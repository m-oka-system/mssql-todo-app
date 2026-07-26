#!/usr/bin/env bash
#
# Azure VM（Ubuntu 24.04 LTS）に Todo アプリを配置して起動します。
#
#   sudo ./deploy/setup.sh
#
# 何度実行しても同じ結果になるように書いています。
# 記入済みの .env は上書きしません。

# 途中で失敗したら、その場で止めます。
#   -e          コマンドが失敗したら終了します
#   -u          未定義の変数を参照したら終了します
#   -o pipefail パイプの途中で失敗しても終了します
set -euo pipefail

UBUNTU_VERSION="24.04"
APP_USER="todo"
APP_DIR="/opt/todo"
SERVICE_NAME="todo"
UV_BIN="/usr/local/bin/uv"
# 開発環境と同じバージョンに固定します。uv.lock を作ったのもこのバージョンです。
# 最新版を取りに行くと、実行した日によって VM の状態が変わります
UV_VERSION="0.9.18"
# 2 秒間隔で 15 回試し、最大 30 秒待ってから失敗と判定します
HEALTH_CHECK_ATTEMPTS=15
HEALTH_CHECK_INTERVAL=2

# apt がライセンス同意などの対話プロンプトで止まらないようにします
export DEBIAN_FRONTEND=noninteractive

# このスクリプトが置かれた deploy/ の親が、リポジトリのルートです
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(dirname "$SCRIPT_DIR")"

log() {
    echo "==> $*"
}

# Azure の Ubuntu イメージは起動直後に unattended-upgrades が走ります。素の apt-get は
# dpkg のロックを取れずに即座に失敗し、set -e でスクリプトがそこで止まります。
# ロックが空くまで最大 600 秒待たせるため、apt-get はこの関数を通して呼びます
apt_get() {
    apt-get -o DPkg::Lock::Timeout=600 "$@"
}

# 起動に失敗したときの案内です。画面にはエラーの詳細を出さない設計のため、
# ログの見方を伝えないと受講者が行き詰まります
abort_with_log_hint() {
    echo "" >&2
    echo "$1" >&2
    echo "次のコマンドでログを確認してください。" >&2
    echo "  sudo journalctl -u $2 -n 50 --no-pager" >&2
    exit 1
}

# 応答を返すまで待ちます。固定の sleep では、VM の性能や初回起動の差で足りません
wait_for_health() {
    local url="$1"
    local attempt=1
    while [ "$attempt" -le "$HEALTH_CHECK_ATTEMPTS" ]; do
        # Streamlit のヘルスチェックは、接続を受け付けられる状態のとき本文に ok を返します
        if [ "$(curl -s --max-time 2 "$url")" = "ok" ]; then
            return 0
        fi
        sleep "$HEALTH_CHECK_INTERVAL"
        attempt=$((attempt + 1))
    done
    return 1
}

#### 前提の確認

if [ "$(id -u)" -ne 0 ]; then
    echo "root 権限が必要です。sudo を付けて実行してください。" >&2
    exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release

# ODBC Driver 18 のリポジトリ URL は Ubuntu のバージョンごとに分かれています。
# 対象外のバージョンで実行すると、存在しない URL を取得して失敗します
if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "$UBUNTU_VERSION" ]; then
    echo "このスクリプトは Ubuntu ${UBUNTU_VERSION} 専用です（検出: ${PRETTY_NAME:-不明}）。" >&2
    exit 1
fi

#### 1. ODBC Driver 18 の導入

log "ODBC Driver 18 を導入します"
apt_get update
apt_get install -y curl ca-certificates

# Microsoft のリポジトリ定義と署名鍵を、1 つのパッケージでまとめて登録します
REPO_DEB="$(mktemp --suffix=.deb)"
curl -sSLf -o "$REPO_DEB" \
    "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VERSION}/packages-microsoft-prod.deb"
dpkg -i "$REPO_DEB"
rm -f "$REPO_DEB"

apt_get update
# ACCEPT_EULA=Y を付けないと、ライセンス同意のプロンプトで止まります
ACCEPT_EULA=Y apt_get install -y msodbcsql18
# schema.sql を VM から適用できるように sqlcmd も入れます。
# PATH には入らないため、/opt/mssql-tools18/bin/sqlcmd と絶対パスで実行します
ACCEPT_EULA=Y apt_get install -y mssql-tools18

#### 2. nginx の導入

log "nginx を導入します"
apt_get install -y nginx

#### 3. uv の導入

INSTALLED_UV_VERSION=""
if [ -x "$UV_BIN" ]; then
    # uv --version は「uv 0.9.18 (...)」の形で出力します
    INSTALLED_UV_VERSION="$("$UV_BIN" --version | awk '{print $2}')"
fi

if [ "$INSTALLED_UV_VERSION" = "$UV_VERSION" ]; then
    log "uv ${UV_VERSION} は導入済みです"
