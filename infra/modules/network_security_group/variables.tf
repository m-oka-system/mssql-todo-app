variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet" {
  type = map(object({
    id   = string
    name = string
  }))
}

variable "network_security_group" {
  type = map(object({
    name          = string
    target_subnet = string
  }))
}

variable "network_security_rule" {
  type = list(object({
    target_nsg                   = string
    name                         = string
    priority                     = number
    direction                    = string
    access                       = string
    protocol                     = string
    source_port_range            = optional(string)
    source_port_ranges           = optional(list(string))
    destination_port_range       = optional(string)
    destination_port_ranges      = optional(list(string))
    source_address_prefix        = optional(string)
    source_address_prefixes      = optional(list(string))
    destination_address_prefix   = optional(string)
    destination_address_prefixes = optional(list(string))
  }))
  default = []
}
