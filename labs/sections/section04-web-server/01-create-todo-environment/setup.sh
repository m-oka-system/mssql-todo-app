#!/usr/bin/env bash
# Cloud Shell から curl でパイプ実行する入口。処理の本体は scripts/lab-setup.sh にある
set -euo pipefail

readonly LAB_PATH="labs/sections/section04-web-server/01-create-todo-environment"
readonly REPO_URL="https://github.com/m-oka-system/mssql-todo-app.git"
# 改名したときに直す箇所を 1 つに保つため、置き場所は URL から導く
REPO_DIR="${HOME}/$(basename "$REPO_URL" .git)"
readonly REPO_DIR

# 永続ストレージを使う Cloud Shell では $HOME が残る
# 存在だけを見て clone を省くと、古いコードがそのまま走る
if [ -d "${REPO_DIR}/.git" ] && [ "$(git -C "$REPO_DIR" remote get-url origin 2> /dev/null || true)" = "$REPO_URL" ]; then
  # sparse-checkout が有効なままだと、更新しても scripts/ が作業ツリーに現れない
  # VM 向けの取得手順を Cloud Shell で実行した場合に起こる
  if [ "$(git -C "$REPO_DIR" config --get core.sparseCheckout || true)" = "true" ]; then
    git -C "$REPO_DIR" sparse-checkout disable
  fi
  git -C "$REPO_DIR" fetch --depth 1 origin main
  git -C "$REPO_DIR" reset --hard FETCH_HEAD
elif [ -e "$REPO_DIR" ]; then
  # 中身を確認せずに消さない。terraform.tfstate があると、Azure 側のリソースが管理外へ取り残される
  echo "エラー: ${REPO_DIR} に想定と異なる内容があります。" >&2
  echo "移動するか削除してから、もう一度実行してください。" >&2
  exit 1
else
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi

exec "${REPO_DIR}/scripts/lab-setup.sh" "$LAB_PATH"
