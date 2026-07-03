package L2D::Auth::Sessions;

#------------------------------------------------------------------------------
# Database-backed session tokens. Only the SHA-256 hash of a token is stored;
# the raw token lives in the signed 'l2d_session' cookie. Server-side rows
# make sessions revocable.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use Digest::SHA qw(sha256_hex);
use Nanoid;

has 'db';
has ttl => 60 * 60 * 24 * 14;      # seconds

#------------------------------------------------------------------------------
# create - issue a new session for a user, returning the raw token.
#------------------------------------------------------------------------------
sub create ($self, $user_id) {

    my $token = Nanoid::generate(size => 32);

    my $row = $self->db->query('sessions/create', {
        user_id            => $user_id,
        session_token_hash => sha256_hex($token),
        ttl_seconds        => $self->ttl,
    })->hash;

    return { ok => 1, token => $token, session_id => $row->{session_id} };
}

#------------------------------------------------------------------------------
# resolve - return the live session row (with the user's email) for a raw
#   token, or undef.
#------------------------------------------------------------------------------
sub resolve ($self, $token) {

    return undef unless defined $token && length $token;

    return $self->db->query('sessions/resolve', {
        session_token_hash => sha256_hex($token),
    })->hash;
}

#------------------------------------------------------------------------------
# revoke - kill a session by raw token.
#------------------------------------------------------------------------------
sub revoke ($self, $token) {

    return 0 unless defined $token && length $token;

    my $row = $self->db->query('sessions/revoke', {
        session_token_hash => sha256_hex($token),
    })->hash;

    return $row ? 1 : 0;
}

1;
