-- Metal-PT website schema (spec docs/superpowers/specs/2026-11-25-metal-pt-website-design.md §4.D).
-- Times are ISO-8601 UTC text ("2026-11-25T12:00:00Z"); booleans are INTEGER 0/1.
-- No IP addresses, user agents or other request metadata are stored anywhere (spec §4.I).

-- A signing key, not a person. key_id is internal only and never shown publicly.
CREATE TABLE macs (
  key_id      TEXT PRIMARY KEY,
  public_key  TEXT NOT NULL,
  first_seen  TEXT NOT NULL,
  banned      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE games (
  id        INTEGER PRIMARY KEY,
  slug      TEXT NOT NULL UNIQUE,
  title     TEXT NOT NULL,
  steam_id  TEXT UNIQUE,          -- NULL allowed (many NULLs are fine under UNIQUE)
  created   TEXT NOT NULL
);

-- Normalised title -> game (lowercase, punctuation and ® ™ removed, spaces collapsed).
CREATE TABLE game_aliases (
  alias_norm  TEXT PRIMARY KEY,
  game_id     INTEGER NOT NULL REFERENCES games(id)
);
CREATE INDEX game_aliases_game_id ON game_aliases (game_id);

CREATE TABLE runs (
  id               TEXT PRIMARY KEY,           -- short random, URL-safe
  game_id          INTEGER NOT NULL REFERENCES games(id),
  key_id           TEXT NOT NULL REFERENCES macs(key_id),
  bundle_sha256    TEXT NOT NULL UNIQUE,       -- same bundle twice -> 409 with the first run's URL
  published        TEXT NOT NULL,
  recorded         TEXT,
  app_version      TEXT,
  chip             TEXT,
  gpu_cores        INTEGER,
  memory_gb        INTEGER,
  model_id         TEXT,
  os_version       TEXT,
  mac_key          TEXT NOT NULL,              -- e.g. m4-max-40, or unknown
  setup_key        TEXT NOT NULL,              -- e.g. native, crossover-25-d3dmetal, or unknown
  setup_label      TEXT NOT NULL,              -- e.g. "CrossOver 25 · D3DMetal"
  group_key        TEXT NOT NULL,              -- groups.group_key this run belongs to
  runtime          TEXT,
  runtime_version  TEXT,
  graphics_layers  TEXT,                       -- all detected layers, sorted, joined
  recorded_app     TEXT,
  preset           TEXT,
  width            INTEGER,
  height           INTEGER,
  upscaler         TEXT,
  upscaler_mode    TEXT,
  frame_gen        TEXT,
  median_fps       REAL,
  p1_low_fps       REAL,
  fps_per_watt     REAL,
  mean_system_w    REAL,
  power_source     TEXT,                       -- system | gpuOnly | none
  on_ac            INTEGER,
  power_mode       TEXT,
  limiter_primary  TEXT,
  limiter_verdict  TEXT,
  steady_s         REAL,
  notes            TEXT,                       -- only when the app's includesNotes is set
  settings_text    TEXT,
  label            TEXT,
  video_id         TEXT,                       -- 11-character YouTube ID only; the submitted URL is never stored
  video_title      TEXT,
  video_channel    TEXT,
  fps_series       TEXT,                       -- JSON, <= 300 points, for the run page chart
  hidden           INTEGER NOT NULL DEFAULT 0,
  outlier          INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX runs_game_id   ON runs (game_id);
CREATE INDEX runs_mac_key   ON runs (mac_key);
CREATE INDEX runs_setup_key ON runs (setup_key);
CREATE INDEX runs_published ON runs (published);
CREATE INDEX runs_key_id    ON runs (key_id);
CREATE INDEX runs_group_key ON runs (group_key);

-- Cached statistics per group (spec §4.E). Quoted because GROUPS is an SQLite keyword.
CREATE TABLE "groups" (
  group_key      TEXT PRIMARY KEY,
  game_id        INTEGER NOT NULL REFERENCES games(id),
  mac_key        TEXT NOT NULL,
  setup_key      TEXT NOT NULL,
  preset         TEXT,
  width          INTEGER,
  height         INTEGER,
  upscaler       TEXT,
  upscaler_mode  TEXT,
  frame_gen      TEXT,
  runs           INTEGER NOT NULL DEFAULT 0,
  macs           INTEGER NOT NULL DEFAULT 0,
  typical_fps    REAL,
  p25_fps        REAL,
  p75_fps        REAL,
  typical_fpw    REAL,
  outliers       INTEGER NOT NULL DEFAULT 0,
  updated        TEXT NOT NULL
);
CREATE INDEX groups_game_id ON "groups" (game_id);

CREATE TABLE reports (
  id        INTEGER PRIMARY KEY,
  run_id    TEXT NOT NULL REFERENCES runs(id),
  reason    TEXT NOT NULL,
  created   TEXT NOT NULL,
  resolved  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX reports_run_id ON reports (run_id);
