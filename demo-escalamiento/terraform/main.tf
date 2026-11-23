# =====================================================================
#  DEMO ESCALAMIENTO Y ALTA DISPONIBILIDAD
#  Internet -> IP pública (zonal-redundante) -> Load Balancer Standard
#           -> VM Scale Set repartido en 3 zonas -> app Python (/work, /health)
#  Autoscale por CPU + reparación automática de instancias no sanas
# =====================================================================

resource "random_string" "sufijo" {
  length  = 4
  upper   = false
  special = false
}

locals {
  nombre = "${var.prefix}-${random_string.sufijo.result}"
  tags = {
    curso = "infraestructura-ti"
    tema  = "escalamiento-ha"
  }
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.nombre}"
  location = var.location
  tags     = local.tags
}

# ------------------------------------------------------------ RED
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${local.nombre}"
  address_space       = ["10.30.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_subnet" "vmss" {
  name                 = "snet-vmss"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.30.1.0/24"]
}

# El LB Standard es "seguro por defecto": sin una regla NSG que permita
# el puerto 80, el tráfico NO llega a las instancias.
resource "azurerm_network_security_group" "vmss" {
  #checkov:skip=CKV_AZURE_160:Puerto 80 expuesto intencionalmente por el Load Balancer para la app web
  name                = "nsg-vmss-${local.nombre}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags

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
  # Las sondas del LB (AzureLoadBalancer) ya están permitidas por la
  # regla por defecto AllowAzureLoadBalancerInBound. SSH no se abre.
}

resource "azurerm_subnet_network_security_group_association" "vmss" {
  subnet_id                 = azurerm_subnet.vmss.id
  network_security_group_id = azurerm_network_security_group.vmss.id
}

# ------------------------------------------------------------ BALANCEADOR
resource "azurerm_public_ip" "lb" {
  name                = "pip-lb-${local.nombre}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones # IP zonal-redundante: sobrevive a la caída de una zona
  domain_name_label   = local.nombre
  tags                = local.tags
}

resource "azurerm_lb" "lb" {
  name                = "lb-${local.nombre}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  tags                = local.tags

  frontend_ip_configuration {
    name                 = "fe-publico"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "pool" {
  name            = "be-vmss"
  loadbalancer_id = azurerm_lb.lb.id
}

# Sonda de salud: si /health no responde 200 en 2 intentos seguidos
# (cada 5 s), el LB deja de enviar tráfico a esa instancia.
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
  disable_outbound_snat          = true # la salida la gestiona la regla outbound
  idle_timeout_in_minutes        = 4
}

# Salida a Internet explícita para las instancias (p. ej. apt install)
resource "azurerm_lb_outbound_rule" "salida" {
  name                    = "outbound-vmss"
  loadbalancer_id         = azurerm_lb.lb.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.pool.id

  frontend_ip_configuration {
    name = "fe-publico"
  }
}

# ------------------------------------------------------------ VM SCALE SET
resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                = "vmss-${local.nombre}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = var.vm_size
  instances           = var.min_instances
  zones               = var.zones
  zone_balance        = false # "mejor esfuerzo": no bloquea si una zona no tiene capacidad
  overprovision       = false # no crear VMs extra (cuota limitada y demo más clara)
  upgrade_mode        = "Manual"
  tags                = local.tags

  admin_username                  = "azureuser"
  disable_password_authentication = true
  admin_ssh_key {
    username   = "azureuser"
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

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

  encryption_at_host_enabled = true

  network_interface {
    name    = "nic"
    primary = true

    ip_configuration {
      name                                   = "ipconfig"
      primary                                = true
      subnet_id                              = azurerm_subnet.vmss.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.pool.id]
    }
  }

  # La plataforma vigila la sonda de salud y REEMPLAZA las instancias
  # que permanezcan no sanas después del periodo de gracia.
  health_probe_id = azurerm_lb_probe.health.id
  automatic_instance_repair {
    enabled      = true
    grace_period = "PT10M"
  }

  boot_diagnostics {}

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    app = indent(6, file("${path.module}/../app/app.py"))
  }))

  # El autoscale cambia el número de instancias; Terraform no debe
  # "corregirlo" en el siguiente apply.
  lifecycle {
    ignore_changes = [instances]
  }

  depends_on = [azurerm_lb_rule.http]
}

# ------------------------------------------------------------ AUTOSCALE
resource "azurerm_monitor_autoscale_setting" "cpu" {
  name                = "autoscale-${local.nombre}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.vmss.id
  tags                = local.tags

  profile {
    name = "perfil-cpu"

    capacity {
      default = var.min_instances
      minimum = var.min_instances
      maximum = var.max_instances
    }

    # SCALE-OUT: CPU promedio > umbral durante 5 min -> +1 instancia
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

    # SCALE-IN: CPU promedio < umbral durante 5 min -> -1 instancia
    # (umbrales separados = histéresis, evita el "flapping")
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
