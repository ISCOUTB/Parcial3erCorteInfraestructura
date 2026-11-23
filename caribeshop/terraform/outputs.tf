output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "vmss_name" {
  value = azurerm_linux_virtual_machine_scale_set.vmss.name
}

output "vmss_principal_id" {
  description = "Object ID de la identidad administrada del VMSS (para az role assignment list)."
  value       = azurerm_linux_virtual_machine_scale_set.vmss.identity[0].principal_id
}

output "lb_ip" {
  value = azurerm_public_ip.lb.ip_address
}

output "url" {
  value = "http://${azurerm_public_ip.lb.fqdn}"
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "storage_account_name" {
  value = azurerm_storage_account.st.name
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.law.workspace_id
}

output "comando_locust" {
  value = "locust -f ../locust/locustfile.py --host http://${azurerm_public_ip.lb.ip_address}"
}

output "autoscale_name" {
  value = azurerm_monitor_autoscale_setting.cpu.name
}