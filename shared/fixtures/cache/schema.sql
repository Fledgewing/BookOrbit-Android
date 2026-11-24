-- The offline cache's database, version 1 (docs/design/sqlite-cache.md "Schema").
-- Orbit Companion creates it (CacheStore.SCHEMA, compared with this file by CacheStoreTest); the
-- plugin's tests build their fixture database from it (test_logic.lua). One statement per line.
CREATE TABLE meta (k TEXT PRIMARY KEY, v) WITHOUT ROWID;
CREATE TABLE books (id INTEGER PRIMARY KEY, item BLOB, detail BLOB, item_at INTEGER, detail_at INTEGER, search TEXT);
CREATE TABLE lists (identity TEXT PRIMARY KEY, kind TEXT, section TEXT, total INTEGER, head BLOB, fetched_at INTEGER, validated_at INTEGER) WITHOUT ROWID;
CREATE TABLE list_items (identity TEXT, pos INTEGER, book_id INTEGER, item BLOB, PRIMARY KEY (identity, pos)) WITHOUT ROWID;
CREATE INDEX list_items_book ON list_items (book_id);
CREATE TABLE entries (key TEXT PRIMARY KEY, path TEXT, body BLOB, fetched_at INTEGER, validated_at INTEGER, home INTEGER, stale INTEGER, bytes INTEGER) WITHOUT ROWID;
CREATE TABLE cover_keep (name TEXT PRIMARY KEY) WITHOUT ROWID;
CREATE TABLE tags (name BLOB PRIMARY KEY, n INTEGER) WITHOUT ROWID;
CREATE TABLE scopes (kind TEXT, id TEXT, label BLOB, n INTEGER, PRIMARY KEY (kind, id)) WITHOUT ROWID;
CREATE TABLE leave_out (rule TEXT, book_id INTEGER, PRIMARY KEY (rule, book_id)) WITHOUT ROWID;
CREATE TABLE jobs (kind TEXT, ref TEXT, state INTEGER, tries INTEGER, PRIMARY KEY (kind, ref)) WITHOUT ROWID;
