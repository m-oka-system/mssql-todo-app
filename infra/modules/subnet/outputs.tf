output "subnet" {
  value = {
    for k, v in azurerm_subnet.this : k => {
      id   = v.id
      name = v.name
    }
  }
}
