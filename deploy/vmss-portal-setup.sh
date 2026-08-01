#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

systemctl stop apt-daily.timer apt-daily-upgrade.timer apt-daily.service \
    apt-daily-upgrade.service esm-cache.service apt-news.service 2>/dev/null || true

apt_get_retry() {
    local attempt
    for attempt in 1 2 3; do
        if apt-get "$@"; then
            return 0
        fi
        echo "apt-get failed. Retrying in 15 seconds ($attempt/3)"
        sleep 15
    done
    return 1
}

apt_get_retry update
apt_get_retry install -y git

repo_dir="$(mktemp -d)"
git clone --depth 1 --sparse https://github.com/m-oka-system/mssql-todo-app.git "$repo_dir"
cd "$repo_dir"
git sparse-checkout set src deploy

"$repo_dir/deploy/setup.sh"

install -o todo -g todo -m 600 /dev/stdin /opt/todo/src/.env <<'ENVFILE'
DB_HOST=<server-name>.database.windows.net
DB_NAME=todo
DB_USER=<admin-user>
DB_PASSWORD=<password>
ENVFILE

systemctl restart todo

cd /
rm -rf "$repo_dir"
