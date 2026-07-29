output "subnnetwork_security_group" {
  value = {
    for k, v in azurerm_network_security_group.this : k => {
      id   = v.id
      name = v.name
    }
  }
}
