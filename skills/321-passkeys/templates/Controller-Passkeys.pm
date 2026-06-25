package F6::Web::Controller::Passkeys;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Passkeys.pm
# Description:  WebAuthn ceremonies - register a passkey, sign in with one,
#               list/remove them. Verification is delegated to F6::Auth::WebAuthn.
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;

use F6::Model::Passkeys;
use F6::Model::Users;
use F6::Model::Accounts;
use Mojo::JSON qw(encode_json);

#------------------------------------------------------------------------------
# POST /auth/passkey/login/options
#------------------------------------------------------------------------------
sub login_options ($c) {
    my $wa        = $c->webauthn;
    my $challenge = $wa->new_challenge;
    $c->session(webauthn => { type => 'login', challenge => $challenge, exp => time + 300 });
    return $c->render(json => $wa->request_options(challenge => $challenge));
}

#------------------------------------------------------------------------------
# POST /auth/passkey/login/verify
#------------------------------------------------------------------------------
sub login_verify ($c) {
    my $sess = $c->session('webauthn');
    return $c->render(json => { ok => 0, error => 'no_challenge' }, status => 400)
        unless $sess && ($sess->{type} // '') eq 'login' && ($sess->{exp} // 0) >= time;
    delete $c->session->{webauthn};

    my $body = $c->req->json
        or return $c->render(json => { ok => 0, error => 'bad_request' }, status => 400);
    my $resp = $body->{response} // {};

    my $passkeys = F6::Model::Passkeys->new(db => $c->db);
    my $cred = $passkeys->find($body->{id} // '')
        or return $c->render(json => { ok => 0, error => 'unknown_credential' }, status => 400);

    # verify_assertion returns { signature_count } on success, DIES otherwise.
    my $result = eval {
        $c->webauthn->verify_assertion(
            challenge          => $sess->{challenge},
            public_key         => $cred->{public_key},
            sign_count         => $cred->{sign_count},
            client_data_json   => $resp->{clientDataJSON},
            authenticator_data => $resp->{authenticatorData},
            signature          => $resp->{signature},
        );
    };
    return $c->render(json => { ok => 0, error => 'verify_failed' }, status => 400)
        unless $result && defined $result->{signature_count};

    # Sign-count replay check, tolerant of authenticators that always send 0.
    my $new_count = $result->{signature_count} // 0;
    if ($cred->{sign_count} && $new_count && $new_count <= $cred->{sign_count}) {
        return $c->render(json => { ok => 0, error => 'counter' }, status => 400);
    }
    $passkeys->touch($cred->{credential_id}, $new_count);

    $c->start_session_for($cred->{user_id});
    return $c->render(json => { ok => 1, redirect => _home_for($c, $cred->{user_id}) });
}

#------------------------------------------------------------------------------
# POST /auth/passkey/register/options   (auth required)
#------------------------------------------------------------------------------
sub register_options ($c) {
    my $user = $c->current_user
        or return $c->render(json => { ok => 0, error => 'auth' }, status => 401);

    my $users    = F6::Model::Users->new(db => $c->db);
    my $passkeys = F6::Model::Passkeys->new(db => $c->db);
    my $handle   = $users->ensure_webauthn_handle($user->{user_id});
    my @exclude  = map { $_->{credential_id} } @{ $passkeys->for_user($user->{user_id}) };

    my $wa        = $c->webauthn;
    my $challenge = $wa->new_challenge;
    $c->session(webauthn => {
        type => 'register', challenge => $challenge,
        user_id => $user->{user_id}, exp => time + 300,
    });

    return $c->render(json => $wa->creation_options(
        challenge   => $challenge,
        user_handle => $handle,
        email       => $user->{email},
        display     => $user->{email},
        exclude     => \@exclude,
    ));
}

#------------------------------------------------------------------------------
# POST /auth/passkey/register/verify    (auth required)
#------------------------------------------------------------------------------
sub register_verify ($c) {
    my $user = $c->current_user
        or return $c->render(json => { ok => 0, error => 'auth' }, status => 401);
    my $sess = $c->session('webauthn');
    return $c->render(json => { ok => 0, error => 'no_challenge' }, status => 400)
        unless $sess && ($sess->{type} // '') eq 'register'
            && ($sess->{user_id} // 0) == $user->{user_id} && ($sess->{exp} // 0) >= time;
    delete $c->session->{webauthn};

    my $body = $c->req->json
        or return $c->render(json => { ok => 0, error => 'bad_request' }, status => 400);
    my $resp = $body->{response} // {};

    # verify_registration returns the credential on success, DIES otherwise.
    my $result = eval {
        $c->webauthn->verify_registration(
            challenge          => $sess->{challenge},
            client_data_json   => $resp->{clientDataJSON},
            attestation_object => $resp->{attestationObject},
        );
    };
    return $c->render(json => { ok => 0, error => 'verify_failed' }, status => 400)
        unless $result && $result->{credential_id};

    F6::Model::Passkeys->new(db => $c->db)->create({
        credential_id => $result->{credential_id},
        user_id       => $user->{user_id},
        public_key    => $result->{credential_pubkey},
        sign_count    => $result->{signature_count} // 0,
        transports    => ($body->{transports} ? encode_json($body->{transports}) : undef),
        label         => ($body->{label} && length $body->{label}) ? $body->{label} : 'Passkey',
    });

    return $c->render(json => { ok => 1 });
}

#------------------------------------------------------------------------------
# GET /passkeys/add   (auth required) - skippable post-signup interstitial
#------------------------------------------------------------------------------
sub add_form ($c) {
    my $user = $c->current_user or return $c->redirect_to('/signin');
    return $c->render(template => 'auth/passkey_offer', home => _home_for($c, $user->{user_id}));
}

#------------------------------------------------------------------------------
# POST /passkeys/:credential_id/remove   (auth required)
#------------------------------------------------------------------------------
sub remove ($c) {
    my $user = $c->current_user or return $c->redirect_to('/signin');
    F6::Model::Passkeys->new(db => $c->db)->remove($user->{user_id}, $c->param('credential_id'));
    my $next = $c->param('next');
    return $c->redirect_to(($next && $next =~ m{\A/[^/]}) ? $next : _home_for($c, $user->{user_id}));
}

#------------------------------------------------------------------------------
# _home_for - the user's first account page, mirroring Auth.pm's post-login dest
#------------------------------------------------------------------------------
sub _home_for ($c, $user_id) {
    my $own   = F6::Model::Accounts->new(db => $c->db)->accounts_with_arrays_for_user($user_id);
    my $first = $own->[0];
    return $first ? "/\@$first->{handle}" : '/signup';
}

1;
