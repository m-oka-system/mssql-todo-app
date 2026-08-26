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

module "network" {
  source              = "../../modules/network"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  allowed_client_ips  = local.allowed_client_ips
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

module "mssql_server" {
  source              = "../../modules/mssql_server"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  name                = "sql-iaas-${random_string.suffix.result}"

  # ファイアウォール規則は作らない
  # ロードバランサのフロントエンド IP の登録は受講者がハンズオンで実施する
  firewall_rule = {}
}

module "mssql_database" {
  source    = "../../modules/mssql_database"
  location  = var.location
  server_id = module.mssql_server.mssql_server_id
  name      = "todo"
}
