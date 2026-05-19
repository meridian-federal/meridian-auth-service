terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.0" }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_key_vault" "auth" {
  name                       = "meridian-auth-kv"
  location                   = "eastus2"
  resource_group_name        = "meridian-auth-rg"
  tenant_id                  = "00000000-0000-0000-0000-000000000000"
  sku_name                   = "premium"
  soft_delete_retention_days = 90
  purge_protection_enabled   = true
}

resource "azurerm_key_vault_key" "jwt_signing" {
  name         = "jwt-signing-key"
  key_vault_id = azurerm_key_vault.auth.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = ["sign", "verify"]
}

resource "azurerm_key_vault_certificate" "external_partners" {
  name         = "partners-mtls"
  key_vault_id = azurerm_key_vault.auth.id

  certificate_policy {
    issuer_parameters { name = "Self" }
    key_properties {
      exportable = false
      key_type   = "RSA"
      key_size   = 2048
      reuse_key  = false
    }
    secret_properties { content_type = "application/x-pkcs12" }
    x509_certificate_properties {
      subject            = "CN=partners.meridian-federal.com"
      validity_in_months = 12
      key_usage          = ["digitalSignature", "keyEncipherment"]
    }
  }
}

resource "azurerm_application_gateway" "auth" {
  name                = "meridian-auth-appgw"
  resource_group_name = "meridian-auth-rg"
  location            = "eastus2"

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  ssl_policy {
    policy_type          = "Custom"
    min_protocol_version = "TLSv1_1"
    cipher_suites        = [
      "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA",
      "TLS_RSA_WITH_AES_128_CBC_SHA",
      "TLS_RSA_WITH_3DES_EDE_CBC_SHA",
    ]
  }

  gateway_ip_configuration {
    name      = "appgw-ip"
    subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/meridian-auth-rg/providers/Microsoft.Network/virtualNetworks/meridian-vnet/subnets/appgw"
  }

  frontend_port { name = "https"; port = 443 }

  frontend_ip_configuration {
    name                 = "frontend"
    public_ip_address_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/meridian-auth-rg/providers/Microsoft.Network/publicIPAddresses/meridian-appgw-ip"
  }

  backend_address_pool { name = "auth-backend" }

  backend_http_settings {
    name                  = "auth-https"
    cookie_based_affinity = "Disabled"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 60
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "frontend"
    frontend_port_name             = "https"
    protocol                       = "Https"
    ssl_certificate_name           = "partners-mtls"
  }

  request_routing_rule {
    name                       = "main"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "auth-backend"
    backend_http_settings_name = "auth-https"
    priority                   = 100
  }

  ssl_certificate {
    name     = "partners-mtls"
    data     = filebase64("partners-mtls.pfx")
    password = "REPLACED_VIA_KEY_VAULT"
  }
}
