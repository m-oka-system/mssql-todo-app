terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9.0"
    }
    # 無料オファー（useFreeLimit）は azurerm が未対応のため azapi を併用します
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.11.0"
    }
    # ファイアウォール規則へ実行元の IP を自動で登録するために使います
    http = {
      source  = "hashicorp/http"
      version = "~> 3.6.0"
    }
  }
}
