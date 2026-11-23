output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "vmss_name" {
  value = azurerm_linux_virtual_machine_scale_set.vmss.name
}

output "lb_ip" {
  value = azurerm_public_ip.lb.ip_address
}

output "url" {
  value = "http://${azurerm_public_ip.lb.fqdn}"
}

output "comando_locust" {
  value = "locust -f ../locust/locustfile.py --host http://${azurerm_public_ip.lb.ip_address}"
}

output "autoscale_name" {
  value = azurerm_monitor_autoscale_setting.cpu.name
}
