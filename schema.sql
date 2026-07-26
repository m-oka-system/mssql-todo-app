-- Todo アプリのテーブル定義です。管理者が一度だけ実行します。
-- アプリのコードは DDL を実行しません。複数の VM が同時に起動すると競合するためです。
--
-- 実行例:
--   sqlcmd -S <サーバー名>.database.windows.net -d todo -U <管理者ユーザー> -i schema.sql
--
-- -P オプションは使いません。パスワードがシェル履歴とプロセス一覧に残るためです。
-- -U だけを指定すると、sqlcmd が非表示の対話プロンプトでパスワードを尋ねます。

-- SQL Server には CREATE TABLE IF NOT EXISTS がないため、OBJECT_ID で存在を確認します。
-- 第 2 引数の N'U' は「ユーザーテーブル」を意味します。
IF OBJECT_ID(N'dbo.todos', N'U') IS NULL
CREATE TABLE dbo.todos (
    id         INT IDENTITY(1,1) PRIMARY KEY,
    title      NVARCHAR(255) NOT NULL,
    completed  BIT NOT NULL DEFAULT 0,
    -- SYSUTCDATETIME() は UTC を返します。表示するときに JST へ変換します
    created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);
