# Passkeys / WebAuthn in Perl Mojolicious - gotchas

The non-obvious things that cost time. Read before and during implementation.

## Authen::WebAuthn API (v0.005)

- Constructor: `Authen::WebAuthn->new(rp_id => ..., origin => ...)`.
- Method names: `validate_registration` and `validate_assertion`.
- **Argument keys end in `_b64`, NOT `_b64u`** - but the VALUES are base64url
  (the module decodes everything with `decode_base64url`). So your JS / test
  authenticator must base64url-encode (no padding), and you pass them under the
  `_b64` keys. Names: `challenge_b64`, `client_data_json_b64`,
  `attestation_object_b64`, `credential_pubkey_b64`, `authenticator_data_b64`,
  `signature_b64`, `token_binding_id_b64`.
- **Registration of `attestation: 'none'` is rejected unless you pass
  `allow_untrusted_attestation => 1`** to `validate_registration`. We request
  `none` (we don't vet authenticator models), so this flag is required.
- `validate_registration` returns `{ credential_id, credential_pubkey,
  signature_count, aaguid, ... }`. Store `credential_pubkey` verbatim (it is the
  base64url COSE key) and feed it back as `credential_pubkey_b64` on assertion -
  do NOT reformat it.
- **`validate_assertion` DIES on any failure** (bad signature, wrong
  challenge/origin, sign-count regression). On success it returns a hashref -
  in v0.005 that is `{ success => 1, signature_count => N }`, but treat the
  `success` key as unreliable across versions and do NOT depend on it. Wrap the
  call in `eval` and treat `$r && defined $r->{signature_count}` as success -
  that is the version-portable signal:
  `my $r = eval { ...verify_assertion... }; ... unless $r && defined $r->{signature_count}`.

## Challenge handling

- The library compares the **challenge_b64 STRING** directly against
  `clientDataJSON.challenge`. So put the SAME base64url string you generated
  into the options AND pass it back as `challenge_b64`. `MIME::Base64`'s
  `encode_base64url` is unpadded, which matches what browsers put in
  clientDataJSON - they line up. Generate with `random_bytes(32)` (Crypt::PRNG).
- Store the single-use challenge + ceremony type in the **signed session
  cookie** (`$c->session`), short TTL (~5 min). The session exists pre-login, so
  it works for the sign-in ceremony too. Delete it on use.
- **Registration and login use INDEPENDENT challenges** - generate a fresh
  single-use challenge per ceremony; never reuse one across register/login.
- `requested_uv` only ENFORCES the user-verification flag when it equals
  `'required'`. With `'preferred'` (our default) the UV bit in authData is not
  checked - fine here (the authenticator sets UV anyway), but don't expect
  `'preferred'` to reject a UV-absent authenticator.

## Session cookie scope: keep the Mojo session HOST-ONLY

The challenge lives in the signed Mojolicious session cookie. Keep that cookie
**host-only** - do NOT give it a `Domain`. If you add `Domain=example.com` (e.g.
to share login across apex + subdomains), it becomes a SECOND cookie of the same
name alongside any pre-existing host-only one already in the browser. The browser
then sends BOTH (`Cookie: <name>=<stale>; <name>=<new>`), and the stale one -
which carries no current challenge - can be read first, so login fails with
**`no_challenge`** even though everything in the code looks correct.

Tell-tale: passkey `login_verify` returns `no_challenge`, but a fresh `curl`
cookie-jar round-trip of `login/options` -> `login/verify` succeeds (gets past
the challenge check) - proving the SERVER is fine and the fault is browser-side
cookie shadowing. Fix: leave the transient flow session host-only; if you need
cross-host LOGIN persistence, put it on a SEPARATE cookie (e.g. the DB-backed
`*_session`) with its own `Domain`. After changing the scope, existing browsers
must clear the stale cookie once - same-name cookies at different scopes do not
overwrite each other, they coexist.

## Debugging a failing ceremony (capture the swallowed reason)

`validate_assertion` / `validate_registration` are wrapped in `eval`, so the real
reason is swallowed and the JS only shows a generic "did not complete" toast. To
find it, temporarily log the failing branch and - for a verify failure - the die
message (`$@`) plus the decoded `clientDataJSON` `origin`/`challenge`/`type` next
to your configured `origin`/`rp_id` and the session challenge. That one line
usually names the fault (origin mismatch, challenge mismatch, no_challenge,
unknown_credential, or a crypto error).

Then separate SERVER from BROWSER: replay `login/options` -> `login/verify` with
a `curl` cookie jar (`-c jar -b jar`). If curl gets PAST the challenge check
(e.g. `unknown_credential` for a junk id) but the real browser gets
`no_challenge`, the server is fine and the fault is browser-side cookie handling
(see the host-only cookie gotcha above). Note the app log may go to STDERR -
under 321/ubic that is the service's `stderr` file, not `log/<mode>.log`.

## Sign-count

Many platform authenticators (Apple, Windows Hello) always report `0`. Only
treat a **decrease from a non-zero stored value** as a cloned-authenticator
signal: `if ($stored && $new && $new <= $stored) { reject }`. Otherwise accept
and store the new count.

## Discoverable ("usernameless") sign-in

- Request options: `allowCredentials => []` (empty = discoverable) + login needs
  no identity. Registration: `authenticatorSelection.residentKey => 'required'`.
- WebAuthn `user.id` must be an **opaque, stable byte string** - never the email
  or PK. Use a random per-user handle (`webauthn_user_handle`, base64url of 32
  random bytes), generated lazily on first registration.

## rpId / origin (config-derived)

- `rp_id` = the registrable domain, **no scheme, no port** (e.g. `favsix.com`,
  or `localhost` for local dev).
- `origin` = the full origin the browser sends (e.g. `https://favsix.com`,
  `http://localhost:3000`). Must match exactly.
- Derive both from per-environment config so prod vs localhost just works.

## Secure-context requirement (testing)

Browsers refuse WebAuthn outside a **secure context: HTTPS or `localhost`**. A
plain-HTTP dev host (e.g. `http://app.example.dev:8400`) CANNOT run the browser
half. So: unit/integration-test the server headlessly (see the software test
authenticator), and do manual browser E2E on live (HTTPS) or `localhost`.

## The software test authenticator (Test-WebAuthn.pm)

This is the fiddliest part; the template is proven. Byte layout that works with
Authen::WebAuthn:
- EC P-256 key via CryptX: `Crypt::PK::ECC->new->generate_key('nistp256')`;
  `export_key_raw('public')` returns `0x04 || X(32) || Y(32)`.
- COSE key (CBOR map): `{1=>2 (EC2), 3=>-7 (ES256), -1=>1 (P-256), -2=>X, -3=>Y}`.
- `authData` = `sha256(rp_id) . chr(flags) . pack('N', sign_count)` then, for
  registration, the attested credential data:
  `("\x00"x16 aaguid) . pack('n', len(cred_id)) . cred_id . cose_key`.
  Flags: registration `0x45` (UP|UV|AT), assertion `0x05` (UP|UV).
- Registration attestation object (CBOR): `{fmt=>'none', attStmt=>{},
  authData=>...}`.
- Assertion signature: `pk->sign_message($authData . sha256($clientDataJSON),
  'SHA256')` - CryptX `sign_message` hashes with SHA-256 and returns a DER
  ECDSA signature, which is exactly what WebAuthn ES256 expects.
- The stored `credential_id` (from `validate_registration`) equals
  `encode_base64url(raw_cred_id)`, and your device must report `id` as the same
  - so controller `find($body->{id})` matches.

## DBD::Pg `->rows` is unreliable for DELETE

`$db->query('... DELETE ...')->rows` returns **-1** for a zero-match delete. To
count deleted rows reliably, add `RETURNING <pk>` and count:
`scalar @{ $res->arrays->to_array }`.

## Dependency install: two places

- The deploy installs deps from `cpanfile` into the app's `local/lib`
  (`cpanm -L local --installdeps .`), and the running app's `PERL5LIB` includes
  it. Add `Authen::WebAuthn` and `CBOR::XS` to `cpanfile`.
- But the **local `prove` test harness** often uses the perlbrew `site_perl`
  `@INC` (no `local/lib`). If `prove` reports "Can't locate Authen/WebAuthn.pm",
  install into site_perl too: `cpanm --notest Authen::WebAuthn CBOR::XS` (without
  `-L local`). CryptX is usually already present (it's a common dep).

## Migrations: auto_migrate is lazy (Mojo::Pg)

`$pg->auto_migrate(1)` migrates on the **first DB connection** of a worker - i.e.
the first DB-backed *request* after a restart, NOT at process start. Right after
a deploy, `mojo_migrations` can still show the OLD version until something queries
the DB (a logged-out homepage or a 401 path may not touch it, so a new column can
look "missing"). It is NOT a 500 risk - auto_migrate applies the change as part of
acquiring the connection, before any query runs on it. To verify a schema change
post-deploy: hit a DB-backed page (a valid `/@handle`), then
`SELECT version FROM mojo_migrations WHERE name='<app>'`.

## Email-anchored, verified-once signup (no squatting)

Don't store an account/passkey until the email is proven. Reuse the existing
email-code signup, set a `post_signup` session flag, and after the code
verifies, redirect to a skippable "add a passkey" page. This guarantees the
email is verified before anything is persisted, and avoids prompting biometrics
for an unproven account.

## Test sub signatures

Plain `.t` files (`use strict; use warnings;`) do NOT enable subroutine
signatures. Either `use feature 'signatures';` or unpack `@_` classically in
test helper subs - otherwise you get "Illegal character in prototype".
