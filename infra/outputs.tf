output "ssh_command" {
  value = "ssh -i ${local_sensitive_file.ssh_private_key.filename} ${module.vm.admin_username}@${module.vm.vm_public_ip["vm01"].ip_address}"
}

# 接続情報はこのファイルに書き出す。中身をそのまま VM の /opt/todo/src/.env へ貼り付けられる
output "env_file" {
  value = local_sensitive_file.env.filename
}
