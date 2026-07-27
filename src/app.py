"""Flask と Azure SQL Database で作る Todo アプリです。"""

import os
import time
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path

import pyodbc
from dotenv import load_dotenv
from flask import Flask, Response, abort, redirect, render_template, request, url_for
from sqlalchemy import URL, Connection, Engine, create_engine, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.pool import NullPool

# 最初の接続より前に無効化します。pyodbc 既定のプールが実接続を保持すると、
# Azure SQL のセッション数が 0 にならず、自動一時停止が働きません
pyodbc.pooling = False

BASE_DIR = Path(__file__).resolve().parent
JST = timezone(timedelta(hours=9))
TITLE_MAX_LENGTH = 255  # DB の列長 NVARCHAR(255) と一致させます
# 1 接続あたりの最悪の待ち時間は 5 × 10 秒（試行）+ 4 × 5 秒（待機）= 70 秒です。
# 一覧の表示は接続を 2 回張ることがあるため、1 リクエストでは 140 秒を見込みます。
# gunicorn の --timeout 150 はこの 140 秒より長くしてあります。
# 試行を細かく刻むのは、再開した瞬間をできるだけ早く捉えるためです。回数を減らして
# 1 回あたりを長くすると、再開済みなのに前の試行の待ち時間が残る時間が増えます
CONNECT_TIMEOUT_SECONDS = 10
RETRY_ATTEMPTS = 5
RETRY_WAIT_SECONDS = 5
# 停止した Azure SQL Database が再開する間に返るエラーです。どちらも待てば解決します。
# HYT00 はログインのタイムアウトを表す SQLSTATE です。再開中の接続はすぐエラーにならず、
# 応答しないまま待たされるため、CONNECT_TIMEOUT_SECONDS が先に切れてこちらになります。
# サーバー名の誤りやネットワークの不達も同じ HYT00 です。区別できないため待ちます
RESUMING_SQLSTATE = "HYT00"
# 40613（データベースが利用できない）は SQLSTATE ではなく、pyodbc が本文の末尾へ
# 括弧付きで付けるネイティブのエラー番号です。括弧ごと一致させます。
# このときの SQLSTATE は HY000（一般的なエラー）で、他の障害とも共通するため使えません
RESUMING_ERROR_NUMBER = "(40613)"
DB_ERROR_MESSAGE = (
    "データベースに接続できません。src/.env の接続情報と、Azure SQL Database の"
    "ファイアウォール規則にクライアント IP が登録されているかを確認してください。"
    "待っても復旧しない場合は、無料 vCore 秒の残量を確認してください。"
    "枯渇による停止は翌月まで再開しません。"
)
SCHEMA_MISSING_MESSAGE = (
    "テーブル dbo.todos がありません。src/schema.sql を実行してから、"
    "この画面を再読み込みしてください。"
)

# 引数なしの load_dotenv() はカレントディレクトリから上へ探索するため、
# 起動場所によって .env を読めません。app.py からの相対で指定します
load_dotenv(BASE_DIR / ".env")

app = Flask(__name__)

_engine: Engine | None = None
_table_verified = False


@app.before_request
def reject_cross_site_write() -> None:
    """他のサイトから送られた POST を拒否します。"""
    # 認証も Cookie もないため、CSRF トークンを結び付ける先がありません。
    # Sec-Fetch-Site はブラウザだけが付けられる禁止ヘッダ名で、スクリプトから
    # 偽装できないため、依存を増やさずにクロスサイトの書き込みを弾けます。
    # ヘッダを送らない古いブラウザや curl は通します（移植元と同じ挙動です）
    if request.method == "POST" and request.headers.get("Sec-Fetch-Site") == "cross-site":
        abort(403)


def build_conn_url() -> URL:
    """環境変数から接続 URL を組み立てます。"""
    # f-string で組み立てると、パスワードに含まれる @ や : がホストの区切りと
    # 解釈されて接続に失敗します。URL.create() は各要素をエスケープします
    return URL.create(
        "mssql+pyodbc",
        username=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        host=os.environ["DB_HOST"],
        port=1433,
        database=os.environ["DB_NAME"],
        query={
            "driver": "ODBC Driver 18 for SQL Server",
            "Authentication": "SqlPassword",
            "Encrypt": "yes",
            "TrustServerCertificate": "no",
        },
    )


