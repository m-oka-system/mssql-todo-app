variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

# SSH（22 番）で許可する送信元。HTTP は Internet へ公開するため、ここに含める必要はない
# 誰を許可するかはラボ側の判断のため、値の組み立ては root module で行う
variable "allowed_client_ips" {
  type = list(string)
}
