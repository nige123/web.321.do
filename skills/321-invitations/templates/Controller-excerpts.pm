# Copyright Nige Ltd. Author: Nigel Hamilton.
# Controller excerpts from the shipped Paydance implementation (PD:: - rename
# to your namespace). These subs live in the onboarding/team controller;
# _after_signup/_who are the session helpers they lean on.

sub _staff_at_org ($c) {
    my $actor = $c->stash('current_actor');
    my $ok    = $c->stash('org_key');
    my $is_staff = $actor && (
        PD::App::Authz::actor_holds_role($actor, 'paydance.staff.checker', $ok)
        || PD::App::Authz::actor_holds_role($actor, 'paydance.staff.payer', $ok)
    );
    unless ($is_staff) {
        $c->render(template => 'errors/no_access', status => 403);
        return 0;
    }
    return 1;
}


# team - GET /o/:org_key/team. Show the pending invitations and the invite
# form. Behind the /o/:org_key require_session guard; this additionally
# requires the actor to hold a staff role at the org.
sub team ($c) {
    return unless _staff_at_org($c);
    my $pending = $c->service('Invitations')->pending_for_org($c->current_org);
    my $requests = $c->service('AccessRequests')->pending_for_org($c->current_org);
    my $members  = $c->service('StaffProfiles')->list_members($c->stash('current_actor'));
    my $contributors = $c->service('StaffProfiles')->list_contributors($c->stash('current_actor'));
    # The confirmation flash is handled globally (the _flash partial in the
    # layout reads pd_flash from the stash or the redirect flash), so this
    # render carries no notice arg of its own.
    $c->render(template => 'onboarding/team',
        pending => $pending, requests => $requests, members => $members,
        contributors => $contributors);
}


# team_invite - POST /o/:org_key/team. Invite a teammate by email + role.
# On success redirect back to the team page with a notice; on a calm
# AppError re-render the team page with the error message as the notice.
sub team_invite ($c) {
    return unless _staff_at_org($c);

    my $email = $c->param('email') // '';
    $email =~ s/^\s+|\s+$//g;
    my $role  = $c->param('role') // '';

    my $rerender = sub ($notice) {
        # These re-renders are all validation messages, so the flash takes the
        # amber attention tone. Set it on the stash (we re-render this request,
        # we don't redirect) and let the global _flash partial show it.
        $c->set_flash(did => $notice, tone => 'attention', via => 'stash');
        $c->render(template => 'onboarding/team',
            pending => $c->service('Invitations')->pending_for_org($c->current_org),
            requests => $c->service('AccessRequests')->pending_for_org($c->current_org),
            members => $c->service('StaffProfiles')->list_members($c->stash('current_actor')),
            contributors => $c->service('StaffProfiles')->list_contributors($c->stash('current_actor')),
            status => 200);
    };

    return $rerender->('Please enter the email address to invite.')
        unless length $email;
    return $rerender->('Please choose a role for the invitation.')
        unless $INVITABLE_ROLE{$role};

    my $ok = eval {
        $c->service('Invitations')->invite(
            $c->current_org, $email, $role, $c->stash('current_actor'));
        1;
    };
    unless ($ok) {
        my $err = $@;
        my $msg = (ref $err && $err->can('message') && $err->message)
            ? $err->message
            : 'We could not send that invitation. Please try again.';
        return $rerender->($msg);
    }

    $c->set_flash(did => "Invitation sent to $email.", next => "We will let you know when they accept.");
    return $c->redirect_to($c->url_for('org_team'));
}


# team_reinvite - POST /o/:org_key/team/invitations/:invitation_id/resend.
# Send a pending (typically expired) invitation again: Service::Invitations
# rotates the token, extends the expiry, and emails a fresh accept link.
# On a calm AppError (accepted/revoked/not found) flash the message with the
# attention tone; either way redirect back to the team page.
sub team_reinvite ($c) {
    return unless _staff_at_org($c);

    my $sent = eval {
        $c->service('Invitations')->resend(
            $c->current_org, $c->stash('invitation_id'),
            $c->stash('current_actor'));
    };
    if ($sent) {
        $c->set_flash(
            did  => "Invitation sent again to $sent->{email}.",
            next => 'They have 7 more days to accept.');
    }
    else {
        my $err = $@;
        my $msg = (ref $err && $err->can('message') && $err->message)
            ? $err->message
            : 'We could not send that invitation again. Please try again.';
        $c->set_flash(did => $msg, tone => 'attention');
    }
    return $c->redirect_to($c->url_for('org_team'));
}


