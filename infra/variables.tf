variable "resource_group_name" {
  type = string
}

variable "location" {
  type    = string
  default = "japaneast"
}

# SSH（22 番）と SQL のファイアウォールで許可する送信元です。HTTP は Internet へ公開するため、ここに含める必要はありません。
# terraform apply を実行した環境の IP は自動で許可されるため、それ以外に許可したい IP だけをここに指定します。
#   Cloud Shell で apply し、ローカルからも接続する場合 : ローカルの IP を指定します
#   ローカルだけで進める場合                            : 指定は不要です
variable "allowed_client_ip" {
  type    = list(string)
  default = []
}
