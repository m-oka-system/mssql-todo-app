"""Streamlit と Azure SQL Database で作る Todo アプリです。"""

import logging
import os
import time
from datetime import UTC, datetime, timedelta, timezone

import pyodbc
import streamlit as st
from dotenv import load_dotenv
from sqlalchemy import URL, Connection, Engine, create_engine, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.pool import NullPool

# 最初の接続より前に無効化します。pyodbc 既定のプールが実接続を保持すると、
# Azure SQL のセッション数が 0 にならず、自動一時停止が働きません
pyodbc.pooling = False

JST = timezone(timedelta(hours=9))
TITLE_MAX_LENGTH = 255  # DB の列長 NVARCHAR(255) と一致させます
RETRY_ATTEMPTS = 5
RETRY_WAIT_SECONDS = 15

logger = logging.getLogger(__name__)


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


@st.cache_resource
def get_engine() -> Engine:
    """Engine を生成します。実接続は SQL を実行するときに張られます。"""
    # 再接続ボタンで .env の修正を反映するため、ここで読み直します。
    # override=True がないと、プロセス内の古い環境変数が優先されます
    load_dotenv(override=True)
    # 接続確認やリトライはここに置きません。@st.cache_resource は初回しか
    # 実行されないため、起動後にデータベースが自動停止すると対応できません
    return create_engine(
        build_conn_url(),
        # 接続を保持するとセッション数が 0 にならず、自動一時停止が働きません
        poolclass=NullPool,
        # ODBC の SQL_ATTR_LOGIN_TIMEOUT に設定されます。接続文字列の
        # Connection Timeout は ODBC のキーワードではないため使えません
        connect_args={"timeout": 60},
    )


def connect_with_retry(engine: Engine) -> Connection:
    """接続の確立だけを再試行します。SQL の実行後は再試行しません。"""
    # SQL の実行まで再試行すると、INSERT がコミット済みで応答だけ失われた場合に
    # 2 回目の INSERT が走り、Todo が重複します。重複を検出する手段はありません
    for attempt in range(RETRY_ATTEMPTS):
        try:
            return engine.connect()
        except DBAPIError as e:
            # 40613 がどの例外型になるかはドライバ依存のため、エラー番号で判定します。
            # 40613 以外（認証やファイアウォールの誤り）は待っても解決しないため、すぐに投げます
            if "40613" not in str(e.orig) or attempt == RETRY_ATTEMPTS - 1:
                raise
            time.sleep(RETRY_WAIT_SECONDS)


def execute_sql(sql: str, params: dict | None = None, *, fetch: bool = False) -> list | None:
    """SQL を実行します。停止中のデータベース（40613）は再開を待って接続し直します。"""
    # 参照系も conn.begin() で囲みます。明示的にコミットしない限りロールバックされるため、
    # すべて同じ形にすることでコミット忘れが原理的に起きません
    with connect_with_retry(get_engine()) as conn, conn.begin():
        result = conn.execute(text(sql), params or {})
        return result.all() if fetch else None


@st.cache_data
def table_exists() -> bool:
    """dbo.todos が存在するかを確認します。"""
    # 例外の種類では判定しません。ProgrammingError には構文エラーや列名の誤りも
    # 含まれるため、「テーブルがない」と誤って案内する可能性があります
    rows = execute_sql("SELECT OBJECT_ID(N'dbo.todos', N'U') AS object_id", fetch=True)
    return rows[0].object_id is not None


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


def on_toggle(todo_id: int) -> None:
    """チェックボックスが操作されたときに完了状態を保存します。"""
    try:
        # ウィジェットの新しい値は session_state から読みます
        set_completed(todo_id, st.session_state[f"chk_{todo_id}"])
    except Exception:
        # コールバックで例外が送出されるとスクリプト本体が実行されず、
        # 一覧そのものが消えた画面になるため、必ず捕捉します
        logger.exception("完了状態の変更に失敗しました")
        st.error("完了状態を変更できませんでした。しばらく待ってから操作してください。")


st.title("Todo アプリ")

try:
    with st.spinner("データベースに接続しています。停止状態からの復帰には最大 1 分かかります。"):
        exists = table_exists()
        todos = fetch_todos() if exists else []
except Exception:
    # 例外の詳細はサーバーログにだけ記録します。ODBC のエラーメッセージには
    # サーバー名やユーザー名が含まれるためです
    logger.exception("データベースへの接続に失敗しました")
    st.error(
        "データベースに接続できません。接続情報とファイアウォール規則を確認してください。"
        "復旧しない場合は、無料 vCore 秒の残量を確認してください。"
        "枯渇による停止は翌月まで再開しません。"
    )
    if st.button("再接続"):
        get_engine.clear()
        table_exists.clear()
        st.rerun()
    st.stop()

# 正常系の分岐は、例外処理と分けて try の外に置きます
if not exists:
    st.error("テーブル dbo.todos がありません。schema.sql を実行してください。")
    # 確認結果はキャッシュされるため、ボタンがないとアプリの再起動が必要になります
    if st.button("テーブルを再確認"):
        table_exists.clear()
        st.rerun()
    st.stop()

with st.form("add_todo_form", clear_on_submit=True):
    title = st.text_input("タスク名", max_chars=TITLE_MAX_LENGTH)
    submitted = st.form_submit_button("追加")

if submitted:
    # 空白だけの入力を弾くため、前後の空白を除いてから検証します
    title = title.strip()
    if not title:
        st.warning("タスク名を入力してください。")
    else:
        try:
            add_todo(title)
        except Exception:
            logger.exception("タスクの追加に失敗しました")
            st.error("タスクを追加できませんでした。しばらく待ってから操作してください。")
        else:
            st.rerun()

for todo in todos:
    # ウィジェットの生成前に DB の値を反映します。key が既にある場合、
    # value 引数は無視されるため、他のセッションによる変更が表示されません
    st.session_state[f"chk_{todo.id}"] = todo.completed

    with st.container(border=True):
        c1, c2, c3, c4 = st.columns([1, 10, 5, 1], vertical_alignment="center")
        c1.checkbox(
            "完了",
            key=f"chk_{todo.id}",
            label_visibility="collapsed",
            on_change=on_toggle,
            args=(todo.id,),
        )
        c2.markdown(f"~~{todo.title}~~" if todo.completed else todo.title)
        c3.caption(to_jst(todo.created_at).strftime("%Y/%m/%d %H:%M"))
        if c4.button("🗑️", key=f"del_{todo.id}"):
            try:
                delete_todo(todo.id)
            except Exception:
                logger.exception("削除に失敗しました")
                st.error("削除できませんでした。しばらく待ってから操作してください。")
            else:
                st.rerun()
