output "ssh_private_key_path" {
  value = local_sensitive_file.ssh_private_key.filename
}

output "ssh_command" {
  value = "ssh -i ${local_sensitive_file.ssh_private_key.filename} ${module.vm.admin_username}@${module.vm.vm_public_ip["vm01"].ip_address}"
}
