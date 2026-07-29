#!/usr/bin/env bash
#
# Azure VM（Ubuntu 24.04 LTS）に Todo アプリを配置して起動します。
#
#   sudo ./deploy/setup.sh
#
# 何度実行しても同じ結果になるように書いています。
# 記入済みの /opt/todo/src/.env は上書きしません。

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
REPO_DIR="$(dirname "$SCRIPT_DIR")"

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
        # アプリの /healthz は、要求を受け付けられる状態のとき本文に ok を返します。
        # DB には触らないため、接続情報が未記入でも 200 が返ります
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

#### 2. nginx の導入

log "nginx を導入します"
apt_get install -y nginx

#### 3. エディタの導入

log "エディタ（micro）を導入します"
# 接続情報を記入するために使います。vi や nano と違い、保存が Ctrl+S、終了が
# Ctrl+Q で、モードもメタキーの表記もありません。受講者が最初につまずく箇所を
# 減らすために入れます。
#   --no-install-recommends  推奨パッケージの xclip（X11 一式を引き込みます）を避けます
# 編集中の作業ファイルを対象のディレクトリに残さないため、中断しても
# 次回そのまま開けます（vi や nano の .swp が残る問題が起きません）
apt_get install -y --no-install-recommends micro

#### 4. uv の導入

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

#### 5. 実行ユーザーの作成

log "実行ユーザー ${APP_USER} を作成します"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
    # root では動かさないため、ログインシェルを持たないシステムユーザーを用意します。
    # ホームをアプリのディレクトリに合わせ、uv のキャッシュもそこへ置きます
    useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
fi

#### 6. アプリの配置

log "アプリを ${APP_DIR} に配置します"
mkdir -p "$APP_DIR/src/templates"
# 配置するファイルを列挙します。何が VM へ渡るのかが一目で分かります。
# アプリのソースは src/ 配下、uv プロジェクトの定義は $APP_DIR の直下です。
# src/.env は列挙しません。.gitignore の対象のため clone した $REPO_DIR には
# 存在しませんが、手で作られていても記入済みの src/.env を上書きしないためです
# （作成は下の if で行います）
cp "$REPO_DIR/src/app.py" "$REPO_DIR/src/.env.sample" "$APP_DIR/src/"
cp "$REPO_DIR/src/templates/index.html" "$REPO_DIR/src/templates/error.html" \
    "$APP_DIR/src/templates/"
cp "$REPO_DIR/pyproject.toml" "$REPO_DIR/uv.lock" "$REPO_DIR/.python-version" "$APP_DIR/"

# 既にある .env は上書きしません。接続情報を記入したあとに再実行しても消えません
if [ ! -f "$APP_DIR/src/.env" ]; then
    cp "$REPO_DIR/src/.env.sample" "$APP_DIR/src/.env"
fi

chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
# 接続情報を含むため、所有者だけが読み書きできる権限にします
chmod 600 "$APP_DIR/src/.env"

#### 7. 依存パッケージのインストール

log "依存パッケージをインストールします"
# HOME を明示して、uv のキャッシュと仮想環境をアプリのディレクトリに収めます。
#   --frozen  uv.lock のバージョンをそのまま使います
#   --no-dev  ruff と pytest を入れません。VM では使わないためです。
#             todo.service の uv run 側にも同じ指定が必要です。片方だけだと、
#             サービスの初回起動時に uv が入れ直し、ここで減らした意味がなくなります
sudo -u "$APP_USER" env HOME="$APP_DIR" "$UV_BIN" sync --frozen --no-dev --project "$APP_DIR"

#### 8. 旧バージョンの残骸の削除

