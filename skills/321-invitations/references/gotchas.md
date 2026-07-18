# 321-invitations gotchas

All of these happened while building the paydance.com implementation.

## Two copies of the role whitelist

The service AND the controller each carry a `%INVITABLE_ROLE` (the controller
validates before calling the service so the flash can be a calm field nudge
rather than an AppError). Adding a role to one and not the other makes the
new role silently uninvitable (controller copy missed) or a confusing 400
(service copy missed). Grep for INVITABLE_ROLE and update BOTH - or refactor
to one exported source when you touch it a third time.

## The find/create/re-query dance is REQUIRED

`sign_in_verified` does find_by_email, then find_or_create_by_email, then
find_by_email AGAIN. The trailing re-query is not redundant:
find_or_create_by_email is a single data-modifying-CTE statement, and
PostgreSQL does not let a statement's final SELECT see rows its own CTEs just
inserted - for a brand-new email it creates the user but returns undef.
Deleting the "extra" query breaks exactly and only the brand-new-invitee
path, which is the path this skill exists for.

## Slow first email is greylisting, not your app

The Mailer hands mail to Postmark synchronously on the transactional
(`outbound`) stream - the app's part takes milliseconds. A first-ever email
to a recipient (Fastmail especially) can still take minutes: the receiving
host defers unknown sender/recipient pairs and accepts the retry
(greylisting). Do not burn time hunting app latency; check the Postmark
activity dashboard, confirm DKIM/SPF, and remember the penalty vanishes on
later sends. The real fix for invitees is this skill's magic-link accept:
no second email to wait for at all.

## Scanners prefetch GETs

Corporate and webmail link scanners fetch invitation URLs before the human
does. If the GET signs in or consumes the invitation, the scanner silently
burns it and the human sees "already used". Sign-in and acceptance happen
ONLY on the POST behind the button. Keep the GET pure render.

## Dead tokens must not leak validity

Unknown, used, revoked and expired tokens all render the SAME calm 404 page
on GET and POST alike ("used already, withdrawn, or expired"). Distinct
messages let a link holder probe which tokens were real.

## Middot in test regexes

The `.t` files are not `use utf8`; a literal `·` in a regex mis-encodes and
never matches the rendered " · expired" meta. Use `\x{b7}` in the pattern - it
sidesteps the trap without touching the file's encoding. (This is the general
non-ASCII / `use utf8` mojibake trap; see 321-bootstrap-saas gotchas. The other
fix is to `use utf8` in the test and write the literal `·`.)

## Validate BEFORE sign_in_verified

Order matters in the session-less accept path: token validation first, then
session creation. Reversed, a dead token still mints a session for whatever
email the row carried - a free sign-in oracle for anyone holding an expired
link.

## The old link must die on resend

Resend rotates the token rather than re-emailing the old one. Both emails
say "accept"; only the newest works. Assert in tests that the pre-rotation
accept URL 404s - it is the difference between "send again" and "duplicate
credential".

## Session precedence is deliberate

If someone is ALREADY signed in and clicks an invitation meant for a
different address, the grant goes to the signed-in user (they chose to click
accept). Do not "fix" this by force-switching sessions to the invitation
email - that turns a forwarded email into an account switcher.
