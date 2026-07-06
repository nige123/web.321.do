# Copyright Nige Ltd. Author: Nigel Hamilton.
package L2D::Web::Controller::Auth;

#------------------------------------------------------------------------------
# Magic-code sign-in: issue a passcode, verify it, mint the session cookie.
# Email passcode is the universal credential; the 321-passkeys skill adds
# passkeys as a faster alternative on top of this flow.
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;

use L2D::Auth::Passcodes;
use L2D::Auth::Sessions;
use L2D::Model::Users;
use L2D::Model::Accounts;

#------------------------------------------------------------------------------
# signin_form - GET /signin[?email=...&next=...]
#------------------------------------------------------------------------------
sub signin_form ($c) {
    my $next_url = _safe_next($c->param('next'));
    my $email_q  = $c->param('email');
    if (my $user = $c->current_user) {
        return $c->redirect_to($next_url) if $next_url;
        return $c->redirect_to(_home_for($c, $user));
    }
    return $c->render(template => 'auth/signin',
        error => undef, email => $email_q, next_url => $next_url);
}

#------------------------------------------------------------------------------
# signin_submit - POST /signin  (issue + email a code, then ask for it)
#------------------------------------------------------------------------------
sub signin_submit ($c) {

    my $passcodes = L2D::Auth::Passcodes->new(db => $c->db);
    my $issued    = $passcodes->issue(
        $c->param('email'), $c->req->headers->user_agent, $c->tx->remote_address,
    );

    unless ($issued->{ok}) {
        my $message = $issued->{error} eq 'rate_limited'
            ? 'Too many codes requested. Try again later.'
            : 'Please enter a valid email address.';
        return $c->render(template => 'auth/signin',
            error => $message, email => $c->param('email'), next_url => undef);
    }

    $c->minion->enqueue(email_passcode => [ $issued->{email}, $issued->{code} ]);

    $c->session(signin_email => $issued->{email});
    if (my $next_url = _safe_next($c->param('next'))) {
        $c->session(signin_next => $next_url);
    }
    return $c->redirect_to('/signin/code');
}

#------------------------------------------------------------------------------
# code_form - GET /signin/code
#------------------------------------------------------------------------------
sub code_form ($c) {
    return $c->redirect_to(_home_for($c, $c->current_user)) if $c->current_user;
    return $c->redirect_to('/signin') unless $c->session('signin_email');
    return $c->render(template => 'auth/code',
        email => $c->session('signin_email'), error => undef);
}

#------------------------------------------------------------------------------
# code_submit - POST /signin/code  (verify, find-or-create user, mint session)
#------------------------------------------------------------------------------
sub code_submit ($c) {

    my $email = $c->session('signin_email');
    return $c->redirect_to('/signin') unless $email;

    my $verified = L2D::Auth::Passcodes->new(db => $c->db)
                        ->verify($email, $c->param('code'));

    unless ($verified->{ok}) {
        return $c->render(template => 'auth/code',
            email => $email, error => 'That code is wrong or expired. Try again.');
    }

    my $user = L2D::Model::Users->new(db => $c->db)
                    ->find_or_create_by_email($verified->{email});

    $c->start_session_for($user->{user_id});

    delete $c->session->{signin_email};
    my $next_url = delete $c->session->{signin_next};

    # (321-passkeys inserts a "add a passkey?" offer here for brand-new signups.)
    return $c->redirect_to($next_url) if $next_url;
    return $c->redirect_to(_home_for($c, $user));
}

#------------------------------------------------------------------------------
# signout - POST /signout
#------------------------------------------------------------------------------
sub signout ($c) {

    my $token = $c->signed_cookie('l2d_session');
    L2D::Auth::Sessions->new(db => $c->db)->revoke($token) if $token;

    $c->signed_cookie(l2d_session => '',
        { path => '/', domain => $c->config('cookie_domain'), expires => 1 });

    return $c->redirect_to('/');
}

#------------------------------------------------------------------------------
# _home_for - where a signed-in user lands: their personal account, else signup.
#------------------------------------------------------------------------------
sub _home_for ($c, $user) {
    my $personal = L2D::Model::Accounts->new(db => $c->db)
        ->personal_for_user($user->{user_id});
    return $personal ? "/\@$personal->{handle}" : '/signup';
}

#------------------------------------------------------------------------------
# _safe_next - only redirect within this app (absolute path, no scheme/CRLF).
#------------------------------------------------------------------------------
sub _safe_next ($next) {
    return undef unless defined $next && length $next;
    return undef unless $next =~ m{\A/};   # path-absolute
    return undef if $next =~ m{\A//};      # block protocol-relative
    return undef if $next =~ m{[\r\n]};    # block header injection
    return $next;
}

1;
