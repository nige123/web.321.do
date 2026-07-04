# Share-token gotchas

## The raw token exists exactly once

`create` returns the raw token; after the redirect it is gone - only the hash
survives. Flash the FULL share URL on the very next page render (the model
returns `{ token }`, the controller builds `base_url . '/' . prefix . '/' . $token`).
If you store or log the raw token anywhere else, you have reinvented the leak
hash-at-rest prevents. Tests should assert the raw token does NOT appear in
any DB column.

## Resolve must check the type, not just the hash

A share URL encodes its type in the prefix (`/p/` profile, `/r/` role spec...).
`resolve($token, $expected_type)` returns nothing on a type mismatch. Skip
that check and any valid token opens EVERY public view - a role-spec token
pasted into `/p/` would render a profile page shell against the wrong row id,
usually leaking whatever id collides.

## Public projections leak by default

`SELECT *` on the shared row WILL eventually expose something private (raw
answers, pasted source text, the owner's email via a lazy JOIN). Each type
gets a dedicated `*_public` query listing safe columns explicitly - treat any
new column on the resource table as private until added there deliberately.

## Single-letter routes collide with everything

`/p/:token` style prefixes must be declared BEFORE catch-all routes (`/@:handle`
or `/:slug`), and the letters added to RESERVED_HANDLES so no user can claim
the handle `p` and shadow the namespace.

## Revoked vs expired are different answers to different questions

`revoked_at` is an owner action (permanent, idempotent via
`COALESCE(revoked_at, now())`); `expires_at` is a mint-time policy (NULL =
forever). The resolve query checks both. Do not "unrevoke" by clearing the
column - mint a fresh token instead, so the audit trail stays truthful.

## Ownership is per-type, not generic

There is no polymorphic `resource.owner_id` - each type declares its own
`*_owned` query (comparison ownership is `comparisons.user_id`, a team
resource might be membership-based). The model's type map keeps that explicit;
resist the urge to fold it into one clever join.

## Log the view, tolerate the failure

`share_viewed` events power the flywheel metrics, but analytics must never
break an anonymous page - go through the app's non-fatal `log_event` helper,
not a raw insert.
