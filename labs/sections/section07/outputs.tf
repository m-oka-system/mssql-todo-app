output "ssh_command" {
  value = "ssh -i ${local_sensitive_file.ssh_private_key.filename} ${module.vm.admin_username}@${module.vm.vm_public_ip["vm01"].ip_address}"
}

output "scp_env_command" {
  value = "scp -i ${local_sensitive_file.ssh_private_key.filename} ${local_sensitive_file.env.filename} ${module.vm.admin_username}@${module.vm.vm_public_ip["vm01"].ip_address}:~/"
}

# ブラウザで開く URL。そのまま貼り付けられる形にする
output "app_url" {
  value = "http://${module.vm.vm_public_ip["vm01"].ip_address}"
}
