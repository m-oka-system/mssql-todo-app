# apply の直後に、次の手順で入力するコマンドを画面へ表示する
#
# terraform output はコメントを出せない。description を書いても Outputs には表示されない
# 並び順も名前のアルファベット順で固定される
# 値そのものを複数行にすれば、改行と補足を画面へ出せる（ヒアドキュメントとして表示される）

output "next_steps" {
  value = <<-EOT
    以下の手順に従って進めてください。

      1. ブラウザで Todo アプリを開く
         http://${module.vm.vm_public_ip["vm01"].ip_address}

      2. DB 接続情報の定義ファイル (.env) を VM へ送る
         scp -i ${local_sensitive_file.ssh_private_key.filename} ${local_sensitive_file.env.filename} ${module.vm.admin_username}@${module.vm.vm_public_ip["vm01"].ip_address}:~/

      3. VM へ SSH 接続する
         ssh -i ${local_sensitive_file.ssh_private_key.filename} ${module.vm.admin_username}@${module.vm.vm_public_ip["vm01"].ip_address}
  EOT
}
