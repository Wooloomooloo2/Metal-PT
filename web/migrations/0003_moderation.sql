-- Moderation (spec §4.H).
-- runs.video_locked: a moderator removed this run's video link; the owner's PATCH may not set a new one.
ALTER TABLE runs ADD COLUMN video_locked INTEGER NOT NULL DEFAULT 0;
-- reports.text: the reporter's words (≤ 1000 characters, scrubbed). Reports store only run id, reason, text and
-- time: nothing about who sent them (spec §4.I).
ALTER TABLE reports ADD COLUMN text TEXT;
CREATE INDEX reports_open ON reports (resolved, created);
