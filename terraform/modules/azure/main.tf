resource "azurerm_resource_group" "quest" {
  name     = "quest"
  location = "denmarkeast"
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "quest" {
  name                = "log-quest-dnk"
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

  # Standard LB is pass-through, so the VM sees the real source IP of whatever hits it.
  # Ideally this would be locked to the CDN edge's IP space the way the previous Front
  # Door design was (service tag AzureFrontDoor.Backend), but Azure CDN Standard from
  # Microsoft (classic) doesn't have a documented/guaranteed service tag of its own, and
  # guessing wrong here would silently break the deployment (health probes + all traffic
  # dropped). Left open; origin lockdown is noted as a follow-up in docs/plan.md.
  security_rule {
    name                       = "AllowAppInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.app_port)
    source_address_prefix      = "Internet"
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

  # The outbound rule below reuses this same frontend IP for SNAT; Azure requires
  # the load-balancing rule to explicitly cede outbound SNAT to it.
  disable_outbound_snat = true
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

# --- CDN (TLS + managed cert on the default *.azureedge.net domain) ---
#
# Front Door Standard/Premium is rejected outright on Free Trial/Student subscriptions
# ("Free Trial and Student account is forbidden for Azure Frontdoor resources"). Azure CDN
# Standard from Microsoft (the classic, non-Front-Door SKU) is the only CDN tier Microsoft
# documents as available to those subscription types, so it's used here instead. Its default
# endpoint hostname gets a Microsoft-managed HTTPS certificate with no extra configuration.

resource "azurerm_cdn_profile" "quest" {
  name                = "quest-cdn"
  location            = "global"
  resource_group_name = azurerm_resource_group.quest.name
  sku                 = "Standard_Microsoft"
  tags                = var.tags
}

resource "azurerm_cdn_endpoint" "quest" {
  name                = "quest-app"
  profile_name        = azurerm_cdn_profile.quest.name
  location            = "global"
  resource_group_name = azurerm_resource_group.quest.name
  tags                = var.tags

  is_http_allowed  = true
  is_https_allowed = true

  origin_host_header = azurerm_public_ip.lb.ip_address

  origin {
    name      = "quest-origin"
    host_name = azurerm_public_ip.lb.ip_address
    http_port = 80
  }

  # The app's responses are dynamic (e.g. per-request client IP, secret word), not
  # cacheable static assets, so bypass the CDN's default caching behavior entirely.
  global_delivery_rule {
    cache_expiration_action {
      behavior = "BypassCache"
    }

    # Unlike Front Door, classic Azure CDN doesn't document automatically setting
    # X-Forwarded-Proto from the client's protocol, and the origin here is only ever
    # reached over plain HTTP (no https_port on the origin above). The app's /tls check
    # relies on this header, so set it explicitly rather than depend on undocumented
    # default behavior -- this endpoint is only ever meant to be hit over HTTPS.
    modify_request_header_action {
      action = "Overwrite"
      name   = "X-Forwarded-Proto"
      value  = "https"
    }
  }
}
