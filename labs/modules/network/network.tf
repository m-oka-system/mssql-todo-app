# ラボ共通のネットワーク構成
# section07 と section09 が同じ構成を使うため、ここへまとめる
#
# リソースを直接書く。リソースごとの汎用モジュールは経由しない
# ラボのネットワークは 1 通りしかなく、for_each や dynamic を挟むと読む手間が増えるだけである
#
# 名前とアドレス空間は固定する。変数にしない
# 動画の表示と一致させるため、ラボごとに変える運用をしない（labs/README.md の設計上の約束）

resource "azurerm_virtual_network" "this" {
  name                = "vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.0.1.0/24"]
  # VM から apt と GitHub へ出るために必要
  default_outbound_access_enabled = true
  # 既定値をプロバイダ任せにせず明示する
  # プロバイダのスキーマには既定値が載っておらず、版によって変わっても気づけない
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-vm"
  resource_group_name = var.resource_group_name
  location            = var.location
}

# 80 番はインターネットへ公開する。受講者がブラウザから確認するため
resource "azurerm_network_security_rule" "http" {
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  name                        = "AllowHttpInbound"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
}

# 22 番は許可した IP だけに絞る
resource "azurerm_network_security_rule" "ssh" {
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  name                        = "AllowSshMyIpInbound"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = var.allowed_client_ips
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}
