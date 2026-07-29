resource "azurerm_subnet" "this" {
  for_each = var.subnet

  name                              = each.value.name
  resource_group_name               = var.resource_group_name
  virtual_network_name              = var.virtual_network_name
  address_prefixes                  = each.value.address_prefixes
  default_outbound_access_enabled   = each.value.default_outbound_access_enabled
  private_endpoint_network_policies = each.value.private_endpoint_network_policies
  service_endpoints                 = each.value.service_endpoints

  dynamic "delegation" {
    for_each = lookup(each.value, "service_delegation", null) != null ? [each.value.service_delegation] : []

    content {
      name = delegation.value.name

      service_delegation {
        name    = delegation.value.name
        actions = delegation.value.actions
      }
    }
  }
}