# request_approve - POST /o/:org_key/team/requests/:request_id/approve. Grant
# the requester a staff role (Service::AccessRequests authorises that the
# current_actor is staff at this org), flash a notice, and redirect back to
# the team page.
sub request_approve ($c) {
    return unless _staff_at_org($c);
    $c->service('AccessRequests')->approve(
        $c->stash('request_id'), $c->stash('current_actor'));
    $c->set_flash(did => 'Access approved.', next => 'They can sign in now.');
    return $c->redirect_to($c->url_for('org_team'));
}


# request_deny - POST /o/:org_key/team/requests/:request_id/deny. Mark the
# request denied (no grant), flash a notice, redirect back to the team page.
sub request_deny ($c) {
    return unless _staff_at_org($c);
    $c->service('AccessRequests')->deny(
        $c->stash('request_id'), $c->stash('current_actor'));
    $c->set_flash(did => 'Request denied.');
    return $c->redirect_to($c->url_for('org_team'));
}


# team_revoke - POST /o/:org_key/team/revoke. Revoke an external contributor's
# org grant (e.g. a bookkeeper). Staff-guarded; the role + user come from the
# form. Service::StaffProfiles::revoke_role does the staff-auth + the revoke.
# Flash a notice and redirect back to the team page.
sub team_revoke ($c) {
    return unless _staff_at_org($c);

    my $user_id = $c->param('user_id');
    my $role    = $c->param('role') // '';
    my $org_key = $c->stash('org_key');

    $c->service('StaffProfiles')->revoke_role(
        $c->stash('current_actor'), $user_id, $role, $org_key);

    $c->set_flash(did => 'Contributor removed.');
    return $c->redirect_to($c->url_for('org_team'));
}


# accept - GET /accept-invitation/:token. Name the inviting org and offer a
sub accept ($c) {
    my $token = $c->stash('token');
    my $inv   = _invitation_view($c, $token);

    unless ($inv && !$inv->{is_invalid}) {
        return $c->render(
            template    => 'errors/error',
            status      => 404,
            error_title => "We can't find that invitation",
            error_body  => 'It may have been used already, withdrawn, or expired.',
        );
    }

    $c->render(template => 'onboarding/accept',
        org           => $inv,
        token         => $token,
        signed_in     => (_who($c) ? 1 : 0));
}


