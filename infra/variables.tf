variable "resource_group_name" {
  type = string
}

variable "location" {
  type    = string
  default = "japaneast"
}

# ハンズオンでは Cloud Shell とローカル（ブラウザを動かす端末）の両方から
# 接続します。terraform apply を実行した側の IP は自動で許可されるため、
# **もう一方の IP だけ**をここに指定します。
#
#   Cloud Shell から apply する場合 : ローカルの IP を指定します
#   ローカルから apply する場合     : Cloud Shell の IP（curl -s https://api.ipify.org）を指定します
variable "allowed_client_ip" {
  type    = list(string)
  default = []
}
