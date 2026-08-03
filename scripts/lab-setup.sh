#!/usr/bin/env bash
# ラボ環境を構築する。各ラボの setup.sh から呼ばれる
# 引数はリポジトリルートから見たラボのパス（例: labs/sections/section04-web-server/01-create-todo-environment）
set -euo pipefail

# readonly では右辺のコマンド置換が失敗しても set -e が止めないため、代入と分ける
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

abort() {
  echo "エラー: $1" >&2
  shift
  local line
  for line in "$@"; do
    echo "$line" >&2
  done
  exit 1
}

# az コマンドを実行し、失敗と「結果が false」を区別する
# if の条件内でコマンド置換を行うと set -e が働かず、CLI の失敗を「見つからない」と誤案内してしまう
#
# 標準エラーは戻り値へ混ぜない。az は成功時にも WARNING を出すことがあり、混ぜると結果の判定が壊れる
run_az() {
  local output status errors
  errors="$(mktemp)"
  set +e
  output="$("$@" 2> "$errors")"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    local detail
    detail="$(cat "$errors")"
    rm -f "$errors"
    abort "Azure CLI の実行に失敗しました（$*）。" \
      "未ログイン・権限不足・通信障害のいずれかが考えられます。" \
      "az login でサインインし直してから、もう一度お試しください。" \
      "" \
      "$detail"
  fi

  rm -f "$errors"
  printf '%s' "$output"
}

# 数値でなければ比較が終了コード 2 を返すが、if の条件内では set -e が止めない
# 判定を素通りして誤ったリソースグループへ apply するため、形式を先に検証する
require_number() {
  # $1: 値, $2: 何を取得しようとしたか
  if ! [[ "$1" =~ ^[0-9]+$ ]]; then
    abort "$2 を取得できませんでした（応答: $1）。" \
      "az account show でサインインの状態を確認してください。"
  fi
}

# 受講者へ確認を取る。制御端末がなければ中止する
# /dev/tty は誰でも読める権限を持つため、test -r では開けるかどうかを判定できない
confirm_or_abort() {
  if ! { exec 3< /dev/tty; } 2> /dev/null; then
    abort "確認を取れないため中止しました。" \
      "使用するリソースグループ名を指定してから、もう一度実行してください。" \
      "" \
      "  az group list -o table" \
      '  export TF_VAR_resource_group_name="<リソースグループ名>"'
  fi

  local answer
  if ! read -r -p "続けますか？ 続ける場合は yes と入力してください: " answer <&3; then
    exec 3<&-
    abort "入力を読み取れなかったため中止しました。"
  fi
  exec 3<&-

  if [ "$answer" != "yes" ]; then
    abort "中止しました。"
  fi
}

if [ $# -ne 1 ]; then
  abort "引数の数が正しくありません。" "使い方: $0 <ラボのパス>"
fi

LAB_DIR="${REPO_ROOT}/$1"
readonly LAB_DIR

if [ ! -d "$LAB_DIR" ]; then
  abort "ラボのディレクトリが見つかりません: $1" \
    "リポジトリが古い可能性があります。次を実行して更新してから、もう一度お試しください。" \
    "" \
    "  git -C \"${REPO_ROOT}\" fetch --depth 1 origin main" \
    "  git -C \"${REPO_ROOT}\" reset --hard FETCH_HEAD"
fi

# リソースグループを決める
# 事前に export されていればそれを使い、未設定ならコース内ラボ環境とみなして唯一のものを探す
if [ -z "${TF_VAR_resource_group_name:-}" ]; then
  rg_count="$(run_az az group list --query "length(@)" -o tsv)"
  require_number "$rg_count" "リソースグループの数"

  if [ "$rg_count" -ne 1 ]; then
    abort "リソースグループを特定できませんでした（現在 ${rg_count} 個）。" \
      "使用するリソースグループ名を指定してから、もう一度実行してください。" \
      "コース内ラボ環境では、ワークスペースに用意されたリソースグループの名前です。" \
      "" \
      "  az group list -o table" \
      '  export TF_VAR_resource_group_name="<リソースグループ名>"'
  fi

  TF_VAR_resource_group_name="$(run_az az group list --query "[0].name" -o tsv)"
  export TF_VAR_resource_group_name
fi

# 代入で受ける。if の条件内でコマンド置換すると set -e が抑止され、run_az の abort がサブシェルで止まる
group_exists="$(run_az az group exists --name "$TF_VAR_resource_group_name")"

if [ "$group_exists" != "true" ]; then
  abort "リソースグループ '${TF_VAR_resource_group_name}' が見つかりません。" \
    "TF_VAR_resource_group_name の指定に誤りがないか確認してください。"
fi

# 既存のリソースがあれば、経路によらず同意を取る
# 名前を明示した経路のほうが危険が大きい。受講者自身のサブスクリプションである確率が高いため
# 片付けはリソースグループごとの削除のため、既存のリソースも巻き添えになる
resource_count="$(run_az az resource list --resource-group "$TF_VAR_resource_group_name" --query "length(@)" -o tsv)"
require_number "$resource_count" "リソースグループ '${TF_VAR_resource_group_name}' の中身"

subscription="$(run_az az account show --query "name" -o tsv)"

if [ "$resource_count" -gt 0 ]; then
  echo "警告: リソースグループ '${TF_VAR_resource_group_name}' には既に ${resource_count} 個のリソースがあります。" >&2
  echo "サブスクリプション: ${subscription}" >&2
  echo "このラボの片付けは「リソースグループごと削除」です。既存のリソースも消えます。" >&2
  echo "" >&2
  confirm_or_abort
fi

echo "サブスクリプション: ${subscription}"
echo "リソースグループ: ${TF_VAR_resource_group_name}"

# 2 回目以降は、構成だけが最新版へ入れ替わったまま古い state へ適用されることになる
# 属性の変更によってはリソースが置き換えられるため、無確認では進めない
if [ -s "${LAB_DIR}/terraform.tfstate" ]; then
  echo "警告: このラボは既に構築済みです（terraform.tfstate があります）。" >&2
  echo "教材が更新されている場合、リソースが作り直されることがあります。" >&2
  echo "作り直したくない場合は、リソースグループごと削除してから実行してください。" >&2
  echo "" >&2
  confirm_or_abort
fi

# -var は渡さない。Terraform が TF_VAR_resource_group_name を自動で読む
cd "$LAB_DIR"
terraform init -input=false
terraform apply -auto-approve -input=false