def get_engine() -> Engine:
    """Engine を生成します。実接続は SQL を実行するときに張られます。"""
    global _engine
    # import 時ではなくリクエストの処理中に生成します。import 時に生成すると、
    # .env が未記入のときにワーカーが起動できず、案内ではなく 502 が出ます
    if _engine is None:
        _engine = create_engine(
            build_conn_url(),
            # 接続を保持するとセッション数が 0 にならず、自動一時停止が働きません
            poolclass=NullPool,
            # ODBC の SQL_ATTR_LOGIN_TIMEOUT に設定されます。接続文字列の
            # Connection Timeout は ODBC のキーワードではないため使えません
            connect_args={"timeout": CONNECT_TIMEOUT_SECONDS},
        )
    return _engine


def is_resuming_error(error: DBAPIError) -> bool:
    """データベースの再開を待てば解決するエラーかどうかを判定します。"""
    # 例外型はドライバ依存で一定しないため、SQLSTATE とエラー番号で判定します。
    # メッセージ全体を部分一致で調べてはいけません。認証の失敗（SQLSTATE 28000）の
    # 本文にはユーザー名が入るため、student40613 のような名前の受講者が
    # パスワードを間違えたときに、待っても解決しないエラーを待ってしまいます
    sqlstate = error.orig.args[0] if error.orig.args else ""
    return sqlstate == RESUMING_SQLSTATE or RESUMING_ERROR_NUMBER in str(error.orig)


def connect_with_retry(engine: Engine) -> Connection:
    """接続の確立だけを再試行します。SQL の実行後は再試行しません。"""
    # SQL の実行まで再試行すると、INSERT がコミット済みで応答だけ失われた場合に
    # 2 回目の INSERT が走り、Todo が重複します。重複を検出する手段はありません
    for attempt in range(RETRY_ATTEMPTS):
        try:
            return engine.connect()
        except DBAPIError as e:
            # 再開待ち以外（認証やファイアウォールの誤り）は待っても解決しないため、
            # すぐに投げます。誤った資格情報は 18456、規則の不足は 40615 で即座に返ります
            if not is_resuming_error(e):
                raise
            if attempt == RETRY_ATTEMPTS - 1:
                raise
            time.sleep(RETRY_WAIT_SECONDS)


def execute_sql(sql: str, params: dict | None = None, *, fetch: bool = False) -> list | None:
    """SQL を実行します。停止中のデータベースは再開を待って接続し直します。"""
    # 参照系も conn.begin() で囲みます。明示的にコミットしない限りロールバックされるため、
    # すべて同じ形にすることでコミット忘れが原理的に起きません
    with connect_with_retry(get_engine()) as conn, conn.begin():
        result = conn.execute(text(sql), params or {})
        return result.all() if fetch else None


def table_exists() -> bool:
    """dbo.todos が存在するかを確認します。"""
    global _table_verified
    # 接続をプールしないため、確認のたびに ODBC のログインが 1 回増えます。
    # 一度あることを確認できたら以降は問い合わせません。「ない」結果は覚えないので、
    # schema.sql を実行したあとは次の再読み込みで反映されます
    if _table_verified:
        return True
    # 例外の種類では判定しません。ProgrammingError には構文エラーや列名の誤りも
    # 含まれるため、「テーブルがない」と誤って案内する可能性があります
    rows = execute_sql("SELECT OBJECT_ID(N'dbo.todos', N'U') AS object_id", fetch=True)
    _table_verified = rows[0].object_id is not None
    return _table_verified


def fetch_todos() -> list:
    """Todo を作成日時の降順で取得します。"""
    # created_at は秒単位のため同時刻になり得ます。id を第 2 キーにして順序を一定にします
    return execute_sql(
        "SELECT id, title, completed, created_at FROM dbo.todos ORDER BY created_at DESC, id DESC",
        fetch=True,
    )


def add_todo(title: str) -> None:
    """Todo を追加します。"""
    execute_sql("INSERT INTO dbo.todos (title) VALUES (:title)", {"title": title})


def set_completed(todo_id: int, completed: bool) -> None:
    """完了状態を指定した値に変更します。"""
    execute_sql(
        "UPDATE dbo.todos SET completed = :completed WHERE id = :id",
        {"completed": completed, "id": todo_id},
    )


def delete_todo(todo_id: int) -> None:
    """Todo を削除します。"""
    execute_sql("DELETE FROM dbo.todos WHERE id = :id", {"id": todo_id})


