# Terraform を実行している環境のグローバル IP を取得する。NSG の SSH 許可と、SQL サーバーのファイアウォール規則の両方に使う
data "http" "my_ip" {
  url                = "https://api.ipify.org"
  request_timeout_ms = 10000

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "グローバル IP を取得できませんでした（HTTP ${self.status_code}）。"
    }
  }
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
  source              = "../../modules/vnet"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  vnet_name           = "vnet"
  address_space       = ["10.0.0.0/16"]
}

module "subnet" {
  source               = "../../modules/subnet"
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
  source              = "../../modules/network_security_group"
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
      source_address_prefixes    = local.allowed_client_ips
      destination_address_prefix = "*"
    },
  ]
}

module "ssh_public_key" {
  source              = "../../modules/ssh_public_key"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  name                = "sshkey-vm-${random_string.suffix.result}"
}

# SSH 秘密鍵をローカルへ保存する
resource "local_sensitive_file" "ssh_private_key" {
  content         = module.ssh_public_key.private_key_pem
  filename        = pathexpand("~/.ssh/ssh-key-${random_string.suffix.result}.pem")
  file_permission = "0400"
}

module "vm" {
  source              = "../../modules/vm"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  ssh_public_key      = module.ssh_public_key.public_key_openssh
  subnet_id           = module.subnet.subnet["vm"].id

  # アプリは入れない。VM への配置は受講者がハンズオンで実施する
  # false のときは拡張機能を作らず、cloud-init が nginx だけを入れる
  # 拡張機能を作らないため、接続情報（db_*）は渡さない
  install_app_enabled = false

  vm = {
    vm01 = {
      name      = "vm01"
      public_ip = true
    }
  }
}

module "mssql_server" {
  source              = "../../modules/mssql_server"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  name                = "sql-iaas-${random_string.suffix.result}"

  # ファイアウォール規則は作らない
  # 送信元 IP の登録は受講者がハンズオンで実施する
  firewall_rule = {}
}

module "mssql_database" {
  source    = "../../modules/mssql_database"
  location  = var.location
  server_id = module.mssql_server.mssql_server_id
  name      = "todo"
}

# 接続情報を src/.env へ書き出す。このまま uv run python src/app.py で使える
resource "local_sensitive_file" "env" {
  filename        = abspath("${path.root}/../../../src/.env")
  file_permission = "0600"

  content = <<-EOT
    DB_HOST=${module.mssql_server.fully_qualified_domain_name}
    DB_NAME=${module.mssql_database.mssql_database_name}
    DB_USER=${module.mssql_server.administrator_login}
    DB_PASSWORD=${module.mssql_server.administrator_login_password}
  EOT
}
