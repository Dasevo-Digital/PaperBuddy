import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Schema-Migrationen. Neue Migrationen nur anhängen, nie ändern.
const _migrations = <String>[
  '''
  CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    first_name TEXT NOT NULL DEFAULT '',
    last_name TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL DEFAULT '',
    is_superuser INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1,
    date_joined TEXT NOT NULL
  );
  CREATE TABLE tokens (
    key TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created TEXT NOT NULL
  );
  CREATE TABLE correspondents (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    match TEXT NOT NULL DEFAULT '',
    matching_algorithm INTEGER NOT NULL DEFAULT 6,
    is_insensitive INTEGER NOT NULL DEFAULT 1,
    owner INTEGER REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE TABLE document_types (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    match TEXT NOT NULL DEFAULT '',
    matching_algorithm INTEGER NOT NULL DEFAULT 6,
    is_insensitive INTEGER NOT NULL DEFAULT 1,
    owner INTEGER REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE TABLE storage_paths (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    path TEXT NOT NULL DEFAULT '',
    match TEXT NOT NULL DEFAULT '',
    matching_algorithm INTEGER NOT NULL DEFAULT 6,
    is_insensitive INTEGER NOT NULL DEFAULT 1,
    owner INTEGER REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE TABLE tags (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    color TEXT NOT NULL DEFAULT '#a6cee3',
    is_inbox_tag INTEGER NOT NULL DEFAULT 0,
    match TEXT NOT NULL DEFAULT '',
    matching_algorithm INTEGER NOT NULL DEFAULT 6,
    is_insensitive INTEGER NOT NULL DEFAULT 1,
    owner INTEGER REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE TABLE documents (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT NOT NULL DEFAULT '',
    correspondent_id INTEGER REFERENCES correspondents(id) ON DELETE SET NULL,
    document_type_id INTEGER REFERENCES document_types(id) ON DELETE SET NULL,
    storage_path_id INTEGER REFERENCES storage_paths(id) ON DELETE SET NULL,
    created TEXT NOT NULL,
    modified TEXT NOT NULL,
    added TEXT NOT NULL,
    archive_serial_number INTEGER UNIQUE,
    original_filename TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    checksum TEXT NOT NULL UNIQUE,
    original_path TEXT NOT NULL,
    archive_path TEXT,
    thumbnail_path TEXT,
    page_count INTEGER,
    owner INTEGER REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE TABLE document_tags (
    document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (document_id, tag_id)
  );
  CREATE TABLE notes (
    id INTEGER PRIMARY KEY,
    document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    note TEXT NOT NULL,
    created TEXT NOT NULL,
    user_id INTEGER REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE TABLE tasks (
    id INTEGER PRIMARY KEY,
    task_id TEXT NOT NULL UNIQUE,
    task_file_name TEXT,
    date_created TEXT NOT NULL,
    date_done TEXT,
    status TEXT NOT NULL,
    result TEXT,
    acknowledged INTEGER NOT NULL DEFAULT 0,
    related_document INTEGER REFERENCES documents(id) ON DELETE SET NULL,
    owner INTEGER REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE TABLE ui_settings (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    settings TEXT NOT NULL DEFAULT '{}'
  );
  CREATE VIRTUAL TABLE documents_fts USING fts5(
    title, content, content='documents', content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
  );
  CREATE TRIGGER documents_ai AFTER INSERT ON documents BEGIN
    INSERT INTO documents_fts(rowid, title, content)
    VALUES (new.id, new.title, new.content);
  END;
  CREATE TRIGGER documents_ad AFTER DELETE ON documents BEGIN
    INSERT INTO documents_fts(documents_fts, rowid, title, content)
    VALUES ('delete', old.id, old.title, old.content);
  END;
  CREATE TRIGGER documents_au AFTER UPDATE OF title, content ON documents BEGIN
    INSERT INTO documents_fts(documents_fts, rowid, title, content)
    VALUES ('delete', old.id, old.title, old.content);
    INSERT INTO documents_fts(rowid, title, content)
    VALUES (new.id, new.title, new.content);
  END;
  ''',
  // 2: Mehrbenutzer, Objektrechte, Papierkorb, Custom Fields, gespeicherte Ansichten
  '''
  ALTER TABLE users ADD COLUMN is_staff INTEGER NOT NULL DEFAULT 0;
  UPDATE users SET is_staff = 1 WHERE is_superuser = 1;
  CREATE TABLE groups (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
  );
  CREATE TABLE user_groups (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, group_id)
  );
  CREATE TABLE user_permissions (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    permission TEXT NOT NULL,
    PRIMARY KEY (user_id, permission)
  );
  CREATE TABLE group_permissions (
    group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    permission TEXT NOT NULL,
    PRIMARY KEY (group_id, permission)
  );
  CREATE TABLE object_permissions (
    object_type TEXT NOT NULL,
    object_id INTEGER NOT NULL,
    permission TEXT NOT NULL CHECK (permission IN ('view', 'change')),
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    group_id INTEGER REFERENCES groups(id) ON DELETE CASCADE,
    CHECK ((user_id IS NULL) <> (group_id IS NULL))
  );
  CREATE INDEX object_permissions_lookup ON object_permissions(object_type, object_id);
  ALTER TABLE documents ADD COLUMN deleted_at TEXT;
  CREATE INDEX documents_deleted ON documents(deleted_at);
  CREATE TABLE custom_fields (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    data_type TEXT NOT NULL,
    extra_data TEXT NOT NULL DEFAULT '{}',
    created TEXT NOT NULL
  );
  CREATE TABLE document_custom_fields (
    id INTEGER PRIMARY KEY,
    document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    field_id INTEGER NOT NULL REFERENCES custom_fields(id) ON DELETE CASCADE,
    value TEXT,
    UNIQUE (document_id, field_id)
  );
  CREATE TABLE saved_views (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    show_on_dashboard INTEGER NOT NULL DEFAULT 0,
    show_in_sidebar INTEGER NOT NULL DEFAULT 0,
    sort_field TEXT,
    sort_reverse INTEGER NOT NULL DEFAULT 0,
    filter_rules TEXT NOT NULL DEFAULT '[]',
    page_size INTEGER,
    display_mode TEXT,
    display_fields TEXT,
    owner INTEGER REFERENCES users(id) ON DELETE CASCADE
  );
  ''',
  // 3: Workflows
  '''
  CREATE TABLE workflows (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    sort_order INTEGER NOT NULL DEFAULT 0,
    enabled INTEGER NOT NULL DEFAULT 1
  );
  CREATE TABLE workflow_triggers (
    id INTEGER PRIMARY KEY,
    workflow_id INTEGER NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
    data TEXT NOT NULL
  );
  CREATE TABLE workflow_actions (
    id INTEGER PRIMARY KEY,
    workflow_id INTEGER NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
    sort_order INTEGER NOT NULL DEFAULT 0,
    data TEXT NOT NULL
  );
  CREATE TABLE workflow_runs (
    id INTEGER PRIMARY KEY,
    workflow_id INTEGER NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
    document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    trigger_type INTEGER NOT NULL,
    run_at TEXT NOT NULL
  );
  CREATE INDEX workflow_runs_lookup ON workflow_runs(workflow_id, document_id);
  ''',
  // 4: Mail-Abruf
  '''
  CREATE TABLE mail_accounts (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    imap_server TEXT NOT NULL,
    imap_port INTEGER,
    imap_security INTEGER NOT NULL DEFAULT 2,
    username TEXT NOT NULL,
    password TEXT NOT NULL,
    character_set TEXT NOT NULL DEFAULT 'UTF-8',
    owner INTEGER REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE TABLE mail_rules (
    id INTEGER PRIMARY KEY,
    account_id INTEGER NOT NULL REFERENCES mail_accounts(id) ON DELETE CASCADE,
    sort_order INTEGER NOT NULL DEFAULT 0,
    enabled INTEGER NOT NULL DEFAULT 1,
    data TEXT NOT NULL,
    owner INTEGER REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE TABLE mail_processed (
    id INTEGER PRIMARY KEY,
    rule_id INTEGER NOT NULL REFERENCES mail_rules(id) ON DELETE CASCADE,
    folder TEXT NOT NULL,
    uid INTEGER NOT NULL,
    message_id TEXT,
    subject TEXT,
    received TEXT,
    processed TEXT NOT NULL,
    status TEXT NOT NULL,
    error TEXT
  );
  CREATE INDEX mail_processed_lookup ON mail_processed(rule_id, folder, uid);
  ''',
  // 5: Freigabelinks
  '''
  CREATE TABLE share_links (
    id INTEGER PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    expiration TEXT,
    file_version TEXT NOT NULL DEFAULT 'archive',
    created TEXT NOT NULL,
    owner INTEGER REFERENCES users(id) ON DELETE CASCADE
  );
  ''',
  // 6: Verlauf und Versionen
  '''
  CREATE TABLE document_history (
    id INTEGER PRIMARY KEY,
    document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    timestamp TEXT NOT NULL,
    action TEXT NOT NULL,
    changes TEXT NOT NULL DEFAULT '{}',
    actor_id INTEGER REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE INDEX document_history_doc ON document_history(document_id, timestamp);
  CREATE TABLE document_versions (
    id INTEGER PRIMARY KEY,
    document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    added TEXT NOT NULL,
    version_label TEXT,
    checksum TEXT NOT NULL,
    is_root INTEGER NOT NULL DEFAULT 0,
    original_filename TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    original_path TEXT NOT NULL,
    archive_path TEXT,
    thumbnail_path TEXT,
    content TEXT NOT NULL DEFAULT '',
    page_count INTEGER
  );
  CREATE INDEX document_versions_doc ON document_versions(document_id);
  ''',
  // 7: API v10 (Herkunft von Aufgaben)
  '''
  ALTER TABLE tasks ADD COLUMN trigger_source TEXT NOT NULL DEFAULT 'api_upload';
  ''',
];

Database openDatabase(String path) {
  Directory(p.dirname(path)).createSync(recursive: true);
  final db = sqlite3.open(path);
  db.execute('PRAGMA journal_mode = WAL;');
  db.execute('PRAGMA foreign_keys = ON;');
  migrate(db);
  return db;
}

Database openInMemoryDatabase() {
  final db = sqlite3.openInMemory();
  db.execute('PRAGMA foreign_keys = ON;');
  migrate(db);
  return db;
}

void migrate(Database db) {
  final version = db.select('PRAGMA user_version;').first.columnAt(0) as int;
  for (var i = version; i < _migrations.length; i++) {
    db.execute('BEGIN;');
    try {
      db.execute(_migrations[i]);
      db.execute('PRAGMA user_version = ${i + 1};');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }
}

String nowIso() => DateTime.now().toUtc().toIso8601String();
