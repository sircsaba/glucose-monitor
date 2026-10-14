-- Glucose server tables (MySQL / MariaDB).
-- Run once in phpMyAdmin: select your database, open the SQL tab, paste this file, click Go.
-- The full record is kept as JSON text in `doc`; the other columns are for fast searching.

CREATE TABLE IF NOT EXISTS entries (
  id         VARCHAR(64)  NOT NULL PRIMARY KEY,
  date_ms    BIGINT       NOT NULL,
  type       VARCHAR(16)  NOT NULL DEFAULT 'sgv',
  doc        LONGTEXT     NOT NULL,
  updated_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_entries_date (date_ms),
  KEY idx_entries_type_date (type, date_ms)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS treatments (
  id         VARCHAR(64)  NOT NULL PRIMARY KEY,
  created_ms BIGINT       NOT NULL,
  event_type VARCHAR(64)  NOT NULL DEFAULT '',
  sync_id    VARCHAR(128) NULL,
  doc        LONGTEXT     NOT NULL,
  updated_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_treat_created (created_ms),
  KEY idx_treat_type (event_type, created_ms),
  KEY idx_treat_sync (sync_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS devicestatus (
  id         VARCHAR(64)  NOT NULL PRIMARY KEY,
  created_ms BIGINT       NOT NULL,
  doc        LONGTEXT     NOT NULL,
  KEY idx_ds_created (created_ms)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS profile (
  id         VARCHAR(64)  NOT NULL PRIMARY KEY,
  created_ms BIGINT       NOT NULL,
  start_ms   BIGINT       NOT NULL,
  doc        LONGTEXT     NOT NULL,
  KEY idx_profile_start (start_ms)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
