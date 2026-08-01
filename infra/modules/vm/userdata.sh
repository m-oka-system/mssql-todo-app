#!/usr/bin/env bash
# cloud-init が VM の初回起動時に実行する
# install_app = false のときだけ使う。アプリを入れず、VM の疎通だけを確認する構成向け
# cloud-init は root で実行するため sudo は付けない
set -euo pipefail

# ライセンス同意などの対話プロンプトで止まらないようにする
export DEBIAN_FRONTEND=noninteractive

# 起動直後は複数のユニットが apt のロックを取り合うため、走らせないようにする
# esm-cache と apt-news は Ubuntu 24.04 で追加されたもので、ブート直後に必ず走る
APT_UNITS="apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service esm-cache.service apt-news.service"
# shellcheck disable=SC2086
systemctl stop $APT_UNITS 2>/dev/null || true

# 途中で失敗しても自動更新を止めたままにしない
trap 'systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true' EXIT

# 停止しても取りこぼす場合に備えて、失敗したら少し待って試し直す
apt_get_retry() {
    local attempt
    for attempt in 1 2 3; do
        if apt-get "$@"; then
            return 0
        fi
        sleep 15
    done
    return 1
}

apt_get_retry update
apt_get_retry install -y nginx
