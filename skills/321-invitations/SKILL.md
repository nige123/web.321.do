---
name: 321-invitations
description: Use when adding invite-a-teammate / invite-a-collaborator by email to a Mojolicious SSR app on the AXS baseline - low-friction email invitations where ACCEPTING THE LINK SIGNS THE INVITEE IN (magic-link accept, no passcode wait, no second email), plus role grants on accept, virtual composite roles (Admin = several grants), Send again with token rotation, and expiry. Triggers: invite user, invitation email, join team, accept invitation, reinvite, resend invite, onboarding friction, magic link.
---

# Email invitations with magic-link accept

## Overview

Invite someone by email + role; the emailed link is an unguessable
capability, so ACCEPTING IT SIGNS THE INVITEE STRAIGHT IN - the same proof of
inbox control a sign-in passcode gives, without making them request a second
email and wait for it. One click from inbox to console. Extracted from the
shipped paydance.com implementation; `templates/` are that real, tested code
(`PD::` - rename to your namespace).

The friction this kills, measured on a real invitee: click link -> "sign in
to accept" -> request passcode -> wait for a slow first delivery (greylisting)
-> sign in -> no return-to, so dig out the invitation email and click again.
Magic-link accept makes all of that one POST.

## When to use

- "Invite a teammate / bookkeeper / collaborator" on an AXS-baseline app
  (321-bootstrap-saas: email-passcode sign-in, `axs_identity` grants,
  SQL-template DB layer, branded Mailer).
- Any emailed join-link where the recipient may have NO account yet.
- Pair with 321-passkeys: the post-accept interstitial offers a passkey, so
  the invitee's NEXT sign-in needs no email either.

**Not for:** share-by-link public pages (321-share-tokens); self-serve signup
(that is /start); access REQUESTS (inbound "may I join", the reverse flow).

## The shape (see templates/)

| Piece | File | Job |
|---|---|---|
| Migration | `migration.sql` | `organisation_invitations`: org FK, email, role (free TEXT - no CHECK, roles evolve app-side), `token UNIQUE`, inviter FK, accepted_at / revoked_at / expires_at |
| Service | `Service-Invitations.pm` | `invite` (whitelist role, CSPRNG token, branded email), `accept` (validate -> grant role(s) + stamp accepted_at in ONE tx), `resend` (rotate token + fresh window), `revoke`, `pending_for_org` (+is_expired) |
| Auth | `Auth-sign_in_verified.pm` | `sign_in_verified($email,$ua,$ip)` - the post-proof half of passcode sign-in, shared by passcode verify AND magic-link accept |
| Controller | `Controller-excerpts.pm` | team page, team_invite, team_reinvite, accept GET (side-effect free), accept_submit POST (signs a session-less invitee in, then accepts) |
| Pages | `accept.html.ep`, `team.html.ep` | the one-button accept page; Team page with role select, pending list + Send again |
| Tests | `invite-flow-test.t` | full HTTP lifecycle + every rejection path |

## The recipe

1. Migration + bump the migration-count test. Token is stored RAW here
   (unlike share tokens): it is single-use, short-lived, and revocable, and
   `resend` must re-email it. Hash-at-rest is a fine hardening if you accept
   losing nothing (resend rotates anyway).
2. Port the service. `%INVITABLE_ROLE` is the adaptation point - whitelist
   YOUR roles. Virtual composite roles cost two lines: whitelist the key,
   expand it in `accept()` (e.g. admin -> checker + payer). The virtual key
   lives ONLY on invitation rows and is never granted itself.
3. Add `sign_in_verified` to your Auth service by EXTRACTING the tail of
   `verify_sign_in` (find-or-create user, stamp `verified_at`, create
   session) so both proofs share one code path.
4. Controller: GET accept stays side-effect free and renders one primary
   button. POST accept: signed-in user proceeds as themselves; session-less
   user -> validate the token FIRST, then `sign_in_verified` with the
   INVITATION's email (never a typed one), set the session, continue. Dead
   tokens render the same calm 404 as the GET - never a bounce to sign-in.
5. Resend: "Send again" button per pending row; rotates the token (old link
   dies deliberately) + restarts the expiry window; expired invitations stay
   listed, marked calmly, because re-sending them is the main use case.
6. Flashes at every step (invited / sent again / joined), and a growth event
   per invite if the app has a flywheel.
7. Tests: mint -> accept signed-out -> signed in + role granted +
   verified_at stamped; used/expired/bogus token POST -> 404 AND no session;
   GET creates no session and no user; non-staff cannot invite or resend;
   resend rotates the token and the old accept URL 404s.

## Decisions baked in

- **The emailed token IS the sign-in proof.** Same trust as a passcode
  (control of the inbox). No second email, no passcode wait, no return-to
  loop. This is the low-friction core - do not water it down.
- **Sign-in on POST only.** Mail scanners and link-preview bots prefetch
  GETs; a prefetch must never create a session or consume the invitation.
- **Validate before sign-in.** A used/revoked/expired token must 404 without
  a session ever existing.
- **Single-use via accepted_at.** Accepting stamps it inside the same tx as
  the grant; a replayed link hits the calm 404.
- **Resend rotates.** A fresh CSPRNG token + fresh window; the old link
  stopping dead is a feature (forwarded stale links die).
- **Role is free TEXT, whitelisted in the app.** Role sets evolve without
  migrations; virtual composites stay possible.
- **Grants to the signed-in user when a session exists.** An invitation
  forwarded within a team still lands on whoever accepts it, knowingly.

## Common mistakes

See `references/gotchas.md` - duplicated role whitelists, the CTE
visibility re-query, greylisting misdiagnosed as app slowness, middot
regexes in non-utf8 tests, and scanner-prefetch traps.
