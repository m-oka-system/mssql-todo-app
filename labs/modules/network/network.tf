# ラボ共通のネットワーク構成をまとめる
# リソースは作らず、リソースごとのモジュールを呼ぶだけにする
#
# リソース名は固定する。変数にしない
# 動画の表示と一致させるため、ラボごとに変える運用をしない（labs/README.md の設計上の約束）

module "vnet" {
  source              = "../vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  vnet_name           = "vnet"
  address_space       = ["10.0.0.0/16"]
}

module "subnet" {
  source               = "../subnet"
  resource_group_name  = var.resource_group_name
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
  source              = "../network_security_group"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet              = module.subnet.subnet

  network_security_group = {
    vm = {
      name          = "nsg-vm"
      target_subnet = "vm"
    }
  }

  network_security_rule = [
    {
      target_nsg                 = "vm"
      name                       = "AllowHttpInbound"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "80"
      source_address_prefix      = "Internet"
      destination_address_prefix = "*"
    },
    {
      target_nsg                 = "vm"
      name                       = "AllowSshMyIpInbound"
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefixes    = var.allowed_client_ips
      destination_address_prefix = "*"
    },
  ]
}
