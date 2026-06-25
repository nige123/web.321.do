package Test::WebAuthn;

#------------------------------------------------------------------------------
# A headless software authenticator for tests. Produces the base64url fields a
# browser's navigator.credentials.create()/get() would send, signed with a
# real P-256 key, so Authen::WebAuthn verifies them for real.
#------------------------------------------------------------------------------

use Mojo::Base -strict, -signatures;

use Crypt::PK::ECC;
use Crypt::PRNG qw(random_bytes);
use MIME::Base64 qw(encode_base64url);

use Exporter 'import';
our @EXPORT_OK = qw(new_authenticator);

# new_authenticator(credential_id => 'raw bytes', sign_count => 0)
sub new_authenticator (%opt) {
    my $pk = Crypt::PK::ECC->new;
    $pk->generate_key('nistp256');
    my $raw = $pk->export_key_raw('public');     # 0x04 || X(32) || Y(32)
    return Test::WebAuthn::Device->new(
        pk         => $pk,
        x          => substr($raw, 1, 32),
        y          => substr($raw, 33, 32),
        cred_id    => $opt{credential_id} // ('cred-' . encode_base64url(random_bytes(16))),
        sign_count => $opt{sign_count} // 0,
    );
}

package Test::WebAuthn::Device;

use Mojo::Base -base, -signatures;

use Crypt::Digest::SHA256 qw(sha256);
use CBOR::XS qw(encode_cbor);
use MIME::Base64 qw(encode_base64url);
use JSON::PP qw(encode_json);

has [qw(pk x y cred_id sign_count)];

# COSE_Key for an EC2 P-256 public key.
sub _cose_key ($self) {
    return encode_cbor({
        1  => 2,            # kty: EC2
        3  => -7,           # alg: ES256
        -1 => 1,            # crv: P-256
        -2 => $self->x,     # x
        -3 => $self->y,     # y
    });
}

sub _auth_data ($self, $rp_id, $flags, $with_cred) {
    my $data = sha256($rp_id) . chr($flags) . pack('N', $self->sign_count);
    if ($with_cred) {
        $data .= ("\x00" x 16)                     # aaguid (zeros)
              .  pack('n', length $self->cred_id)  # credential id length
              .  $self->cred_id
              .  $self->_cose_key;
    }
    return $data;
}

# { id, response => { clientDataJSON, attestationObject } } for registration.
sub register ($self, $challenge_b64u, $rp_id, $origin) {
    my $client = encode_json({
        type      => 'webauthn.create',
        challenge => $challenge_b64u,
        origin    => $origin,
    });
    my $att = encode_cbor({
        fmt      => 'none',
        attStmt  => {},
        authData => $self->_auth_data($rp_id, 0x45, 1),   # UP|UV|AT
    });
    return {
        id       => encode_base64url($self->cred_id),
        type     => 'public-key',
        response => {
            clientDataJSON    => encode_base64url($client),
            attestationObject => encode_base64url($att),
        },
    };
}

# { id, response => { clientDataJSON, authenticatorData, signature } } for login.
sub assert ($self, $challenge_b64u, $rp_id, $origin) {
    $self->sign_count($self->sign_count + 1);
    my $client = encode_json({
        type      => 'webauthn.get',
        challenge => $challenge_b64u,
        origin    => $origin,
    });
    my $auth_data = $self->_auth_data($rp_id, 0x05, 0);   # UP|UV
    my $sig       = $self->pk->sign_message($auth_data . sha256($client), 'SHA256');
    return {
        id       => encode_base64url($self->cred_id),
        type     => 'public-key',
        response => {
            clientDataJSON    => encode_base64url($client),
            authenticatorData => encode_base64url($auth_data),
            signature         => encode_base64url($sig),
        },
    };
}

1;
