package F6::Auth::WebAuthn;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     WebAuthn.pm
# Description:  Build WebAuthn ceremony options and verify the browser's
#               responses, delegating the crypto to Authen::WebAuthn.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use Authen::WebAuthn;
use Crypt::PRNG qw(random_bytes);
use MIME::Base64 qw(encode_base64url);

has [qw(rp_id origin rp_name)];

sub _lib ($self) {
    return Authen::WebAuthn->new(rp_id => $self->rp_id, origin => $self->origin);
}

sub new_challenge ($self) {
    return encode_base64url(random_bytes(32));
}

# publicKeyCredentialCreationOptions (registration)
sub creation_options ($self, %a) {
    return {
        challenge => $a{challenge},
        rp   => { id => $self->rp_id, name => $self->rp_name },
        user => {
            id          => $a{user_handle},
            name        => $a{email},
            displayName => $a{display} // $a{email},
        },
        pubKeyCredParams => [
            { type => 'public-key', alg => -7 },     # ES256
            { type => 'public-key', alg => -257 },   # RS256
        ],
        authenticatorSelection => {
            residentKey      => 'required',
            userVerification => 'preferred',
        },
        excludeCredentials =>
            [ map {{ type => 'public-key', id => $_ }} @{ $a{exclude} // [] } ],
        attestation => 'none',
        timeout     => 60000,
    };
}

# publicKeyCredentialRequestOptions (authentication, discoverable)
sub request_options ($self, %a) {
    return {
        challenge        => $a{challenge},
        rpId             => $self->rp_id,
        userVerification => 'preferred',
        allowCredentials => [],
        timeout          => 60000,
    };
}

# Verify a registration response. Returns the library result hash
# ({ credential_id, credential_pubkey, signature_count, ... }) or dies.
# allow_untrusted_attestation: we request attestation:'none', so the
# self/none attestation is expected and accepted.
sub verify_registration ($self, %a) {
    return $self->_lib->validate_registration(
        challenge_b64               => $a{challenge},
        requested_uv                => 'preferred',
        client_data_json_b64        => $a{client_data_json},
        attestation_object_b64      => $a{attestation_object},
        token_binding_id_b64        => undef,
        allow_untrusted_attestation => 1,
    );
}

# Verify an assertion. Returns { signature_count => N } or DIES on any
# failure (bad signature, wrong challenge/origin, unknown credential).
sub verify_assertion ($self, %a) {
    return $self->_lib->validate_assertion(
        challenge_b64          => $a{challenge},
        credential_pubkey_b64  => $a{public_key},
        stored_sign_count      => $a{sign_count},
        requested_uv           => 'preferred',
        client_data_json_b64   => $a{client_data_json},
        authenticator_data_b64 => $a{authenticator_data},
        signature_b64          => $a{signature},
        token_binding_id_b64   => undef,
    );
}

1;
