output "vm_public_ip" {
  value = azurerm_public_ip.this
}

output "vm_network_interface" {
  value = azurerm_network_interface.this
}

output "admin_username" {
  value = var.admin_username
}
