-- Append as your next "-- N up" block (bump t/01-migration.t + truncate list).
-- Send-once audit for the daily owner report: one row per report date makes
-- the report command idempotent (cron double-fires, manual re-runs) unless
-- --force refreshes it.
CREATE TABLE daily_reports (
    report_date  DATE PRIMARY KEY,
    recipient    TEXT NOT NULL,
    sent_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
