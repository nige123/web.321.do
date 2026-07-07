# Copyright Nige Ltd. Author: Nigel Hamilton.
use strict;
use warnings;
BEGIN {
    $ENV{MOJO_CONFIG}    ||= 't/conf/test.conf';
    $ENV{MOJO_MODE}      ||= 'testing';
    $ENV{MOJO_LOG_LEVEL} ||= 'fatal';
}
use Test::Most;
use Test::Mojo;
use lib::relative '../../lib';
use lib::relative '../../local/lib/perl5';
use lib::relative '../lib';
use Test::App qw(with_clean_db test_app seed_org staff_actor party_actor sign_in);

# Phase 9 Task 6 — the team / invitation flow. A staff member invites a
# teammate from /o/<org>/team; the teammate accepts at
# /accept-invitation/<token> and joins the org with the invited role.

with_clean_db {
    my $org = seed_org('honeywillow');
    my $db  = test_app()->pg->db;

    # A staff checker, signed into their own Test::Mojo.
    staff_actor($org, 'rosie@honeywillow.test', 'paydance.staff.checker');
    my $t = Test::Mojo->new('PD::App');
    sign_in($t, 'rosie@honeywillow.test');

    # --- GET /o/honeywillow/team: the invite form ------------------------
    $t->get_ok('/o/honeywillow/team')->status_is(200)
      ->element_exists('form[method="post"][action$="/o/honeywillow/team"] input[name="email"]')
      ->element_exists('form[method="post"][action$="/o/honeywillow/team"] select[name="role"]');

    # --- POST /o/honeywillow/team: invite a teammate ---------------------
    $t->app->mail->reset_captured;
    $t->post_ok('/o/honeywillow/team' => form => {
        email => 'mate@honeywillow.test',
        role  => 'paydance.staff.payer',
    })->status_is(302)
      ->header_like(Location => qr{/o/honeywillow/team});

    # Following the redirect, the team page carries the confirmation flash
    # (did + next), riding through on the flash.
    $t->get_ok('/o/honeywillow/team')->status_is(200)
      ->element_exists('.pd-flash[role="status"]')
      ->content_like(qr/Invitation sent to mate\@honeywillow\.test\./)
      ->content_like(qr/We will let you know when they accept\./);

    # A validation re-render (no role) shows the amber attention flash inline.
    $t->post_ok('/o/honeywillow/team' => form => { email => 'x@honeywillow.test', role => '' })
      ->status_is(200)
      ->element_exists('.pd-flash--attention')
      ->content_like(qr/Please choose a role for the invitation\./);

    # an invitation row now exists for the invitee
    my $inv = $db->query(
        'SELECT invitation_id, email, role, token FROM organisation_invitations
         WHERE organisation_id = ? AND email = ?',
        $org->{organisation_id}, 'mate@honeywillow.test')->hash;
    ok( $inv, 'organisation_invitations row created' );
    is( $inv->{role}, 'paydance.staff.payer', 'invitation carries the chosen role' );

    # the invitee was emailed; recover the token from the email body
    my $captured = $t->app->mail->captured;
    is( scalar(@$captured), 1, 'one invitation email captured' );
    is( $captured->[0]{to}, 'mate@honeywillow.test', 'email addressed to the invitee' );
    my ($token) = $captured->[0]{text_body} =~ m{/accept-invitation/([0-9a-f]+)};
    $token //= ($captured->[0]{text_body} =~ m{token is:\s*([0-9a-f]+)})[0];
    ok( (defined $token && length $token), 'token recovered from the email' );
    is( $token, $inv->{token}, 'recovered token matches the stored invitation token' );

    # --- GET /accept-invitation/<token>: the accept page -----------------
    $t->get_ok("/accept-invitation/$token")->status_is(200)
      ->content_like(qr/Honeywillow/);

    # --- the invitee signs in (starting with NO grant at the org) --------
    my $t2 = Test::Mojo->new('PD::App');
    $t2->app->service('Auth')->request_sign_in('mate@honeywillow.test');
    sign_in($t2, 'mate@honeywillow.test');

    # before accepting, the invitee has no grant at the org
    my $before = $db->query(
        "SELECT count(*) FROM axs_identity.user_roles
         WHERE scope = ? AND scope_type = 'organisation'", 'honeywillow')->array->[0];
    is( $before, 1, 'only the inviting checker holds a grant before accept' );

    # An invitee with NO passkey is offered one on accepting (covered in
    # t/passkeys/post_signup_offer.t); seed one here so this test exercises the
    # ordinary accept completion that lands straight on the staff console.
    my $mate_id = $db->query(
        'SELECT u.user_id FROM axs_identity.users u
         JOIN axs_identity.user_emails e ON e.user_id = u.user_id
         WHERE e.email = ?', 'mate@honeywillow.test')->hash->{user_id};
    $db->query(<<~'SQL', 'mate-has-a-passkey', $mate_id);
        INSERT INTO axs_identity.webauthn_credentials
            (credential_id, user_id, public_key, sign_count, label)
        VALUES (?, ?, 'opaque-cose-key', 0, 'Seeded')
    SQL

    # --- POST /accept-invitation/<token>: join the org ------------------
    $t2->post_ok("/accept-invitation/$token")->status_is(302)
       ->header_like(Location => qr{/o/honeywillow/staff});

    # the invitee now holds the invited role at the org
    my $granted = $db->query(
        "SELECT role FROM axs_identity.user_roles
         WHERE scope = ? AND scope_type = 'organisation'
         AND   email = ? AND grant_state = 'granted'",
        'honeywillow', 'mate@honeywillow.test')->arrays->flatten->to_array;
    is_deeply( $granted, [ 'paydance.staff.payer' ],
        'invitee granted paydance.staff.payer at honeywillow' );

    # --- the invitee can now reach the org's staff console --------------
    $t2->get_ok('/o/honeywillow/staff')->status_is(200);

    # --- a bad token is handled calmly, not a 500 -----------------------
    $t->get_ok('/accept-invitation/not-a-real-token');
    ok( $t->tx->res->code != 500, 'a bad token does not crash the app' );
    $t->status_is(404);
};

# --- inviting an Admin grants BOTH staff roles on accept -------------------
with_clean_db {
    my $org = seed_org('honeywillow');
    my $db  = test_app()->pg->db;

    staff_actor($org, 'rosie@honeywillow.test', 'paydance.staff.checker');
    my $t = Test::Mojo->new('PD::App');
    sign_in($t, 'rosie@honeywillow.test');

    # the invite form offers the Admin role
    $t->get_ok('/o/honeywillow/team')->status_is(200)
      ->element_exists('select[name="role"] option[value="paydance.staff.admin"]')
      ->content_like(qr/Admin \(full access\)/);

    # invite a teammate as Admin
    $t->app->mail->reset_captured;
    $t->post_ok('/o/honeywillow/team' => form => {
        email => 'ada@honeywillow.test',
        role  => 'paydance.staff.admin',
    })->status_is(302);

    # the pending row is labelled Admin
    $t->get_ok('/o/honeywillow/team')->status_is(200)
      ->content_like(qr/ada\@honeywillow\.test/)
      ->content_like(qr/Admin\s*\x{b7}\s*invited/s);

    # recover the token from the email
    my $captured = $t->app->mail->captured;
    is( scalar(@$captured), 1, 'one admin invitation email captured' );
    my ($token) = $captured->[0]{text_body} =~ m{/accept-invitation/([0-9a-f]+)};
    ok( (defined $token && length $token), 'admin invitation token recovered' );

    # the invitee signs in and accepts (seed a passkey so the accept lands
    # straight on the staff console, as in the flow above)
    my $t2 = Test::Mojo->new('PD::App');
    $t2->app->service('Auth')->request_sign_in('ada@honeywillow.test');
    sign_in($t2, 'ada@honeywillow.test');

    my $ada_id = $db->query(
        'SELECT u.user_id FROM axs_identity.users u
         JOIN axs_identity.user_emails e ON e.user_id = u.user_id
         WHERE e.email = ?', 'ada@honeywillow.test')->hash->{user_id};
    $db->query(<<~'SQL', 'ada-has-a-passkey', $ada_id);
        INSERT INTO axs_identity.webauthn_credentials
            (credential_id, user_id, public_key, sign_count, label)
        VALUES (?, ?, 'opaque-cose-key', 0, 'Seeded')
    SQL

    $t2->post_ok("/accept-invitation/$token")->status_is(302)
       ->header_like(Location => qr{/o/honeywillow/staff});

    # accepting an Admin invitation grants BOTH staff roles (and only those:
    # the virtual admin role itself is never granted)
    my $granted = $db->query(
        "SELECT role FROM axs_identity.user_roles
         WHERE scope = ? AND scope_type = 'organisation'
         AND   email = ? AND grant_state = 'granted'
         ORDER BY role",
        'honeywillow', 'ada@honeywillow.test')->arrays->flatten->to_array;
    is_deeply( $granted, [ 'paydance.staff.checker', 'paydance.staff.payer' ],
        'admin invitee granted BOTH staff roles at honeywillow' );

    # and the new admin can reach the staff console
    $t2->get_ok('/o/honeywillow/staff')->status_is(200);
};

# --- re-invite: Send again rotates the token and re-emails -----------------
with_clean_db {
    my $org = seed_org('honeywillow');
    my $db  = test_app()->pg->db;

    staff_actor($org, 'rosie@honeywillow.test', 'paydance.staff.checker');
    my $t = Test::Mojo->new('PD::App');
    sign_in($t, 'rosie@honeywillow.test');

    # invite someone, then let the invitation lapse
    $t->post_ok('/o/honeywillow/team' => form => {
        email => 'slow@honeywillow.test',
        role  => 'paydance.staff.payer',
    })->status_is(302);

    my $inv = $db->query(
        'SELECT invitation_id, token FROM organisation_invitations
         WHERE organisation_id = ? AND email = ?',
        $org->{organisation_id}, 'slow@honeywillow.test')->hash;
    ok( $inv, 'invitation row created for the slow invitee' );
    my $old_token = $inv->{token};

    $db->query(
        "UPDATE organisation_invitations SET expires_at = now() - interval '1 day'
         WHERE invitation_id = ?", $inv->{invitation_id});

    # the team page shows the lapse calmly, with a Send again button
    $t->get_ok('/o/honeywillow/team')->status_is(200)
      ->content_like(qr/\x{b7}\s*expired/s)
      ->element_exists(
          qq{form[action\$="/team/invitations/$inv->{invitation_id}/resend"] button})
      ->content_like(qr/Send again/);

    # --- POST the resend route -------------------------------------------
    $t->app->mail->reset_captured;
    $t->post_ok("/o/honeywillow/team/invitations/$inv->{invitation_id}/resend")
      ->status_is(302)
      ->header_like(Location => qr{/o/honeywillow/team});

    # following the redirect, the team page carries the confirmation flash
    $t->get_ok('/o/honeywillow/team')->status_is(200)
      ->element_exists('.pd-flash[role="status"]')
      ->content_like(qr/Invitation sent again to slow\@honeywillow\.test\./)
      ->content_like(qr/They have 7 more days to accept\./);

    # the token rotated and the expiry moved back into the future
    my $after = $db->query(
        'SELECT token, expires_at > now() AS in_future
         FROM organisation_invitations WHERE invitation_id = ?',
        $inv->{invitation_id})->hash;
    isnt( $after->{token}, $old_token, 'resend rotates the token' );
    ok( $after->{in_future}, 'resend pushes expires_at into the future' );

    # a fresh email went to the same invitee, carrying the NEW token
    my $captured = $t->app->mail->captured;
    is( scalar(@$captured), 1, 'one fresh invitation email captured' );
    is( $captured->[0]{to}, 'slow@honeywillow.test', 'resent email goes to the same invitee' );
    like( $captured->[0]{text_body}, qr/\Q$after->{token}\E/,
        'resent email carries the NEW token' );
    unlike( $captured->[0]{text_body}, qr/\Q$old_token\E/,
        'resent email does not carry the OLD token' );

    # the OLD emailed link is dead: a calm 404, not a 500
    $t->get_ok("/accept-invitation/$old_token");
    ok( $t->tx->res->code != 500, 'the old token does not crash the app' );
    $t->status_is(404);

    # --- accepting with the NEW token succeeds -----------------------------
    my $t2 = Test::Mojo->new('PD::App');
    $t2->app->service('Auth')->request_sign_in('slow@honeywillow.test');
    sign_in($t2, 'slow@honeywillow.test');

    my $slow_id = $db->query(
        'SELECT u.user_id FROM axs_identity.users u
         JOIN axs_identity.user_emails e ON e.user_id = u.user_id
         WHERE e.email = ?', 'slow@honeywillow.test')->hash->{user_id};
    $db->query(<<~'SQL', 'slow-has-a-passkey', $slow_id);
        INSERT INTO axs_identity.webauthn_credentials
            (credential_id, user_id, public_key, sign_count, label)
        VALUES (?, ?, 'opaque-cose-key', 0, 'Seeded')
    SQL

    $t2->post_ok("/accept-invitation/$after->{token}")->status_is(302)
       ->header_like(Location => qr{/o/honeywillow/staff});

    my $granted = $db->query(
        "SELECT role FROM axs_identity.user_roles
         WHERE scope = ? AND scope_type = 'organisation'
         AND   email = ? AND grant_state = 'granted'",
        'honeywillow', 'slow@honeywillow.test')->arrays->flatten->to_array;
    is_deeply( $granted, [ 'paydance.staff.payer' ],
        'accepting the resent invitation grants the invited role' );

    # --- guard: resending an ACCEPTED invitation flashes calmly ------------
    $t->post_ok("/o/honeywillow/team/invitations/$inv->{invitation_id}/resend")
      ->status_is(302)
      ->header_like(Location => qr{/o/honeywillow/team});
    $t->get_ok('/o/honeywillow/team')->status_is(200)
      ->element_exists('.pd-flash--attention')
      ->content_like(qr/This invitation has already been accepted\./);

    # --- guard: a signed-in NON-STAFF user cannot resend --------------------
    # leave a fresh pending invitation to aim at
    $t->post_ok('/o/honeywillow/team' => form => {
        email => 'another@honeywillow.test',
        role  => 'paydance.staff.checker',
    })->status_is(302);
    my $inv2 = $db->query(
        'SELECT invitation_id, token FROM organisation_invitations
         WHERE organisation_id = ? AND email = ?',
        $org->{organisation_id}, 'another@honeywillow.test')->hash;

    # a party user at the org holds a non-staff grant only (the /o/ bridge
    # lets them in; _staff_at_org must still turn them away)
    party_actor($org, 'party@honeywillow.test');
    my $t3 = Test::Mojo->new('PD::App');
    sign_in($t3, 'party@honeywillow.test');

    $t3->post_ok("/o/honeywillow/team/invitations/$inv2->{invitation_id}/resend")
       ->status_is(403);

    my $untouched = $db->query(
        'SELECT token FROM organisation_invitations WHERE invitation_id = ?',
        $inv2->{invitation_id})->hash;
    is( $untouched->{token}, $inv2->{token},
        'an unauthorised resend leaves the token unchanged' );
};

# --- magic-link accept: a signed-OUT invitee accepts straight from the email --
# The emailed token is an unguessable capability proving control of the invited
# inbox, so POSTing accept signs the invitee in as the invited address — no
# passcode round-trip. The sign-in happens ONLY on POST: mail scanners prefetch
# GETs, so the GET must stay side-effect free.
with_clean_db {
    my $org = seed_org('honeywillow');
    my $db  = test_app()->pg->db;

    staff_actor($org, 'rosie@honeywillow.test', 'paydance.staff.checker');
    my $t = Test::Mojo->new('PD::App');
    sign_in($t, 'rosie@honeywillow.test');

    # invite a payer teammate; recover the token from the email
    $t->app->mail->reset_captured;
    $t->post_ok('/o/honeywillow/team' => form => {
        email => 'fresh@honeywillow.test',
        role  => 'paydance.staff.payer',
    })->status_is(302);
    my ($token) = $t->app->mail->captured->[0]{text_body} =~ m{/accept-invitation/([0-9a-f]+)};
    ok( (defined $token && length $token), 'invitation token recovered from the email' );

    # the invitee opens the link with NO session at all
    my $t2 = Test::Mojo->new('PD::App');
    my $sessions_before = $db->query('SELECT count(*) FROM axs_identity.sessions')->array->[0];

    # the GET shows the magic-link copy + the POST form
    $t2->get_ok("/accept-invitation/$token")->status_is(200)
       ->content_like(qr/Accepting signs you in and adds you to the team - no password needed\./)
       ->element_exists(qq{form[method="post"][action\$="/accept-invitation/$token"] button});

    # ... and stays side-effect free: no session, no user created
    my $sessions_after_get = $db->query('SELECT count(*) FROM axs_identity.sessions')->array->[0];
    is( $sessions_after_get, $sessions_before,
        'the GET creates no session (mail scanners prefetch links)' );
    my $users_after_get = $db->query(
        'SELECT count(*) FROM axs_identity.user_emails WHERE email = ?',
        'fresh@honeywillow.test')->array->[0];
    is( $users_after_get, 0, 'the GET creates no user for the invited address' );

    # POST with no prior session: the token itself signs the invitee in
    $t2->post_ok("/accept-invitation/$token")->status_is(302)
       ->header_like(Location => qr{/o/honeywillow/staff});

    # the invitee is now signed in — the staff console opens as them,
    # carrying the joined confirmation flash
    $t2->get_ok('/o/honeywillow/staff')->status_is(200)
       ->element_exists('.pd-flash[role="status"]')
       ->content_like(qr/You have joined Honeywillow\./);

    # the invited role was granted to the invited address
    my $granted = $db->query(
        "SELECT role FROM axs_identity.user_roles
         WHERE scope = ? AND scope_type = 'organisation'
         AND   email = ? AND grant_state = 'granted'",
        'honeywillow', 'fresh@honeywillow.test')->arrays->flatten->to_array;
    is_deeply( $granted, [ 'paydance.staff.payer' ],
        'signed-out invitee granted paydance.staff.payer at honeywillow' );

    # accepting proved control of the invited inbox: verified_at is stamped
    my $verified = $db->query(
        'SELECT verified_at IS NOT NULL AS verified
         FROM axs_identity.user_emails WHERE email = ?',
        'fresh@honeywillow.test')->hash;
    ok( $verified && $verified->{verified},
        'user_emails.verified_at set for the invited address' );

    # --- the ADMIN variant also works signed-out: BOTH staff roles granted --
    $t->app->mail->reset_captured;
    $t->post_ok('/o/honeywillow/team' => form => {
        email => 'boss@honeywillow.test',
        role  => 'paydance.staff.admin',
    })->status_is(302);
    my ($admin_token) = $t->app->mail->captured->[0]{text_body} =~ m{/accept-invitation/([0-9a-f]+)};
    ok( (defined $admin_token && length $admin_token), 'admin invitation token recovered' );

    my $t3 = Test::Mojo->new('PD::App');
    $t3->post_ok("/accept-invitation/$admin_token")->status_is(302)
       ->header_like(Location => qr{/o/honeywillow/staff});
    $t3->get_ok('/o/honeywillow/staff')->status_is(200);

    my $admin_granted = $db->query(
        "SELECT role FROM axs_identity.user_roles
         WHERE scope = ? AND scope_type = 'organisation'
         AND   email = ? AND grant_state = 'granted'
         ORDER BY role",
        'honeywillow', 'boss@honeywillow.test')->arrays->flatten->to_array;
    is_deeply( $admin_granted, [ 'paydance.staff.checker', 'paydance.staff.payer' ],
        'signed-out admin invitee granted BOTH staff roles' );

    # --- a USED token POSTed signed-out: calm 404, NO session opened --------
    my $t4 = Test::Mojo->new('PD::App');
    my $before_used = $db->query('SELECT count(*) FROM axs_identity.sessions')->array->[0];
    $t4->post_ok("/accept-invitation/$token")->status_is(404)
       ->content_like(qr/find that invitation/);
    my $after_used = $db->query('SELECT count(*) FROM axs_identity.sessions')->array->[0];
    is( $after_used, $before_used, 'a used token opens no session' );

    # a follow-up request is still signed out (bounced to sign-in)
    $t4->get_ok('/o/honeywillow/staff')->status_is(302)
       ->header_like(Location => qr{/sign-in});

    # --- an EXPIRED token POSTed signed-out: calm 404, no session -----------
    $t->app->mail->reset_captured;
    $t->post_ok('/o/honeywillow/team' => form => {
        email => 'late@honeywillow.test',
        role  => 'paydance.staff.payer',
    })->status_is(302);
    my ($late_token) = $t->app->mail->captured->[0]{text_body} =~ m{/accept-invitation/([0-9a-f]+)};
    $db->query(
        "UPDATE organisation_invitations SET expires_at = now() - interval '1 day'
         WHERE token = ?", $late_token);

    my $t5 = Test::Mojo->new('PD::App');
    my $before_expired = $db->query('SELECT count(*) FROM axs_identity.sessions')->array->[0];
    $t5->post_ok("/accept-invitation/$late_token")->status_is(404)
       ->content_like(qr/find that invitation/);
    my $after_expired = $db->query('SELECT count(*) FROM axs_identity.sessions')->array->[0];
    is( $after_expired, $before_expired, 'an expired token opens no session' );

    $t5->get_ok('/o/honeywillow/staff')->status_is(302)
       ->header_like(Location => qr{/sign-in});

    my $late_users = $db->query(
        'SELECT count(*) FROM axs_identity.user_emails WHERE email = ?',
        'late@honeywillow.test')->array->[0];
    is( $late_users, 0, 'an expired token creates no user for the invited address' );
};

done_testing;
