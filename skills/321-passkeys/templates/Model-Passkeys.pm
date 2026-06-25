package F6::Model::Passkeys;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Passkeys.pm
# Description:  CRUD over webauthn_credentials (a user's registered passkeys).
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

has 'db';

sub create ($self, $args) {
    return $self->db->query('passkeys/insert', {
        credential_id => $args->{credential_id},
        user_id       => $args->{user_id},
        public_key    => $args->{public_key},
        sign_count    => $args->{sign_count} // 0,
        transports    => $args->{transports},
        aaguid        => $args->{aaguid},
        label         => $args->{label},
    })->hash;
}

sub for_user ($self, $user_id) {
    return $self->db->query('passkeys/for_user', { user_id => $user_id })->hashes->to_array;
}

sub find ($self, $credential_id) {
    return $self->db->query('passkeys/find', { credential_id => $credential_id })->hash;
}

sub touch ($self, $credential_id, $sign_count) {
    return $self->db->query('passkeys/touch',
        { credential_id => $credential_id, sign_count => $sign_count })->hash;
}

sub remove ($self, $user_id, $credential_id) {
    # Count the RETURNING rows - DBD::Pg's ->rows is unreliable (-1) for a
    # zero-match DELETE.
    my $deleted = $self->db->query('passkeys/delete_for_user',
        { user_id => $user_id, credential_id => $credential_id })->arrays->to_array;
    return scalar @$deleted;
}

1;
