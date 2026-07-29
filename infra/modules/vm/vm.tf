resource "azurerm_public_ip" "this" {
  for_each = { for k, v in var.vm : k => v if v.public_ip }

  name                = "pip-${each.value.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  allocation_method   = "Static"
  zones               = ["1", "2", "3"]
}

resource "azurerm_network_interface" "this" {
  for_each = var.vm

  name                = "nic-${each.value.name}"
  resource_group_name = var.resource_group_name
  location            = var.location

  ip_configuration {
    name                          = "ipconfig1"
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = var.subnet_id
    public_ip_address_id          = each.value.public_ip ? azurerm_public_ip.this[each.key].id : null
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  for_each = var.vm

  name                            = each.value.name
  computer_name                   = each.value.name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = each.value.vm_size
  admin_username                  = var.admin_username
  zone                            = each.value.zone
  allow_extension_operations      = each.value.allow_extension_operations
  disable_password_authentication = each.value.disable_password_authentication
  encryption_at_host_enabled      = each.value.encryption_at_host_enabled
  patch_mode                      = each.value.patch_mode
  secure_boot_enabled             = each.value.secure_boot_enabled
  vtpm_enabled                    = each.value.vtpm_enabled
  custom_data                     = filebase64("${path.module}/userdata.sh")

  network_interface_ids = [
    azurerm_network_interface.this[each.key].id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  priority        = "Spot"
  max_bid_price   = -1
  eviction_policy = "Deallocate"

  boot_diagnostics {}

  os_disk {
    name                      = "osdisk-${each.value.name}"
    caching                   = each.value.os_disk.os_disk_cache
    storage_account_type      = each.value.os_disk.os_disk_type
    disk_size_gb              = each.value.os_disk.os_disk_size
    write_accelerator_enabled = each.value.os_disk.write_accelerator_enabled
  }

  source_image_reference {
    publisher = "canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
