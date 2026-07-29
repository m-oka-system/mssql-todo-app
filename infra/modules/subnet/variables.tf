variable "resource_group_name" {
  type = string
}

variable "virtual_network_name" {
  type = string
}

variable "subnet" {
  type = map(object({
    name                              = string
    address_prefixes                  = list(string)
    default_outbound_access_enabled   = optional(bool, false)
    private_endpoint_network_policies = optional(string, "Disabled")
    service_endpoints                 = optional(list(string), [])
    service_delegation = optional(object({
      name    = string
      actions = list(string)
    }))
  }))
}
