resource "azurerm_resource_group" "quest" {
  name     = "quest"
  location = "southcentralus"
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "quest" {
  name                = "log-quest-scus"
  location            = azurerm_resource_group.quest.location
  resource_group_name = azurerm_resource_group.quest.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# --- Networking ---

resource "azurerm_virtual_network" "quest" {
  name                = "quest-vnet"
  location            = azurerm_resource_group.quest.location
  resource_group_name = azurerm_resource_group.quest.name
  address_space       = ["10.60.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "quest" {
  name                 = "quest-subnet"
  resource_group_name  = azurerm_resource_group.quest.name
  virtual_network_name = azurerm_virtual_network.quest.name
  address_prefixes     = ["10.60.1.0/24"]
}

resource "azurerm_network_security_group" "quest" {
  name                = "quest-nsg"
  location            = azurerm_resource_group.quest.location
  resource_group_name = azurerm_resource_group.quest.name
  tags                = var.tags

  # Standard LB is pass-through, so the VM sees Front Door's real source IP.
  # Only Front Door's edge IP space may reach the app port.
  security_rule {
    name                       = "AllowFrontDoorInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.app_port)
    source_address_prefix      = "AzureFrontDoor.Backend"
    destination_address_prefix = "*"
  }
}

# --- Load balancer ---

resource "azurerm_public_ip" "lb" {
  name                = "quest-lb-pip"
  location            = azurerm_resource_group.quest.location
  resource_group_name = azurerm_resource_group.quest.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_lb" "quest" {
  name                = "quest-lb"
  location            = azurerm_resource_group.quest.location
  resource_group_name = azurerm_resource_group.quest.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "frontend"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "quest" {
  name            = "quest-backend"
  loadbalancer_id = azurerm_lb.quest.id
}

resource "azurerm_lb_probe" "quest" {
  name            = "http"
  loadbalancer_id = azurerm_lb.quest.id
  protocol        = "Http"
  port            = var.app_port
  request_path    = "/"
}

resource "azurerm_lb_rule" "quest" {
  name                           = "http"
  loadbalancer_id                = azurerm_lb.quest.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = var.app_port
  frontend_ip_configuration_name = "frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.quest.id]
  probe_id                       = azurerm_lb_probe.quest.id
}

# Gives the VMSS SNAT'd outbound internet access (apt/docker pull) without a NAT Gateway.
resource "azurerm_lb_outbound_rule" "quest" {
  name                    = "outbound"
  loadbalancer_id         = azurerm_lb.quest.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.quest.id

  frontend_ip_configuration {
    name = "frontend"
  }
}

# --- Compute ---

# Throwaway keypair: the VMSS resource requires an SSH key, but no interactive access is
# intended — cloud-init handles all provisioning.
resource "tls_private_key" "vmss_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine_scale_set" "quest" {
  name                = "quest-vmss"
  location            = azurerm_resource_group.quest.location
  resource_group_name = azurerm_resource_group.quest.name
  sku                 = var.vm_size
  instances           = var.instance_count
  upgrade_mode        = "Automatic"
  tags                = var.tags

  admin_username                  = "quest"
  disable_password_authentication = true

  admin_ssh_key {
    username   = "quest"
    public_key = tls_private_key.vmss_ssh.public_key_openssh
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    image       = var.image
    app_port    = var.app_port
    secret_word = var.secret_word
  }))

  network_interface {
    name    = "quest-nic"
    primary = true

    ip_configuration {
      name                                   = "internal"
      primary                                = true
      subnet_id                              = azurerm_subnet.quest.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.quest.id]
    }

    network_security_group_id = azurerm_network_security_group.quest.id
  }

  boot_diagnostics {}

  extension {
    name                       = "AzureMonitorLinuxAgent"
    publisher                  = "Microsoft.Azure.Monitor"
    type                       = "AzureMonitorLinuxAgent"
    type_handler_version       = "1.33"
    auto_upgrade_minor_version = true
  }
}

# --- Logging ---

resource "azurerm_monitor_diagnostic_setting" "lb" {
  name                       = "quest-lb-diagnostics"
  target_resource_id         = azurerm_lb.quest.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.quest.id

  enabled_log {
    category = "LoadBalancerAlertEvent"
  }

  enabled_log {
    category = "LoadBalancerProbeHealthStatus"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_data_collection_rule" "quest" {
  name                = "quest-dcr"
  location            = azurerm_resource_group.quest.location
  resource_group_name = azurerm_resource_group.quest.name
  tags                = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.quest.id
      name                  = "quest-workspace"
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["quest-workspace"]
  }

  data_sources {
    syslog {
      name           = "quest-syslog"
      streams        = ["Microsoft-Syslog"]
      facility_names = ["daemon"]
      log_levels     = ["Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "quest" {
  name                    = "quest-dcr-association"
  target_resource_id      = azurerm_linux_virtual_machine_scale_set.quest.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.quest.id
}

# --- Front Door (TLS + managed cert on the default *.azurefd.net domain) ---

resource "azurerm_cdn_frontdoor_profile" "quest" {
  name                = "quest-fd"
  resource_group_name = azurerm_resource_group.quest.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "quest" {
  name                     = "quest-app"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.quest.id
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "quest" {
  name                     = "quest-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.quest.id

  load_balancing {}

  health_probe {
    protocol            = "Http"
    request_type        = "GET"
    path                = "/"
    interval_in_seconds = 30
  }
}

resource "azurerm_cdn_frontdoor_origin" "quest" {
  name                          = "quest-origin"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.quest.id

  enabled                        = true
  host_name                      = azurerm_public_ip.lb.ip_address
  http_port                      = 80
  https_port                     = 443
  origin_host_header             = azurerm_public_ip.lb.ip_address
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = false
}

resource "azurerm_cdn_frontdoor_route" "quest" {
  name                          = "quest-route"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.quest.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.quest.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.quest.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpOnly"
  https_redirect_enabled = true
  link_to_default_domain = true
}
