# Copyright Nige Ltd. Author: Nigel Hamilton.
package PD::App::Service::Invitations;
use Mojo::Base -base, -signatures;

#------------------------------------------------------------------------------
# Filename:     Invitations.pm
# Description:  Invite a teammate to an organisation by email, accept the
#               invitation (granting the role), or revoke it.
#
#               invite        - generate a token, store an invitation row,
#                               email the invitee an accept URL.
#               accept        - validate the token, grant the role at the
#                               organisation, mark the invitation accepted.
#               revoke        - mark an invitation revoked.
#               pending_for_org - list un-accepted, un-revoked invitations.
#
#               Tokens expire 7 days after the invitation is created.
#------------------------------------------------------------------------------

use PD::App::AppError;
use Crypt::URandom qw(urandom);
use Mojo::Util qw(xml_escape);

has 'db';           # PD::App::AXS::DB
has 'mailer';       # PD::App::Mailer
has 'settings';     # PD::App::Settings
has 'axs_users';    # PD::App::AXS::Users

# The roles an invitation may grant. The two staff roles plus the external
# bookkeeper contributor — the latter is granted at the org but NOT given the
# staff console (see Controller::Onboarding / Grants / Home for the gate).
# 'paydance.staff.admin' is VIRTUAL: it exists only on invitation rows and is
# never granted itself — accept() expands it to BOTH staff roles.
my %INVITABLE_ROLE = (
    'paydance.staff.checker' => 1,
    'paydance.staff.payer'   => 1,
    'paydance.staff.admin'   => 1,
    'paydance.bookkeeper'    => 1,
);