def to_jst(dt: datetime) -> datetime:
    """UTC で保存された日時を JST に変換します。"""
    # DATETIME2 はタイムゾーンを持たないため、UTC と解釈してから変換します
    return dt.replace(tzinfo=UTC).astimezone(JST)


def to_display_todos(rows: list) -> list[dict]:
    """取得した行を、テンプレートへ渡す形に整えます。"""
    # JST への変換はここで済ませます。Jinja2 は辞書のキーも todo.created_at_jst の
    # 記法で解決するため、移植元のテンプレートをそのまま使えます
    return [
        {
            "id": row.id,
            "title": row.title,
            "completed": row.completed,
            "created_at_jst": to_jst(row.created_at),
        }
        for row in rows
    ]


def render_todo_list(error: str | None = None, status: int = 200) -> tuple[str, int]:
    """Todo の一覧を描画します。入力を拒否したときはメッセージと HTTP 400 を渡します。"""
    try:
        if not table_exists():
            return render_template("error.html", message=SCHEMA_MISSING_MESSAGE), 503
        todos = to_display_todos(fetch_todos())
    except Exception:
        # 例外の詳細はサーバーログにだけ記録します。ODBC のエラーメッセージには
        # サーバー名やユーザー名が含まれるためです
        app.logger.exception("データベースへの接続に失敗しました")
        return render_template("error.html", message=DB_ERROR_MESSAGE), 503
    return render_template("index.html", todos=todos, error=error), status


@app.get("/")
def index() -> tuple[str, int]:
    """Todo の一覧を表示します。"""
    return render_todo_list()


@app.post("/add")
def add() -> Response | tuple[str, int]:
    """Todo を追加します。入力を拒否したときは一覧を HTTP 400 で再描画します。"""
    # テンプレートの required と maxlength はブラウザの支援でしかないため、
    # curl や開発者ツールから回避できます。サーバー側でも検証します
    title = request.form.get("title", "").strip()
    if not title:
        return render_todo_list(error="タスク名を入力してください。", status=400)
    # 黙って切り詰めると、保存された内容が入力と違うことに利用者が気づけません。
    # NVARCHAR(255) が数えるのは UTF-16 の単位です。絵文字のような BMP 外の文字は
    # 1 文字で 2 単位を使うため、len() では列長を超える入力を通してしまいます
    if len(title.encode("utf-16-le")) // 2 > TITLE_MAX_LENGTH:
        return render_todo_list(
            error=f"タスク名は {TITLE_MAX_LENGTH} 文字以内で入力してください。", status=400
        )
    try:
        add_todo(title)
    except Exception:
        app.logger.exception("タスクの追加に失敗しました")
        return render_template("error.html", message=DB_ERROR_MESSAGE), 503
    # 結果を直接描画すると、ブラウザの再読み込みで同じ追加が再送されます
    return redirect(url_for("index"))


@app.post("/complete/<int:todo_id>")
def complete(todo_id: int) -> Response | tuple[str, int]:
    """完了状態を変更し、一覧へリダイレクトします。"""
    # 反転ではなくフォームから受けた値にします。反転は現在値に依存するため、
    # 二重クリックやリロードで意図せず再反転します
    completed = request.form.get("completed") == "1"
    try:
        set_completed(todo_id, completed)
    except Exception:
        app.logger.exception("完了状態の変更に失敗しました")
        return render_template("error.html", message=DB_ERROR_MESSAGE), 503
    return redirect(url_for("index"))


@app.post("/delete/<int:todo_id>")
def delete(todo_id: int) -> Response | tuple[str, int]:
    """Todo を削除し、一覧へリダイレクトします。"""
    try:
        delete_todo(todo_id)
    except Exception:
        app.logger.exception("削除に失敗しました")
        return render_template("error.html", message=DB_ERROR_MESSAGE), 503
    return redirect(url_for("index"))


@app.get("/healthz")
def healthz() -> tuple[str, int]:
    """死活確認に応答します。"""
    # DB に触りません。deploy/setup.sh は .env の記入前に起動を確認するためです
    return "ok", 200


if __name__ == "__main__":
    # デバッグモードは使いません。Werkzeug のデバッガは画面から任意のコードを実行できます。
    # macOS で Address already in use になる場合は、AirPlay レシーバーが 5000 番を
    # 使っています。システム設定の「一般 > AirDrop と Handoff」でオフにしてください
    app.run(host="127.0.0.1", port=5000)
