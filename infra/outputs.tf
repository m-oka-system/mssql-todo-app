output "ssh_command" {
  value = "ssh -i ${local_sensitive_file.ssh_private_key.filename} ${module.vm.admin_username}@${module.vm.vm_public_ip["vm01"].ip_address}"
}

# src/.env に記入する接続情報です。パスワードは terraform output -raw db_password で取り出します
output "db_host" {
  value = module.mssql_server.fully_qualified_domain_name
}

output "db_name" {
  value = module.mssql_database.mssql_database_name
}

output "db_user" {
  value = module.mssql_server.administrator_login
}

output "db_password" {
  value     = module.mssql_server.administrator_login_password
  sensitive = true
}

# 無料オファーが適用されたかを確認します
output "db_use_free_limit" {
  value = module.mssql_database.use_free_limit
}
