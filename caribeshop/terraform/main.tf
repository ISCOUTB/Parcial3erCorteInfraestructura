# =====================================================================
#  CARIBESHOP - Plataforma segura, escalable y altamente disponible
#  Integracion de demo-seguridad + demo-escalamiento en un solo proyecto.
# =====================================================================

data "azurerm_client_config" "current" {}

resource "random_string" "sufijo" {
  length  = 5
  upper   = false
  special = false
}

locals {
  nombre = "${var.prefix}-${random_string.sufijo.result}"
  plano  = "${var.prefix}${random_string.sufijo.result}"
}

# ------------------------------------------------------------ RG
resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.nombre}"
  location = var.location
  tags     = var.tags
}

# ------------------------------------------------------------ OBSERVABILIDAD
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${local.nombre}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ------------------------------------------------------------ RED
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${local.nombre}"
  address_space       = ["10.40.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.40.1.0/24"]
  service_endpoints    = ["Microsoft.KeyVault", "Microsoft.Storage"]
}

resource "azurerm_network_security_group" "app" {
  #checkov:skip=CKV_AZURE_160:Puerto 80 expuesto intencionalmente por el Load Balancer para la app web; sin SSH/RDP a Internet
  name                = "nsg-app-${local.nombre}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags

  # Entrada: HTTP desde Internet (para el LB -> instancias)
  security_rule {
    name                       = "Allow-HTTP-Internet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Entrada: denegar resto desde Internet
  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Salida controlada por etiquetas de servicio
  security_rule {
    name                       = "Allow-KeyVault-Out"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureKeyVault"
  }

  security_rule {
    name                       = "Allow-AzureMonitor-Out"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureMonitor"
  }

  security_rule {
    name                       = "Allow-Storage-Out"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Storage"
  }

  security_rule {
    name                       = "Deny-Internet-Out"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# ------------------------------------------------------------ BALANCEADOR
resource "azurerm_public_ip" "lb" {
  name                = "pip-lb-${local.nombre}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones
  domain_name_label   = local.nombre
  tags                = var.tags
}

resource "azurerm_lb" "lb" {
  name                = "lb-${local.nombre}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "fe-publico"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "pool" {
  name            = "be-vmss"
  loadbalancer_id = azurerm_lb.lb.id
}

resource "azurerm_lb_probe" "health" {
  name                = "probe-health"
  loadbalancer_id     = azurerm_lb.lb.id
  protocol            = "Http"
  port                = 80
  request_path        = "/health"
  interval_in_seconds = 5
  probe_threshold     = 2
}

resource "azurerm_lb_rule" "http" {
  name                           = "rule-http"
  loadbalancer_id                = azurerm_lb.lb.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "fe-publico"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.pool.id]
  probe_id                       = azurerm_lb_probe.health.id
  disable_outbound_snat          = true
  idle_timeout_in_minutes        = 4
}

resource "azurerm_lb_outbound_rule" "salida" {
  name                    = "outbound-vmss"
  loadbalancer_id         = azurerm_lb.lb.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.pool.id

  frontend_ip_configuration {
    name = "fe-publico"
  }
}

# ------------------------------------------------------------ ALMACENAMIENTO
resource "azurerm_storage_account" "st" {
  #checkov:skip=CKV2_AZURE_1:CMK fuera del alcance; cifrado de plataforma + doble cifrado
  #checkov:skip=CKV2_AZURE_33:Private Endpoint fuera del alcance (costo); service endpoint + firewall
  #checkov:skip=CKV_AZURE_59:Acceso publico limitado por firewall (IP operador + subred)
  #checkov:skip=CKV_AZURE_206:ZRS suficiente para la demo; produccion evaluaria GZRS
  #checkov:skip=CKV_AZURE_33:No se usa Queue service en esta cuenta
  name                     = "st${local.plano}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "ZRS"
  tags                     = var.tags

  https_traffic_only_enabled        = true
  min_tls_version                   = "TLS1_2"
  allow_nested_items_to_be_public   = false
  infrastructure_encryption_enabled = true
  shared_access_key_enabled         = false

  sas_policy {
    expiration_period = "00.02:00:00"
  }

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    ip_rules                   = var.my_ip
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
  }

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_role_assignment" "operador_blob" {
  scope                = azurerm_storage_account.st.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_container" "datos" {
  #checkov:skip=CKV2_AZURE_21:Registro de lecturas con diagnostic setting StorageRead
  name                  = "datos-clientes"
  storage_account_id    = azurerm_storage_account.st.id
  container_access_type = "private"
  depends_on            = [time_sleep.rbac]
}

resource "azurerm_monitor_diagnostic_setting" "blob" {
  name                       = "diag-blob"
  target_resource_id         = "${azurerm_storage_account.st.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}

# ------------------------------------------------------------ SECRETOS
resource "azurerm_key_vault" "kv" {
  #checkov:skip=CKV2_AZURE_32:Private Endpoint fuera del alcance (costo); firewall + service endpoint
  name                = "kv-${local.plano}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  tags                = var.tags

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    # Key Vault exige CIDR; se normalizan IPs sueltas a /32
    ip_rules                   = [for ip in var.my_ip : (can(regex("/", ip)) ? ip : "${ip}/32")]
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
  }
}

resource "azurerm_role_assignment" "operador_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "rbac" {
  create_duration = "90s"
  depends_on      = [azurerm_role_assignment.operador_kv, azurerm_role_assignment.operador_blob]
}

resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
}

resource "time_offset" "expira_secreto" {
  offset_days = 90
}

resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                           = "diag-kv"
  target_resource_id             = azurerm_key_vault.kv.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.law.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "AuditEvent"
  }
}

resource "azurerm_key_vault_secret" "db" {
  name            = "app-db-password"
  value           = random_password.db.result
  key_vault_id    = azurerm_key_vault.kv.id
  content_type    = "password"
  expiration_date = time_offset.expira_secreto.rfc3339
  depends_on      = [time_sleep.rbac, azurerm_monitor_diagnostic_setting.kv]
}

# ------------------------------------------------------------ VM SCALE SET
resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  #checkov:skip=CKV_AZURE_50:Se requieren extensiones para administrar sin SSH y monitoreo
  name                = "vmss-${local.nombre}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = var.vm_size
  instances           = var.min_instances
  zones               = var.zones
  zone_balance        = false
  overprovision       = false
  upgrade_mode        = "Manual"
  tags                = var.tags

  admin_username                  = "azureuser"
  disable_password_authentication = true
  admin_ssh_key {
    username   = "azureuser"
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  identity {
    type = "SystemAssigned"
  }

  #checkov:skip=CKV_AZURE_97:Encryption at host no disponible en la suscripcion (Azure for Students); se usa cifrado de plataforma
  secure_boot_enabled = true
  vtpm_enabled        = true

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  network_interface {
    name    = "nic"
    primary = true

    ip_configuration {
      name                                   = "ipconfig"
      primary                                = true
      subnet_id                              = azurerm_subnet.app.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.pool.id]
    }
  }

  health_probe_id = azurerm_lb_probe.health.id
  automatic_instance_repair {
    enabled      = true
    grace_period = "PT10M"
  }

  boot_diagnostics {}

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    app            = indent(6, file("${path.module}/../app/app.py"))
    key_vault_name = azurerm_key_vault.kv.name
    secret_name    = "app-db-password"
  }))

  lifecycle {
    ignore_changes = [instances]
  }

  depends_on = [azurerm_lb_rule.http]
}

# Rol: la identidad del VMSS solo puede LEER secretos (minimo privilegio)
resource "azurerm_role_assignment" "vmss_kv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine_scale_set.vmss.identity[0].principal_id
}

# ------------------------------------------------------------ AUTOSCALE
resource "azurerm_monitor_autoscale_setting" "cpu" {
  name                = "autoscale-${local.nombre}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.vmss.id
  tags                = var.tags

  profile {
    name = "perfil-cpu"

    capacity {
      default = var.min_instances
      minimum = var.min_instances
      maximum = var.max_instances
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = var.cpu_scale_out
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT3M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = var.cpu_scale_in
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }

  dynamic "notification" {
    for_each = var.alert_email == "" ? [] : [1]
    content {
      email {
        custom_emails = [var.alert_email]
      }
    }
  }
}

# ------------------------------------------------------------ POLICY (S5)
resource "azurerm_policy_definition" "no_blob_publico" {
  name         = "deny-storage-blob-publico"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "[CaribeShop] Denegar cuentas de almacenamiento con acceso publico a blobs"
  description  = "Rechaza cualquier Storage Account cuyo allowBlobPublicAccess no sea false."

  metadata = jsonencode({ category = "Storage", version = "1.0.0" })

  policy_rule = jsonencode({
    "if" = {
      allOf = [
        { field = "type", equals = "Microsoft.Storage/storageAccounts" },
        {
          field     = "Microsoft.Storage/storageAccounts/allowBlobPublicAccess"
          notEquals = false
        }
      ]
    }
    "then" = { effect = "deny" }
  })
}

resource "azurerm_resource_group_policy_assignment" "no_blob_publico" {
  name                 = "asg-no-blob-publico"
  resource_group_id    = azurerm_resource_group.rg.id
  policy_definition_id = azurerm_policy_definition.no_blob_publico.id
  display_name         = "No blobs publicos en CaribeShop"
}

data "azurerm_policy_definition" "requiere_tag" {
  display_name = "Require a tag on resources"
}

resource "azurerm_resource_group_policy_assignment" "requiere_tag" {
  name                 = "asg-requiere-tag-responsable"
  resource_group_id    = azurerm_resource_group.rg.id
  policy_definition_id = data.azurerm_policy_definition.requiere_tag.id
  display_name         = "Exigir etiqueta 'responsable'"

  parameters = jsonencode({
    tagName = { value = "responsable" }
  })
}

# ------------------------------------------------------------ ALERTA (E5)
resource "azurerm_monitor_action_group" "alertas" {
  count               = var.alert_email == "" ? 0 : 1
  name                = "ag-${local.nombre}"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "caribe"

  email_receiver {
    name          = "equipo"
    email_address = var.alert_email
  }
}

resource "azurerm_monitor_metric_alert" "cpu_alta" {
  count               = var.alert_email == "" ? 0 : 1
  name                = "alert-cpu-alta-${local.nombre}"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_linux_virtual_machine_scale_set.vmss.id]
  description         = "CPU sostenida alta en el VMSS de CaribeShop"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachineScaleSets"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.alertas[0].id
  }
}