#------------------------------------------------------------------------------
# invite - create an invitation and email the invitee an accept URL.
#------------------------------------------------------------------------------
sub invite ($self, $org, $email, $role, $inviter_actor) {

    PD::App::AppError->throw(http_status => 400, message => 'An email address is required.')
        unless defined $email && length $email;

    PD::App::AppError->throw(http_status => 400, message => 'That is not an invitable role.')
        unless $INVITABLE_ROLE{ $role // '' };

    # A url-safe 40-hex-char token (CSPRNG: an invitation token is a
    # security capability, so it must be unguessable).
    my $token = unpack('H*', urandom(20));

    my $invited_by = $inviter_actor && $inviter_actor->can('user_id')
        ? $inviter_actor->user_id
        : undef;

    my $invitation = $self->db->sql(<<~'SQL',
        INSERT INTO organisation_invitations
            (organisation_id, email, role, token, invited_by_user_id, expires_at)
        VALUES
            ([organisation_id], [email], [role], [token], [invited_by_user_id],
             now() + interval '7 days')
        RETURNING invitation_id, organisation_id, email, role, token,
                  invited_by_user_id, accepted_at, revoked_at,
                  expires_at, created_at
    SQL
        {
            organisation_id    => $org->{organisation_id},
            email              => $email,
            role               => $role,
            token              => $token,
            invited_by_user_id => $invited_by,
        })->hash;

    $self->_send_invitation_email($org, $email, $token);

    return $invitation;

}


#------------------------------------------------------------------------------
# _send_invitation_email - email the invitee their accept URL. Used by both
# invite() and resend(); a no-op when the service has no mailer.
#------------------------------------------------------------------------------
sub _send_invitation_email ($self, $org, $email, $token) {

    return unless $self->mailer;

    my $accept_url = "https://paydance.com/accept-invitation/$token";
    my $from       = $self->settings
        ? $self->settings->get_or('postmark_from_email', 'team@paydance.com')
        : 'team@paydance.com';

    my $org_name_safe = xml_escape($org->{display_name});

    my $body = <<~"HTML";
        <p style="font-family:Georgia,'Times New Roman',serif;font-weight:600;font-size:24px;line-height:1.25;color:#080832;margin:0 0 12px;">You're invited to join $org_name_safe</p>
        <p style="font-size:16px;line-height:1.5;color:#2A2A3A;margin:0 0 24px;">$org_name_safe has invited you to join their team on Paydance — a calmer way to keep payments moving step by step.</p>
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 24px;">
          <tr><td style="border-radius:10px;background:#5B2FD6;">
            <a href="$accept_url" style="display:inline-block;padding:14px 28px;color:#FFFFFF;text-decoration:none;font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;letter-spacing:0.01em;">Accept invitation</a>
          </td></tr>
        </table>
        <p style="font-size:14px;line-height:1.5;color:#6A6A7A;margin:0 0 12px;">If the button doesn't work, paste this link into your browser:</p>
        <p style="font-size:14px;line-height:1.5;color:#5B2FD6;word-break:break-all;margin:0;"><a href="$accept_url" style="color:#5B2FD6;text-decoration:underline;">$accept_url</a></p>
        HTML

    my $html_body = _email_shell($body);

    $self->mailer->send(
        from      => $from,
        to        => $email,
        subject   => 'You have been invited to join ' . $org->{display_name} . ' on Paydance',
        text_body => "You have been invited to join "
            . $org->{display_name}
            . " on Paydance.\n\n"
            . "Accept this invitation: $accept_url\n\n"
            . "Your invitation token is: $token\n",
        html_body => $html_body,
    );

    return;

}


#------------------------------------------------------------------------------
# accept - validate the token, grant the role, mark the invitation accepted.
#------------------------------------------------------------------------------
sub accept ($self, $token, $user) {

    my $invitation = $self->db->sql(<<~'SQL', { token => $token })->hash;
        SELECT i.invitation_id, i.organisation_id, i.email, i.role,
               i.accepted_at, i.revoked_at, i.expires_at,
               i.expires_at < now() AS is_expired,
               o.organisation_id AS org_id, o.org_key,
               o.display_name, o.inbound_address
        FROM organisation_invitations i
        JOIN organisations o ON o.organisation_id = i.organisation_id
        WHERE i.token = [token]
    SQL

    PD::App::AppError->throw(http_status => 404, message => 'Invitation not found.')
        unless $invitation;

    PD::App::AppError->throw(http_status => 409, message => 'This invitation is no longer valid.')
        if $invitation->{revoked_at};

    PD::App::AppError->throw(http_status => 409, message => 'This invitation has already been accepted.')
        if $invitation->{accepted_at};

    PD::App::AppError->throw(http_status => 409, message => 'This invitation has expired.')
        if $invitation->{is_expired};

    # Grant the role and mark the invitation accepted atomically: if the
    # process dies between the two, neither lands - otherwise the role
    # could be granted while the token stayed permanently re-usable.
    my $tx = $self->db->db->begin;

    # The virtual admin role expands to BOTH staff roles (there is no admin
    # grant — an admin is simply someone who holds checker AND payer). Every
    # other role grants exactly itself.
    my @roles_to_grant = $invitation->{role} eq 'paydance.staff.admin'
        ? ('paydance.staff.checker', 'paydance.staff.payer')
        : ($invitation->{role});

    # Grant the invited role(s) at the organisation if not already granted.
    for my $role (@roles_to_grant) {
        $self->db->sql(<<~'SQL',
            INSERT INTO axs_identity.user_roles
                (email, user_id, scope_type, scope, role, grant_state)
            VALUES ([email], [user_id], 'organisation', [scope], [role], 'granted')
            ON CONFLICT DO NOTHING
        SQL
            {
                email   => $invitation->{email},
                user_id => $user->{user_id},
                scope   => $invitation->{org_key},
                role    => $role,
            });
    }

    $self->db->sql(<<~'SQL', { invitation_id => $invitation->{invitation_id} });
        UPDATE organisation_invitations
        SET accepted_at = now()
        WHERE invitation_id = [invitation_id]
    SQL

    $tx->commit;

    return {
        organisation_id => $invitation->{org_id},
        org_key         => $invitation->{org_key},
        display_name    => $invitation->{display_name},
        inbound_address => $invitation->{inbound_address},
        role            => $invitation->{role},
    };

}


#------------------------------------------------------------------------------
# revoke - mark an invitation revoked.
#------------------------------------------------------------------------------
sub revoke ($self, $invitation_id) {

    $self->db->sql(<<~'SQL', { invitation_id => $invitation_id });
        UPDATE organisation_invitations
        SET revoked_at = now()
        WHERE invitation_id = [invitation_id]
    SQL

    return;

}


#------------------------------------------------------------------------------
# resend - send an invitation again with a fresh token and a fresh 7 days.
#          The main use case is an expired invitation, so expired rows are
#          allowed; accepted or revoked ones are not. Rotating the token
#          deliberately invalidates the previously emailed accept link.
#------------------------------------------------------------------------------
sub resend ($self, $org, $invitation_id, $inviter_actor) {

    my $row = $self->db->sql(<<~'SQL',
        SELECT invitation_id, organisation_id, email, role,
               accepted_at, revoked_at, expires_at
        FROM organisation_invitations
        WHERE invitation_id   = [invitation_id]
        AND   organisation_id = [organisation_id]
    SQL
        {
            invitation_id   => $invitation_id,
            organisation_id => $org->{organisation_id},
        })->hash;

    PD::App::AppError->throw(http_status => 404, message => 'Invitation not found.')
        unless $row;

    PD::App::AppError->throw(http_status => 409, message => 'This invitation has already been accepted.')
        if $row->{accepted_at};

    PD::App::AppError->throw(http_status => 409, message => 'This invitation was revoked.')
        if $row->{revoked_at};

    # A fresh unguessable token (same CSPRNG pattern as invite) and a fresh
    # 7-day window. The old emailed link stops working from here.
    my $token = unpack('H*', urandom(20));

    my $updated = $self->db->sql(<<~'SQL',
        UPDATE organisation_invitations
        SET token = [token], expires_at = now() + interval '7 days'
        WHERE invitation_id = [invitation_id]
        RETURNING invitation_id, organisation_id, email, role, token,
                  invited_by_user_id, accepted_at, revoked_at,
                  expires_at, created_at
    SQL
        {
            token         => $token,
            invitation_id => $row->{invitation_id},
        })->hash;

    $self->_send_invitation_email($org, $updated->{email}, $token);

    return $updated;

}


#------------------------------------------------------------------------------
# pending_for_org - list un-accepted, un-revoked invitations for an org.
#------------------------------------------------------------------------------
sub pending_for_org ($self, $org) {

    return $self->db->sql(<<~'SQL', { organisation_id => $org->{organisation_id} })->hashes->to_array;
        SELECT invitation_id, organisation_id, email, role, token,
               invited_by_user_id, accepted_at, revoked_at,
               expires_at, created_at,
               expires_at < now() AS is_expired
        FROM organisation_invitations
        WHERE organisation_id = [organisation_id]
        AND   accepted_at IS NULL
        AND   revoked_at  IS NULL
        ORDER BY created_at
    SQL

}


# _email_shell - wrap a body fragment in the branded inline-HTML envelope.
# File-scoped (not a method): keeps the service class surface clean.
sub _email_shell ($body_html) {
    return <<~"HTML";
        <!doctype html>
        <html lang="en">
        <body style="margin:0;padding:0;background:#FBFBFD;font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;color:#2A2A3A;">
          <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#FBFBFD;">
            <tr><td align="center" style="padding:40px 16px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="480" style="max-width:480px;width:100%;background:#FFFFFF;border:1px solid #E7E7EE;border-radius:14px;">
                <tr><td style="padding:32px 32px 8px;">
                  <a href="https://paydance.com/" style="text-decoration:none;color:#080832;display:inline-block;">
                    <img src="https://paydance.com/assets/logo-device.svg" width="32" height="32" alt="" style="vertical-align:middle;display:inline-block;">
                    <span style="font-family:Georgia,'Times New Roman',serif;font-weight:600;font-size:22px;letter-spacing:-0.01em;vertical-align:middle;margin-left:10px;color:#080832;">Paydance</span>
                  </a>
                </td></tr>
                <tr><td style="padding:24px 32px 32px;">
                  $body_html
                </td></tr>
                <tr><td style="padding:20px 32px;border-top:1px solid #E7E7EE;font-size:13px;line-height:1.5;color:#6A6A7A;">
                  Paydance keeps payments moving step by step.<br>
                  <a href="https://paydance.com/payment-rules" style="color:#6A6A7A;text-decoration:underline;">Payment rules</a>
                  &nbsp;·&nbsp;
                  <a href="https://paydance.com/terms" style="color:#6A6A7A;text-decoration:underline;">Terms</a>
                  &nbsp;·&nbsp;
                  <a href="https://paydance.com/privacy" style="color:#6A6A7A;text-decoration:underline;">Privacy</a>
                </td></tr>
              </table>
            </td></tr>
          </table>
        </body>
        </html>
        HTML
}


1;