else
    log "uv ${UV_VERSION} を導入します"
    # UV_INSTALL_DIR で全ユーザーから使える場所に入れます。既定の入れ先は実行ユーザーの
    # ホームで、systemd から起動するサービスからは見えません。
    # UV_NO_MODIFY_PATH=1 は、インストーラが PATH 設定用の env スクリプトを
    # /usr/local/bin/env に作り、/usr/bin/env を隠してしまうのを防ぎます
    curl -sSLf "https://astral.sh/uv/${UV_VERSION}/install.sh" |
        env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
fi

#### 4. 実行ユーザーの作成

log "実行ユーザー ${APP_USER} を作成します"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
    # root では動かさないため、ログインシェルを持たないシステムユーザーを用意します。
    # ホームをアプリのディレクトリに合わせ、uv のキャッシュもそこへ置きます
    useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
fi

#### 5. アプリの配置

log "アプリを ${APP_DIR} に配置します"
mkdir -p "$APP_DIR/.streamlit"
# 配置するファイルを列挙します。何が VM へ渡るのかが一目で分かります
cp "$SRC_DIR/app.py" "$SRC_DIR/schema.sql" "$SRC_DIR/pyproject.toml" "$SRC_DIR/uv.lock" \
    "$SRC_DIR/.python-version" "$SRC_DIR/.env.sample" "$APP_DIR/"
cp "$SRC_DIR/.streamlit/config.toml" "$APP_DIR/.streamlit/config.toml"

# 既にある .env は上書きしません。接続情報を記入したあとに再実行しても消えません
if [ ! -f "$APP_DIR/.env" ]; then
    cp "$SRC_DIR/.env.sample" "$APP_DIR/.env"
fi

chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
# 接続情報を含むため、所有者だけが読み書きできる権限にします
chmod 600 "$APP_DIR/.env"

#### 6. 依存パッケージのインストール

log "依存パッケージをインストールします"
# HOME を明示して、uv のキャッシュと仮想環境をアプリのディレクトリに収めます。
# --frozen は uv.lock のバージョンをそのまま使うための指定です
sudo -u "$APP_USER" env HOME="$APP_DIR" "$UV_BIN" sync --frozen --project "$APP_DIR"

#### 7. systemd サービスの設定

log "systemd サービスを設定します"
cp "$SCRIPT_DIR/todo.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
# 再実行したときに更新後の app.py を読み込ませるため、start ではなく restart します
systemctl restart "${SERVICE_NAME}.service"

# restart の成功は、ExecStart のプロセスを起動できたことしか示しません。直後に終了しても
# Restart=always が 5 秒ごとに起動し直すため、失敗が再起動のループに隠れます。
# 実際に応答するところまで確かめてから次へ進みます
if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    abort_with_log_hint "サービス ${SERVICE_NAME} が起動していません。" "$SERVICE_NAME"
fi

log "アプリの応答を待ちます（最大 $((HEALTH_CHECK_ATTEMPTS * HEALTH_CHECK_INTERVAL)) 秒）"
if ! wait_for_health "http://127.0.0.1:8501/_stcore/health"; then
    abort_with_log_hint \
        "アプリが応答しません（http://127.0.0.1:8501/_stcore/health）。" "$SERVICE_NAME"
fi

#### 8. nginx の設定

log "nginx を設定します"
cp "$SCRIPT_DIR/todo.nginx.conf" /etc/nginx/sites-available/todo.conf
ln -sfn /etc/nginx/sites-available/todo.conf /etc/nginx/sites-enabled/todo.conf
# 既定のサイトも default_server を宣言しているため、残すと設定検査で衝突します
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx

if ! systemctl is-active --quiet nginx; then
    abort_with_log_hint "nginx が起動していません。" "nginx"
fi

log "nginx 経由の応答を確認します"
# 80 番から同じヘルスチェックに届けば、リバースプロキシの経路が通っています。
# WebSocket の疎通は curl では確かめられないため、ブラウザでの確認が別途必要です
if ! wait_for_health "http://127.0.0.1/_stcore/health"; then
    abort_with_log_hint "nginx 経由でアプリに到達できません（http://127.0.0.1/）。" "nginx"
fi

#### 完了

log "セットアップが完了しました"
cat <<EOF

次の手順を実行してください。

  1. この VM の送信元 IP アドレスを確認します
       curl -s https://ifconfig.me
  2. Azure SQL Database のファイアウォール規則に、1. の IP アドレスを追加します
     （追加しないと、接続情報が正しくてもデータベースに到達できません）
  3. 接続情報を記入します
       sudo -u ${APP_USER} nano ${APP_DIR}/.env
  4. サービスを再起動します
       sudo systemctl restart ${SERVICE_NAME}
  5. ブラウザから VM のパブリック IP アドレスへアクセスします

テーブルをこの VM から作成する場合（開発 PC で実行済みなら不要です）:
  /opt/mssql-tools18/bin/sqlcmd -S <サーバー名>.database.windows.net \\
      -d <データベース名> -U <管理者ユーザー> -i ${APP_DIR}/schema.sql

ログを確認するコマンド:
  sudo journalctl -u ${SERVICE_NAME} -f

EOF
