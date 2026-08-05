# denmarkeast (constraint #8's first fix for VM quota) turned out to support neither
# Microsoft.OperationalInsights/workspaces nor Data Collection Rule Associations at all --
# splitting logging into a second region (eastus) worked around the workspace half of that but
# not the association half, since DCR associations aren't available there either (confirmed via
# `az provider show -n Microsoft.Insights` and `az monitor diagnostic-settings categories list`
# rather than guessing a third time). swedencentral is one of a handful of regions confirmed to
# support Log Analytics workspaces, DCR associations, AND have open VM quota on this
# subscription for Standard_B2ts_v2 (checked programmatically against the full SKU list) --
# everything lives here now, no region split needed.
resource "azurerm_resource_group" "quest" {
  name     = "quest"
  location = "swedencentral"
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "quest" {
  name                = "log-quest-swc"
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

  # Caddy on the VM terminates TLS itself (see cloud-init.yaml.tftpl) and needs to be
  # genuinely internet-reachable on 80 (ACME HTTP-01 challenge + redirect) and 443 (the
  # actual TLS listener). The app container only binds to loopback, so it's never exposed
  # directly regardless of this rule.
  security_rule {
    name                       = "AllowWebInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

# --- Load balancer ---
#
# TLS (managed cert + trusted CA) for Azure: both Front Door (blocked on Free
# Trial/Student subscriptions) and classic Azure CDN (blocked platform-wide, no new
# resources since Oct 2025) are dead ends here. Caddy runs directly on the VM instead
# (see cloud-init.yaml.tftpl) and gets a genuine Let's Encrypt certificate for a free
# wildcard-DNS hostname derived from the LB's public IP (<ip>.sslip.io resolves to that
# IP with no registration or propagation delay). The Standard LB stays pure L4 and
# forwards both 80 (ACME HTTP-01 challenge) and 443 (the real TLS listener) straight
# through to Caddy on the VM.

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
  port            = 80
  request_path    = "/"
}

resource "azurerm_lb_rule" "quest" {
  name                           = "http"
  loadbalancer_id                = azurerm_lb.quest.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.quest.id]
  probe_id                       = azurerm_lb_probe.quest.id

  # The outbound rule below reuses this same frontend IP for SNAT; Azure requires
  # the load-balancing rule to explicitly cede outbound SNAT to it.
  disable_outbound_snat = true
}

# TCP, not Https: during the brief window before Caddy has finished its first ACME
# issuance, a TLS-handshake probe could flap the backend as unhealthy. A plain TCP
# connect is enough to know Caddy itself is up.
resource "azurerm_lb_probe" "https" {
  name            = "https"
  loadbalancer_id = azurerm_lb.quest.id
  protocol        = "Tcp"
  port            = 443
}

resource "azurerm_lb_rule" "https" {
  name                           = "https"
  loadbalancer_id                = azurerm_lb.quest.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.quest.id]
  probe_id                       = azurerm_lb_probe.https.id
  disable_outbound_snat          = true
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
    lb_hostname = "${azurerm_public_ip.lb.ip_address}.sslip.io"
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

  # The only two categories this specific LB resource actually reports -- confirmed via
  # `az monitor diagnostic-settings categories list` against the live resource, after
  # guessing wrong twice (LoadBalancerProbeHealthStatus, then LoadBalancerAlertEvent).
  enabled_log {
    category = "LoadBalancerHealthEvent"
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
