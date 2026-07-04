package L2D::Model::Shares;

#------------------------------------------------------------------------------
# Revocable share tokens for Love2s, Role Specs and comparisons. Only
# the SHA-256 hash of a token is stored (column token_hash); the raw token
# appears only in the share URL (/p/:token, /r/:token, /c/:token). Mirrors
# L2D::Auth::Sessions.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use Digest::SHA qw(sha256_hex);
use Nanoid;

has 'db';

# Whitelisted resource types -> their ownership query + public URL prefix.
my %OWNED_QUERY = (
    love_profile => 'share_tokens/profile_owned',
    role_spec    => 'share_tokens/role_spec_owned',
    comparison   => 'share_tokens/comparison_owned',
);

my %URL_PREFIX = (
    love_profile => 'p',
    role_spec    => 'r',
    comparison   => 'c',
);

sub valid_type ($self, $type) {
    return defined $type && exists $OWNED_QUERY{$type} ? 1 : 0;
}

sub url_prefix ($self, $type) {
    return $URL_PREFIX{$type};
}

#------------------------------------------------------------------------------
# create - mint a share token for a resource the user owns, returning the raw
#   token (the only time it ever exists outside a URL).
#------------------------------------------------------------------------------
sub create ($self, $user_id, $resource_type, $resource_id) {

    return { ok => 0, error => 'bad_type' }
        unless $self->valid_type($resource_type);

    my $owned = $self->db->query($OWNED_QUERY{$resource_type}, {
        resource_id => $resource_id,
        user_id     => $user_id,
    })->hash;

    return { ok => 0, error => 'not_owner' } unless $owned;

    my $token = Nanoid::generate(size => 24);

    my $row = $self->db->query('share_tokens/insert', {
        token_hash         => sha256_hex($token),
        resource_type      => $resource_type,
        resource_id        => $resource_id,
        created_by_user_id => $user_id,
    })->hash;

    return { ok => 1, token => $token, share => $row };
}

#------------------------------------------------------------------------------
# resolve - live share row for a raw token, or undef. The expected type must
#   match the row, so a role_spec token fetched via /p/... resolves to nothing.
#------------------------------------------------------------------------------
sub resolve ($self, $token, $expected_type) {

    return undef unless defined $token && length $token;

    my $row = $self->db->query('share_tokens/resolve', {
        token_hash => sha256_hex($token),
    })->hash;

    return undef unless $row && $row->{resource_type} eq $expected_type;

    return $row;
}

#------------------------------------------------------------------------------
# revoke - owner-only revoke by id. Returns the (revoked) row, or undef when
#   the row does not exist or is not the caller's.
#------------------------------------------------------------------------------
sub revoke ($self, $share_token_id, $user_id) {

    return $self->db->query('share_tokens/revoke', {
        share_token_id     => $share_token_id,
        created_by_user_id => $user_id,
    })->hash;
}

#------------------------------------------------------------------------------
# Public read-only projections rendered on the share pages. Each selects ONLY
# the columns safe to show anonymously (never raw answers or source text).
#------------------------------------------------------------------------------
sub shared_profile ($self, $profile_id) {
    return $self->db->query('share_tokens/profile_public', {
        profile_id => $profile_id,
    })->expand->hash;
}

sub shared_role_spec ($self, $role_spec_id) {
    return $self->db->query('share_tokens/role_spec_public', {
        role_spec_id => $role_spec_id,
    })->expand->hash;
}

sub shared_comparison ($self, $comparison_id) {
    return $self->db->query('share_tokens/comparison_public', {
        comparison_id => $comparison_id,
    })->expand->hash;
}

1;
