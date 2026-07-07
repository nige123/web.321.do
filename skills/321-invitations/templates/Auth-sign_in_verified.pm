# Copyright Nige Ltd. Author: Nigel Hamilton.
# Service::Auth excerpt (PD:: - rename to your namespace): sign_in_verified
# is the magic-link half of passcode sign-in - everything AFTER proof of
# inbox control. verify_sign_in delegates to it after checking the passcode.

sub verify_sign_in ($self, $email, $passcode, $user_agent = undef, $ip_address = undef) {

    my $norm = normalise_email($email)
        or PD::App::AppError->throw(
            http_status => 400,
            message     => 'Please enter a valid email address.',
        );

    PD::App::AppError->throw(
        http_status => 400,
        message     => 'Please enter the passcode from the email.',
    ) unless defined $passcode && length $passcode;

    my $verified = $self->passcodes->verify_passcode_for_email($norm, $passcode);

    PD::App::AppError->throw(
        http_status => 400,
        message     => 'That passcode is not right or has expired.',
    ) unless $verified;

    return $self->sign_in_verified($norm, $user_agent, $ip_address);
}


# sign_in_verified - open a session for an email address whose ownership has
# ALREADY been proven. The passcode path (verify_sign_in) proves it by code;
# other callers prove it by an emailed unguessable capability (e.g. an
# invitation token — see Controller::Onboarding::accept_submit). Finds or
# creates the user, stamps the email verified, creates the session.
# Returns { token, expires, user_id } — the same shape verify_sign_in returns.
sub sign_in_verified ($self, $email, $user_agent = undef, $ip_address = undef) {

    my $norm = normalise_email($email)
        or PD::App::AppError->throw(
            http_status => 400,
            message     => 'Please enter a valid email address.',
        );

    # find_by_email, then find-or-create, then find_by_email again. The
    # trailing re-query is REQUIRED, not redundant: find_or_create_by_email
    # is a single data-modifying-CTE statement, and PostgreSQL does not let
    # the statement's final SELECT see rows its own CTEs just inserted — so
    # for a brand-new email it creates the user but returns undef. A fresh
    # find_by_email then reads the now-committed row.
    my $user = $self->users->find_by_email($norm);
    unless ($user && $user->{user_id}) {
        $self->users->find_or_create_by_email($norm);
        $user = $self->users->find_by_email($norm);
    }

    PD::App::AppError->throw(
        http_status => 500,
        message     => 'We could not resolve your account.',
    ) unless $user && $user->{user_id};

    # Completing sign-in proves email ownership.
    $self->db->sql(<<~'SQL', { email => $norm });
        UPDATE user_emails
        SET verified_at = COALESCE(verified_at, now())
        WHERE email = [email]
    SQL

    my $session = $self->sessions->create($user->{user_id}, 'human', $user_agent, $ip_address);

    PD::App::AppError->throw(
        http_status => 500,
        message     => 'We could not create a session.',
    ) unless $session && $session->{session_token};

    return {
        token   => $session->{session_token},
        expires => $session->{expires_at},
        user_id => $user->{user_id},
    };
}
