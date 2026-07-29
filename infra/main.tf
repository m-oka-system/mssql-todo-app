resource "random_string" "suffix" {
  length  = 5
  lower   = true
  numeric = true
  upper   = false
  special = false
}

# resource "azurerm_resource_group" "rg" {
#   name     = "rg"
#   location = var.location
# }

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

module "vnet" {
  source              = "./modules/vnet"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  vnet_name           = "vnet"
  address_space       = ["10.0.0.0/16"]
}

module "subnet" {
  source               = "./modules/subnet"
  resource_group_name  = data.azurerm_resource_group.this.name
  virtual_network_name = module.vnet.virtual_network_name

  subnet = {
    vm = {
      name                            = "snet-vm"
      address_prefixes                = ["10.0.1.0/24"]
      default_outbound_access_enabled = true
    }
  }
}

module "network_security_group" {
  source              = "./modules/network_security_group"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  subnet              = module.subnet.subnet

  network_security_group = {
    vm = {
      name          = "nsg-vm"
      target_subnet = "vm"
    }
  }
}

module "ssh_public_key" {
  source              = "./modules/ssh_public_key"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  name                = "sshkey-vm"
}

module "vm" {
  source              = "./modules/vm"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  ssh_public_key      = module.ssh_public_key.public_key_openssh
  subnet_id           = module.subnet.subnet["vm"].id

  vm = {
    vm01 = {
      name      = "vm01"
      public_ip = true
    }
  }
}
