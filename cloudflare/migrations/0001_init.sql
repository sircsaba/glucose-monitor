-- Glucose server tables (Cloudflare D1 / SQLite).
-- The full record is kept as JSON text in `doc`; other columns are for searching.

CREATE TABLE IF NOT EXISTS entries (
  id       TEXT PRIMARY KEY,
  date_ms  INTEGER NOT NULL,
  type     TEXT NOT NULL DEFAULT 'sgv',
  doc      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_entries_date ON entries (date_ms);
CREATE INDEX IF NOT EXISTS idx_entries_type_date ON entries (type, date_ms);

CREATE TABLE IF NOT EXISTS treatments (
  id          TEXT PRIMARY KEY,
  created_ms  INTEGER NOT NULL,
  event_type  TEXT NOT NULL DEFAULT '',
  sync_id     TEXT,
  doc         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_treat_created ON treatments (created_ms);
CREATE INDEX IF NOT EXISTS idx_treat_type ON treatments (event_type, created_ms);
CREATE INDEX IF NOT EXISTS idx_treat_sync ON treatments (sync_id);

CREATE TABLE IF NOT EXISTS devicestatus (
  id          TEXT PRIMARY KEY,
  created_ms  INTEGER NOT NULL,
  doc         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ds_created ON devicestatus (created_ms);

CREATE TABLE IF NOT EXISTS profile (
  id          TEXT PRIMARY KEY,
  created_ms  INTEGER NOT NULL,
  start_ms    INTEGER NOT NULL,
  doc         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_profile_start ON profile (start_ms);

-- Bookmarks for copying from Nightscout.
CREATE TABLE IF NOT EXISTS meta (
  k  TEXT PRIMARY KEY,
  v  TEXT NOT NULL
);