log "旧バージョンの残骸を削除します"
# 依存のインストールが終わってから消します。**順序が重要です。**
# 先に消すと、set -e で uv sync が失敗したときに次の systemd unit の差し替えへ進めず、
# 旧 unit（ExecStart に streamlit run app.py を持つ）が削除済みのファイルを指したまま
# 残ります。動いていたサービスが二度と起動しない状態になります。
#
# 消す対象は 1 つずつ列挙します。rm -rf "$APP_DIR" のようなまとめ消しは、
# 記入済みの .env や作成済みの .venv まで消してしまいます
rm -f "$APP_DIR/app.py"
rm -rf "$APP_DIR/.streamlit"
# .env.sample は src/ 配下へ移りました。直下に残ると同じ内容が 2 か所に並び、
# 受講者がどちらを使うのか迷います
rm -f "$APP_DIR/.env.sample"
# schema.sql は配布しません。アプリがテーブルを作成するようになったためです。
# 旧バージョンから更新した VM に残っていると、手で実行する手順があるように見えます
rm -f "$APP_DIR/schema.sql" "$APP_DIR/src/schema.sql"
# $APP_DIR/.env（旧版）は消しません。接続情報を含むファイルを自動で消すと、
# 受講者が控えを失う場合があります。不要になった旨は完了メッセージで案内します

#### 9. systemd サービスの設定

log "systemd サービスを設定します"
cp "$SCRIPT_DIR/todo.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
# 直前の起動が短時間に 5 回失敗していると start-limit-hit になり、restart そのものが
# 拒否されます。daemon-reload では回数が消えないため、明示的に解除します。
# これがないと、app.py を直して再実行しても復旧できません
systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true

# 再実行したときに更新後の src/app.py を読み込ませるため、start ではなく restart します。
# 失敗したときは set -e でそのまま終わらせず、ログの見方を案内してから止めます
systemctl restart "${SERVICE_NAME}.service" ||
    abort_with_log_hint "サービス ${SERVICE_NAME} を起動できませんでした。" "$SERVICE_NAME"

# restart の成功は、ExecStart のプロセスを起動できたことしか示しません。直後に終了しても
# Restart=always が 5 秒ごとに起動し直すため、失敗が再起動のループに隠れます。
# 実際に応答するところまで確かめてから次へ進みます
if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    abort_with_log_hint "サービス ${SERVICE_NAME} が起動していません。" "$SERVICE_NAME"
fi

log "アプリの応答を待ちます（最大 $((HEALTH_CHECK_ATTEMPTS * HEALTH_CHECK_INTERVAL)) 秒）"
# 確認先は / ではなく /healthz です。/ はデータベースに接続するため、この時点では
# .env が未記入で 503 が返り、正しくセットアップできてもここで失敗扱いになります
if ! wait_for_health "http://127.0.0.1:8000/healthz"; then
    abort_with_log_hint \
        "アプリが応答しません（http://127.0.0.1:8000/healthz）。" "$SERVICE_NAME"
fi

#### 10. nginx の設定

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
# 80 番から同じ /healthz に届けば、nginx から gunicorn への経路が通っています。
# ここも / は使いません（.env 未記入の状態では 503 になります）
if ! wait_for_health "http://127.0.0.1/healthz"; then
    abort_with_log_hint \
        "nginx 経由でアプリに到達できません（http://127.0.0.1/healthz）。" "nginx"
fi

#### 完了

log "セットアップが完了しました"
cat <<EOF

次の手順を実行してください。

  1. この VM の送信元 IP アドレスを確認します
       curl -s https://api.ipify.org
  2. Azure SQL Database のファイアウォール規則に、1. の IP アドレスを追加します
     （追加しないと、接続情報が正しくてもデータベースに到達できません）
  3. 接続情報を記入します（保存は Ctrl+S、終了は Ctrl+Q）
       sudo -u ${APP_USER} micro ${APP_DIR}/src/.env
  4. サービスを再起動します
       sudo systemctl restart ${SERVICE_NAME}
  5. ブラウザから VM のパブリック IP アドレスへアクセスします
     （テーブルは最初のアクセスのときにアプリが作成します）

ログを確認するコマンド:
  sudo journalctl -u ${SERVICE_NAME} -f
EOF

# 旧版が置いていった .env は、接続情報を含むため自動では消しません
if [ -f "$APP_DIR/.env" ]; then
    cat <<EOF

${APP_DIR}/.env は旧バージョンが使っていたファイルで、現在は参照されません。
接続情報を ${APP_DIR}/src/.env へ写したあと、次のコマンドで削除してください。
  sudo rm ${APP_DIR}/.env
EOF
fi

echo ""
