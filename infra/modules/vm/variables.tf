variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "vm" {
  type = map(object({
    name                            = string
    vm_size                         = optional(string, "Standard_F1as_v7")
    zone                            = optional(string, "1")
    allow_extension_operations      = optional(bool, true)
    disable_password_authentication = optional(bool, true)
    encryption_at_host_enabled      = optional(bool, false)
    patch_mode                      = optional(string, "ImageDefault")
    secure_boot_enabled             = optional(bool, true)
    vtpm_enabled                    = optional(bool, true)
    os_disk = optional(object({
      os_disk_cache             = optional(string, "ReadWrite")
      os_disk_type              = optional(string, "StandardSSD_LRS")
      os_disk_size              = optional(number, 30)
      write_accelerator_enabled = optional(bool, false)
    }), {})
    public_ip = optional(bool, false)
  }))
}
