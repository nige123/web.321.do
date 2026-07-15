---
name: 321-db-speed
description: Use when making any database-impacting change in a 123.do / 321-family Mojolicious app - writing or editing a migration, adding a query or .sql.ep file, adding a column that queries will filter/join/order on, or when a route or cron feels slow. The rule: every change ships WITH the indexes its read paths need, named in writing and verified by EXPLAIN ANALYZE - Postgres does not auto-index foreign-key columns. Triggers: migration, new query, add index, slow route, slow page, seq scan, EXPLAIN ANALYZE, LATERAL, ILIKE search, pg_trgm, "why is this query slow".
---

# Every database change considers retrieval speed

## Overview

**A migration or new query ships WITH the indexes its read paths need.** For
every new WHERE / JOIN / ORDER BY, name the index that serves it, in writing:
in the migration comment next to the index, or in the query file's header
comment. "None - table is small and bounded" is an acceptable answer, but
write it down. The only wrong state is silence - an unexamined read path.

Index naming: **table name first, `_idx` suffix** (`_uidx` for unique) - so
`sessions_user_idx`, `passcodes_email_created_idx`,
`accounts_stripe_customer_uidx`. A reader must be able to tell the table from
the index name alone.

## When to use

- Writing or editing a migration (a `-- N up` block), or adding any table.
- Adding or changing a query (a `.sql.ep` under 321-sql-template, or inline).
- Adding a column that queries will filter, join, or order on.
- A route feels slow, or a cron/report gets slower week by week.

**Not for:** the query-layer mechanics themselves (321-sql-template);
non-Postgres stores.

## Postgres does not auto-index foreign-key columns

PRIMARY KEY and UNIQUE constraints get indexes automatically; a plain
`REFERENCES` column gets **nothing**. Real failure, api.123.do:
`entries(step_id)` - the app's hottest join key - was unindexed for 33
migrations. The find-steps route's correlated LATERAL then seq-scanned the
whole entries table once per candidate step: EXPLAIN showed 486 loops x
"Rows Removed by Filter: 3408", about 1.6M row visits and ~260 ms at toy
scale, with quadratic growth from there.

**Index the correlation key of every LATERAL** - it is the column the inner
scan re-filters on for every outer row, so an index there is multiplied by
`loops=N` while a missing one is too.

## Verify with EXPLAIN ANALYZE

Run against the dev DB with representative binds and the WORST realistic
case (cross-track, no early hits), not the friendly case that returns on the
first page. Red flags:

- **`Seq Scan` inside `loops=N`** - a full scan repeated N times; the killer
  shape from the LATERAL failure above.
- **High "Rows Removed by Filter"** - the rows were visited only to be thrown
  away; the filter column wants an index.
- **LIMIT caps the output, not the scan.** ORDER BY still evaluates every
  candidate row before LIMIT unless the ordering is index-aligned, so a
  "fast because LIMIT 10" hunch is wrong on exactly the tables that grow.

## Pattern library

- **Partial indexes must match the query's predicate.** An index
  `... WHERE trashed_at IS NULL` (or `archived_at IS NULL`) is only usable
  when the query states the same predicate - visibility conditions belong in
  both places, verbatim.
- **`(key, created_at DESC)` composites** for latest-N-per-key lookups: the
  index walks straight to the newest rows for the key, no sort node.
- **Leading-wildcard `ILIKE '%q%'` can never use a btree.** The upgrade path
  is a pg_trgm GIN index on the column (or expression) - zero query changes.
- **Expiry/purge DELETEs** (`WHERE expires_at < now()`) need an index on the
  expiry column once the table can grow, or every purge is a full scan.
- **Unique indexes double as fast lookups.** Token/id resolution rides the
  UNIQUE constraint (see 321-share-tokens and 321-invitations: resolution by
  token is an index hit, never a scan).

## When boring is right

Small bounded tables, once-a-day crons, tables that self-purge. Say so
explicitly - "no index: bounded by the number of staff" - rather than adding
speculative indexes. Unused indexes are not free: every INSERT/UPDATE
maintains them, and they crowd the cache. The discipline is the written
sentence, not the CREATE INDEX.

## Where this hooks into the family

- **321-sql-template** - every new `.sql.ep` names its supporting index in a
  header comment.
- **321-bootstrap-saas** - the baseline migration models the discipline: each
  index comment names the read path it serves.
- **321-stripe / 321-passkeys / 321-invitations / 321-share-tokens** - each
  migration's indexes exist for a named reason; never remove one without
  re-reading it.
- **321-daily-report** - report aggregates stay date-bounded and
  index-backed so the morning cron never becomes a full-table scan.
