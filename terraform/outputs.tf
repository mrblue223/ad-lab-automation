# ---- Outputs: feed these into ansible/inventory/azure.ini -------------------

output "dc_public_ip" {
  description = "HYDRA-DC public IP — put in azure.ini [dc]"
  value       = azurerm_public_ip.dc.ip_address
}

output "workstation_public_ips" {
  description = "Workstation public IPs — put in azure.ini [workstations]"
  value       = { for k, v in azurerm_public_ip.ws : k => v.ip_address }
}

output "ansible_inventory_hint" {
  description = "Copy these into ansible/inventory/azure.ini"
  value = <<EOT

[dc]
HYDRA-DC ansible_host=${azurerm_public_ip.dc.ip_address} ws_name=HYDRA-DC

[workstations]
%{ for k, v in azurerm_public_ip.ws ~}
${k} ansible_host=${v.ip_address} ws_name=${k} ws_ip=${var.workstation_ips[k]}
%{ endfor ~}
EOT
}
