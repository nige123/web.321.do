---
name: 321-passkeys
description: Use when adding passkey or WebAuthn sign-in / sign-up to a Perl Mojolicious SSR app that uses the AXS access model (signed-cookie sessions, a SQL-template DB layer) and deploys with 321 - or when working with Authen::WebAuthn, discoverable credentials, COSE keys, attestation/assertion verification, or a headless WebAuthn test authenticator in Perl.
---

# Passkeys for 321 / AXS / Mojolicious SSR apps

## Overview

Add passkeys (WebAuthn) as an **additional** sign-in / sign-up method to a
Mojolicious app, alongside its existing email/password/passcode auth (which
stays as the universal fallback). The security-critical verification is done by
the `Authen::WebAuthn` CPAN module; you write thin glue: a credentials table, a
small service, four JSON endpoints, the client JS, and UI.

This skill targets the **AXS access model**: signed-cookie sessions, a
`Sessions->create($user_id)` helper, `current_user`, role/members RBAC, a
SQL-template DB wrapper (`$db->query('group/name', {...})` ->
`sql/group/name.sql.ep`), `Model`/`Auth`/`Web::Controller` layering, Mojo::Pg
migrations, and a `Test::Mojo` harness. It was generalized from a shipped
implementation; the `templates/` are real, working, tested code to port.

**Read `references/gotchas.md` before and during implementation** - it lists the
non-obvious failures (the `Authen::WebAuthn` API quirks, the test-authenticator
byte layout, base64url details, `DBD::Pg ->rows`, dependency install) that
otherwise cost hours.

## When to use

- Adding "sign in with a passkey" (discoverable / usernameless) to a Mojo app.
- Adding passkey enrolment at sign-up or in account settings.
- Any Perl WebAuthn work: `Authen::WebAuthn`, COSE keys, attestation/assertion,
  or building a headless test authenticator with CryptX.

**Not for:** non-Mojolicious stacks; replacing your existing auth (passkeys are
additive); attestation/authenticator allow-listing or MFA policy (out of scope).

## What it assumes (adapt these to the target app)

| AXS piece | What the skill hooks into | Adapt |
|-----------|---------------------------|-------|
| Namespace | `F6::` in templates | rename to the app's (e.g. `App::`) |
| Sessions | `<NS>::Auth::Sessions->create($user_id)` + signed `*_session` cookie | match the app's session cookie + helper |
| current_user | `$c->current_user` (id + email) | match the app's accessor |
| DB | `$self->db->query('group/name', {binds})` -> `sql/group/name.sql.ep` | match the SQL-template mechanism |
| Migrations | numbered `-- N up` blocks in `db/migration.sql` (Mojo::Pg) | bump N; update the version test |
| Tests | `Test::Mojo` + a reset-db harness with a truncate list | add `webauthn_credentials` to the list |

## The recipe (TDD, one commit per step)

Work test-first. Each step has a template; `<NS>` = the app's namespace.

1. **Spike first.** Add `Authen::WebAuthn` + `CBOR::XS` to `cpanfile`; install
   (see gotchas: install into BOTH `local/lib` and the test `site_perl`).
   Then **prove the byte layout end-to-end before writing app code**: a ~40-line
   script that builds a `none` attestation + an EC-signed assertion and runs
   them through `validate_registration`/`validate_assertion`. If that doesn't go
   green, nothing downstream will. (`templates/Test-WebAuthn.pm` is that logic.)
2. **Migration** (`templates/migration.sql`): `webauthn_credentials` table +
   `users.webauthn_user_handle`. Bump the migration version + its test; add
   `webauthn_credentials` to the test-harness truncate list.
3. **Model** (`templates/Model-Passkeys.pm`, `templates/sql/*.sql.ep`): CRUD.
   Plus, on your users model, `ensure_webauthn_handle($user_id)` (lazy random
   handle) and `by_webauthn_handle`. Note the `RETURNING` + count trick for
   delete (gotchas).
4. **Test authenticator** (`templates/Test-WebAuthn.pm`): headless software
   authenticator (CryptX) producing valid register/assert inputs. This is what
   lets every later test verify for real without a browser.
5. **Service** (`templates/Auth-WebAuthn.pm`): builds creation/request options
   and wraps `validate_registration`/`validate_assertion`. Add a `webauthn`
   helper (rp_id/origin/rp_name from config) and a `start_session_for($user_id)`
   helper (create session + set the signed cookie, like the existing flow).
6. **Endpoints** (`templates/Controller-Passkeys.pm`): `POST
   /auth/passkey/login/options|verify` and `register/options|verify`, plus
   `GET /passkeys/add` and `POST /passkeys/:credential_id/remove`. Login verify
   reuses `start_session_for`. Add the routes.
7. **Client JS** (`templates/passkeys.js`): base64url + `navigator.credentials
   .create/get` + fetch. Append to your JS bundle, or include it standalone
   via the base's cache-busting helper: `<script src="<%= asset_url
   q{/js/passkeys.js} %>" defer></script>` - never a bare `/js/passkeys.js`
   (321 hot deploys are zero-downtime, so a stale cached copy never gets a
   refresh nudge otherwise).
8. **Sign-in UI** (`templates/ui/signin_button.html.ep`): a "Sign in with a
   passkey" button, hidden until JS confirms support.
9. **Registration UI** (`templates/ui/passkey_offer.html.ep`,
   `settings_passkeys.html.ep`): a skippable post-signup "add a passkey"
   interstitial (set a `post_signup` session flag at signup; redirect there
   after the email code) and a Settings section to list/add/remove.
10. **Verify + ship.** Full suite green; deploy; manual browser E2E on **HTTPS
    or localhost** (a plain-HTTP dev host can't run WebAuthn - gotchas).

## Decisions baked into the templates

- **Additive**, email/passcode stays as the fallback + recovery channel.
- **Discoverable** sign-in (`allowCredentials: []`, `residentKey: required`,
  opaque user handle).
- **Email verified once** at signup, then offer a passkey (no address squatting).
- `attestation: 'none'`, `userVerification: 'preferred'`.
- Challenge in the **host-only** signed session cookie, single-use, short TTL
  (a `Domain` on it collides with a stale same-name cookie -> `no_challenge`; see
  gotchas).

## Rolling out to existing accounts (the nudge)

New users get the post-signup passkey offer automatically, but accounts created
before passkeys existed never see it. Add a gentle, **dismissible banner** for
signed-in users who have no passkey and haven't dismissed it - "Add a passkey"
runs the register flow, "Not now" dismisses it, and adding one anywhere clears
it. Prefer a banner over a forced post-login redirect: it doesn't hijack
navigation and won't destabilise existing login-redirect tests. Full pattern -
migration flag, the should-nudge query, the memoised helper, the banner, the
dismiss endpoint - in `references/existing-user-nudge.md`.

## Verify

- Headless: the test authenticator drives `register -> sign-in -> tamper-
  rejection` through the real library + your endpoints. Cover bad challenge,
  bad signature, unknown credential, sign-count regression, auth-required.
- Manual browser E2E (HTTPS/localhost): sign up -> add passkey -> sign out ->
  sign in with passkey -> remove it -> email fallback still works.

## Common mistakes

See `references/gotchas.md`. The top three: `_b64` arg names (values are
base64url); `allow_untrusted_attestation => 1` for `none`; `validate_assertion`
dies on failure - detect success with `eval` + a defined `signature_count`
(don't depend on the `success` key, which varies by library version).
