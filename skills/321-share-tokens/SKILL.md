---
name: 321-share-tokens
description: Use when adding share-by-link (unlisted links, "copy share link", revocable public pages) to a Mojolicious SSR app on the AXS baseline - shareable resources behind opaque revocable tokens with public read-only views, e.g. /p/:token. Covers hash-at-rest tokens, per-type ownership checks, type-matched resolution, safe public projections, revoke lifecycle, and the share_viewed flywheel event.
---

# Revocable share tokens (unlisted links)

## Overview

Let a signed-in owner share any resource by unlisted link: mint an opaque
token, show the URL once, render a read-only public page to anyone holding the
link, and let the owner revoke it at any time. Only the SHA-256 hash of a
token is stored - the raw token exists solely in the URL. Extracted from the
shipped love2.do implementation; `templates/` are that real, tested code
(`L2D::` - rename to your namespace).

## When to use

- "Share this profile/board/report by link" on an AXS-baseline app
  (321-bootstrap-saas: SQL-template DB layer, `current_user`, `log_event`).
- Public, no-auth read pages for otherwise-private resources.
- Any tokens-in-URLs feature where revocation and audit matter.

**Not for:** permission grants to signed-in collaborators (that is membership
/ RBAC, not a link); signed short-lived URLs for file downloads; OAuth-ish
delegation.

## The shape (see templates/)

| Piece | File | Job |
|---|---|---|
| Migration | `migration.sql` | `share_tokens` table: `token_hash UNIQUE`, `resource_type` CHECK, `resource_id`, creator FK, `permission`, `expires_at`, `revoked_at` |
| Model | `Model-Shares.pm` | `create` (ownership-checked mint), `resolve($token, $expected_type)`, `revoke` (owner-only, idempotent), safe public projections |
| Controller | `Controller-Shares.pm` | `POST /share` + `POST /share/:id/revoke` (auth) and one public GET per type (`/p/:token`, ...) |
| SQL | `sql/*.sql.ep` | insert / resolve / revoke + one `*_owned` and one `*_public` query per resource type |
| Tests | `share-test.t` | the full lifecycle + every rejection path |

The **resource-type map** at the top of the model is the adaptation point: one
row per shareable type wiring `resource_type -> ownership query + URL prefix`.
Add a type = add two SQL files + one map row + one public route/template.

## The recipe

1. Migration block: `share_tokens` with YOUR resource types in the CHECK; bump
   the migration-version test; add the table to the harness truncate list.
   Retrieval speed: `token_hash UNIQUE` is both integrity and THE lookup
   path - `resolve` is an index hit on the stored hash, never a scan
   (hash-at-rest tokens are looked up BY the hash, so the unique index lives
   on the hash column) - and `share_tokens_resource_idx` serves the
   per-resource listing. See **321-db-speed**.
2. Port the model; fill in the type map; write each type's `*_owned` (id +
   user_id -> row) and `*_public` (ONLY anonymously-safe columns) queries.
3. Controller: `create` flashes the full share URL (base_url + prefix + raw
   token - the one moment the token exists to show) and redirects back to the
   resource; public views resolve with the expected type and 404 on any miss;
   `revoke` is owner-only. Log `*_shared` / `share_viewed` events.
4. Routes: single-letter public prefixes (`/p/:token`) declared before any
   catch-all route; add the prefixes to RESERVED_HANDLES if handles share the
   URL root.
5. Public page per type: read-only projection + a "create your own" CTA - the
   share page is the viral loop's landing step.
6. Tests: mint -> public 200; revoked/expired/bogus -> 404; wrong-prefix token
   -> 404; non-owner mint/revoke -> 404; raw token absent from the DB;
   `share_viewed` row written.

## Decisions baked in

- **Hash at rest.** `sha256_hex($token)` in the DB; Nanoid(24) raw token only
  ever in the URL. A DB leak leaks nothing shareable.
- **Type-matched resolve.** `resolve($token, $expected_type)` - a role-spec
  token pasted into `/p/...` resolves to nothing, so URLs can't be cross-wired.
- **Idempotent revoke.** `COALESCE(revoked_at, now())` keeps the first
  timestamp; revoking twice is safe.
- **Projections, not rows.** Public queries select only the columns safe for
  strangers - never raw answers, source text, or emails.
- **Show the URL once, via flash.** No "retrieve my link" page; losing the
  link means minting a new token (and revoking the old one if desired).
- **Every view is an event.** `share_viewed` (+ per-type `*_shared`) rows feed
  the flywheel questions: which outputs get shared, which shares convert.

## Common mistakes

See `references/gotchas.md` - wrong-prefix 404s, the flash-once URL pattern,
projection leaks, reserved single-letter routes, and expires-vs-revoked
semantics.
