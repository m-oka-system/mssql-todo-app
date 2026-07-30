# azapi は hashicorp ではなく Azure 名前空間のため、モジュール側でも出所を明示します。
# 書かないと terraform init が registry.terraform.io/hashicorp/azapi を探して失敗します
terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
  }
}

# 無料オファー（Free Limit）は azurerm が未対応のため azapi で作成します。
# azurerm_mssql_database には useFreeLimit / freeLimitExhaustionBehavior に相当する
# 引数がありません（v4.81・v5.0 のいずれでも未実装）。az CLI の --use-free-limit と
# 同じプロパティを REST API へ直接渡します。
#
# 値は変数にせずリテラルで書きます。無料オファーでは変更できない項目が多く、
# 変えられるように見せると事故につながるためです（理由は各行のコメント）
resource "azapi_resource" "this" {
  type      = "Microsoft.Sql/servers/databases@2025-01-01"
  name      = var.name
  parent_id = var.server_id
  location  = var.location

  body = {
    sku = {
      # 無料オファーはサーバーレスの General Purpose のみです。vCore 数は
      # name ではなく capacity で指定します（GP_S_Gen5_2 のような書き方ではありません）
      name     = "GP_S_Gen5"
      tier     = "GeneralPurpose"
      family   = "Gen5"
      capacity = 2
    }
    properties = {
      collation = "SQL_Latin1_General_CP1_CI_AS"

      # 無料枠は 32 GB です
      maxSizeBytes = 32 * 1024 * 1024 * 1024

      # 無操作が続くと自動的に一時停止します。60 分から変更できません。
      # 変更しようとすると apply が ProvisioningDisabled で失敗します
      minCapacity    = 0.5
      autoPauseDelay = 60

      # AutoPause は「上限に達したら翌月まで停止」です。
      # BillOverUsage にすると超過分が課金され、**同一の請求期間内は無料枠へ戻せません**
      useFreeLimit                = true
      freeLimitExhaustionBehavior = "AutoPause"

      # 無料オファーで AutoPause を選ぶと、バックアップはローカル冗長のみになります
      requestedBackupStorageRedundancy = "Local"
      zoneRedundant                    = false
    }
  }

  # azurerm では確認できない項目のため、適用後の値を出力へ残します
  response_export_values = ["properties.useFreeLimit"]
}
