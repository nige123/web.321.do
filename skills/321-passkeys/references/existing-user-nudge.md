# Rolling passkeys out to existing accounts (the nudge)

New users get the post-signup "add a passkey" offer automatically. But accounts
created **before** passkeys shipped never pass through it - so without a nudge
they'd have to discover passkeys in Settings. This pattern gently prompts them.

**Use a dismissible banner, not a forced post-login redirect.** A banner:
- doesn't hijack navigation (a redirect interstitial does);
- won't change the post-login redirect target, so it can't destabilise existing
  "after login -> /@handle" tests;
- shows only to the target population (signed-in, no passkey, not dismissed) and
  vanishes the moment they add one or click "Not now".

`<NS>` = your app namespace; adapt names to your app.

## 1. Migration: a dismissal flag on users

```sql
-- N up
ALTER TABLE users ADD COLUMN passkey_nudge_dismissed_at TIMESTAMPTZ;
```

## 2. "Should we nudge?" - one cheap query

`sql/users/passkey_nudge.sql.ep` (also in `templates/sql/users_passkey_nudge.sql.ep`):

```sql
SELECT (u.passkey_nudge_dismissed_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM webauthn_credentials w WHERE w.user_id = u.user_id))::int
       AS nudge
FROM users u
WHERE u.user_id = [user_id]
```

`sql/users/dismiss_passkey_nudge.sql.ep`:

```sql
UPDATE users SET passkey_nudge_dismissed_at = now()
WHERE user_id = [user_id] AND passkey_nudge_dismissed_at IS NULL
```

Users model:

```perl
sub needs_passkey_nudge ($self, $user_id) {
    my $row = $self->db->query('users/passkey_nudge', { user_id => $user_id })->hash;
    return $row ? $row->{nudge} : 0;
}
sub dismiss_passkey_nudge ($self, $user_id) {
    return $self->db->query('users/dismiss_passkey_nudge', { user_id => $user_id });
}
```

## 3. A memoised app helper

```perl
# True only when the signed-in user has no passkey and hasn't dismissed.
# Memoised per request; for signed-out users it's a no-op (no query).
$self->helper(passkey_nudge => sub ($c) {
    return $c->stash->{'app.passkey_nudge'} if exists $c->stash->{'app.passkey_nudge'};
    my $user = $c->current_user;
    my $nudge = $user
        ? <NS>::Model::Users->new(db => $c->db)->needs_passkey_nudge($user->{user_id})
        : 0;
    return $c->stash->{'app.passkey_nudge'} = $nudge;
});
```

## 4. The banner (layout)

See `templates/ui/nudge_banner.html.ep` - include it in your default layout just
after the flash. It's `data-passkey-only` (revealed by the client JS only when
WebAuthn is supported) and reuses the existing `data-passkey-register` handler
for "Add a passkey".

## 5. Dismiss endpoint + route

```perl
# POST /passkeys/nudge/dismiss
sub dismiss_nudge ($c) {
    my $user = $c->current_user
        or return $c->render(json => { ok => 0, error => 'auth' }, status => 401);
    <NS>::Model::Users->new(db => $c->db)->dismiss_passkey_nudge($user->{user_id});
    return $c->render(json => { ok => 1 });
}
```

```perl
$r->post('/passkeys/nudge/dismiss')->to('Passkeys#dismiss_nudge');
```

## 6. Clear the flag when they DO add a passkey

In `register/verify`, after storing the credential, also dismiss - so the banner
stops AND the helper's query short-circuits (no more EXISTS scans for them):

```perl
<NS>::Model::Users->new(db => $c->db)->dismiss_passkey_nudge($user->{user_id});
```

## 7. Client JS - "Not now"

Add to the passkey JS module (it reuses the module's `postJSON`):

```javascript
document.querySelectorAll('[data-passkey-dismiss]').forEach(function (btn) {
    btn.addEventListener('click', function (e) {
        e.preventDefault();
        postJSON('/passkeys/nudge/dismiss');           // fire-and-forget
        var banner = btn.closest('[data-passkey-nudge]');
        if (banner) banner.hidden = true;
    });
});
```

## Cost / behaviour

- One cheap `EXISTS` query per authenticated page render **only while the user is
  a nudge target**. Once they dismiss or add a passkey, `dismissed_at` is set and
  the layout helper still runs the query (which now returns 0) - if you want to
  avoid even that, gate the helper on the user row's `dismissed_at` first.
- Signed-out pages do zero extra work.
- New users are unaffected: they still get the stronger post-signup offer; the
  banner only catches pre-existing accounts (and anyone who skipped at signup).

## Test it

Sign in a user with no passkey -> a layout page contains `data-passkey-nudge`.
Give them a passkey (model insert) -> banner gone. Remove it -> banner returns.
`POST /passkeys/nudge/dismiss` -> banner gone for good. Dismiss requires auth.