# accept_submit - POST /accept-invitation/:token. A signed-in acceptor
# proceeds as themselves. A signed-OUT acceptor is signed in by the
# invitation itself: the emailed token is an unguessable capability, so
# presenting it proves control of the invited inbox — the same proof a
# sign-in passcode gives — and sign_in_verified opens a session as the
# INVITED email address, no second email or passcode needed. This magic-link
# sign-in happens ONLY on POST: mail scanners prefetch GETs, so the GET must
# stay side-effect free. Accepts the invitation through Service::Invitations
# (which grants the role). A staff invitee drops into the org's staff
# console; an EXTERNAL contributor (e.g. paydance.bookkeeper) has no staff
# console to reach — sending them to staff_home would 403 — so they land on
# a calm confirmation page instead.
sub accept_submit ($c) {
    my $who = _who($c);

    unless ($who) {
        my $inv = _invitation_view($c, $c->stash('token'));

        # An unknown/used/revoked/expired token gets the SAME calm 404 the
        # GET renders — never a bounce to sign-in.
        unless ($inv && !$inv->{is_invalid}) {
            return $c->render(
                template    => 'errors/error',
                status      => 404,
                error_title => "We can't find that invitation",
                error_body  => 'It may have been used already, withdrawn, or expired.',
            );
        }

        my $session = eval {
            $c->service('Auth')->sign_in_verified(
                $inv->{email},
                ($c->req->headers->user_agent // ''),
                ($c->tx->remote_address // ''),
            );
        };
        unless ($session && $session->{token}) {
            return $c->render(
                template    => 'errors/error',
                status      => 500,
                error_title => 'We could not sign you in',
                error_body  => 'Something went wrong on our side. Please open the invitation link from your email and try again.',
            );
        }

        # Establish the signed-in session exactly as verify_submit does.
        $c->session(api_token   => $session->{token});
        $c->session(api_expires => $session->{expires});
        $who = { user_id => $session->{user_id} };
    }

    my $org = eval {
        $c->service('Invitations')->accept(
            $c->stash('token'), { user_id => $who->{user_id} });
    };
    unless ($org) {
        my $err = $@;
        my $msg = (ref $err && $err->can('message') && $err->message)
            ? $err->message
            : 'We could not accept that invitation.';
        return $c->render(
            template    => 'errors/error',
            status      => 404,
            error_title => "We can't accept that invitation",
            error_body  => $msg,
        );
    }

    # Staff roles reach the console; an external contributor does not. Anything
    # that is not a staff role is treated as external and lands on the calm
    # confirmation page rather than being bounced into a no-access staff_home.
    #
    # NOTE: the post-signup passkey offer is FLAG-GATED on passkeys_enabled (see
    # #done). When the flag is ON, a staff invitee with no passkey is offered one
    # first via _after_signup/the /passkeys/add interstitial (whose Add and Skip
    # both continue to the console); with a passkey, or with the flag OFF, they
    # go STRAIGHT to their console. The grant above always applies.
    my $is_staff = ($org->{role} // '') =~ /^paydance\.staff\./;
    if ($is_staff) {
        $c->set_flash(
            did  => "You have joined $org->{display_name}.",
            next => 'You are signed in and ready to go.');
        my $console = $c->url_for('staff_home', org_key => $org->{org_key});
        return $c->redirect_to(
            $c->passkeys_enabled
                ? _after_signup($c, $who->{user_id}, $console)
                : $console);
    }

    return $c->render(
        template => 'onboarding/contributor_done',
        org      => $org,
    );
}


# _invitation_view - look up an invitation by token for display, joined to
# its organisation so the accept page can name the org. Returns a hashref
# with display_name + org_key + an is_invalid flag, or undef for an unknown
# token. Never throws — the accept page must render calmly.
sub _invitation_view ($c, $token) {
    return undef unless defined $token && length $token;
    my $row = eval {
        $c->service('Invitations')->db->sql(<<~'SQL', { token => $token })->hash;
            SELECT i.invitation_id, i.email, i.accepted_at, i.revoked_at,
                   i.expires_at < now() AS is_expired,
                   o.org_key, o.display_name
            FROM organisation_invitations i
            JOIN organisations o ON o.organisation_id = i.organisation_id
            WHERE i.token = [token]
        SQL
    };
    return undef unless $row;
    $row->{is_invalid} = ($row->{accepted_at} || $row->{revoked_at} || $row->{is_expired})
        ? 1 : 0;
    return $row;
}


# _after_signup - the redirect target at a signup completion point. A user who
# finished signup (new org or accepted invitation) and has no passkey yet is
# offered one first (the skippable /passkeys/add interstitial, which then
# continues to the dashboard); a user who already has a passkey goes straight
# to their usual destination. Scoped to signups by being called ONLY from the
# Onboarding completion paths — ordinary sign-in lives in Controller::Auth and
# never reaches here. Returns a URL string ready for redirect_to.
#
# FLAG-GATED: the signup completions (#done and #accept_submit) call this only
# when $c->passkeys_enabled is true; with the flag off they go straight to the
# fallback URL and no user reaches the offer. Returns /passkeys/add for a user
# with no passkey, otherwise the fallback URL.
sub _after_signup ($c, $user_id, $fallback_url) {
    my $passkeys = $c->service('Passkeys')->for_user($user_id);
    return $c->url_for('passkey_add') unless @$passkeys;
    return $fallback_url;
}


# _who - resolve the signed-in session the way Home::require_session does:
# the verified token from the session -> who_am_i -> the actor. Returns the
# who hashref ({ user_id, session_id, grants }) or undef when not signed in.
sub _who ($c) {
    my $token = $c->session('api_token');
    return undef unless defined $token && length $token;
    return eval { $c->service('Auth')->who_am_i($token) };
}


1;
