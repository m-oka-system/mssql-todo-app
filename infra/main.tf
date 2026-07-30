locals {
  # Cloud Shell から apply すれば Cloud Shell の送信元が入り、その
  # セッションからそのまま SSH できます。セッションが変わって IP が
  # 変わったら、apply し直せば NSG と SQL のファイアウォールが追随します
  terraform_client_ip = chomp(data.http.my_ip.response_body)
  allowed_client_ips  = distinct(concat([local.terraform_client_ip], var.allowed_client_ip))
}

resource "random_string" "suffix" {
  length  = 5
  lower   = true
  numeric = true
  upper   = false
  special = false
}

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
      source_address_prefixes    = local.allowed_client_ips
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
      source_address_prefixes    = local.allowed_client_ips
      destination_address_prefix = "*"
    },
  ]
}

module "ssh_public_key" {
  source              = "./modules/ssh_public_key"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  name                = "sshkey-vm"
}

# SSH 秘密鍵をローカルへ保存する
resource "local_sensitive_file" "ssh_private_key" {
  content         = module.ssh_public_key.private_key_pem
  filename        = pathexpand("~/.ssh/ssh-key.pem")
  file_permission = "0400"
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

# Terraform を実行している端末のグローバル IP です。SQL サーバーの
# ファイアウォール規則へ登録し、ポータルのクエリ エディターから接続できるようにします
data "http" "my_ip" {
  url                = "https://api.ipify.org"
  request_timeout_ms = 10000

  # http プロバイダは 2xx 以外でもエラーになりません。確認しないと、エラーページの
  # HTML がそのままファイアウォール規則へ渡り、原因の分かりにくい失敗になります
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "グローバル IP を取得できませんでした（HTTP ${self.status_code}）。"
    }
  }
}

module "mssql_server" {
  source              = "./modules/mssql_server"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  name                = "sql-iaas-${random_string.suffix.result}"

  # VM からの接続と、SSH を許可した端末からの接続（ポータルのクエリ エディター用）を通します
  firewall_rule = merge(
    {
      vm = {
        name             = "vm01"
        start_ip_address = module.vm.vm_public_ip["vm01"].ip_address
        end_ip_address   = module.vm.vm_public_ip["vm01"].ip_address
      }
    },
    {
      for ip in local.allowed_client_ips : "client-${replace(ip, ".", "-")}" => {
        name             = "client-${replace(ip, ".", "-")}"
        start_ip_address = ip
        end_ip_address   = ip
      }
    }
  )
}

module "mssql_database" {
  source    = "./modules/mssql_database"
  location  = var.location
  server_id = module.mssql_server.mssql_server_id
  name      = "todo"
}
