package L2D::Model::Users;

#------------------------------------------------------------------------------
# User records, keyed by email. Sign-in is find-or-create: the passcode flow
# proves control of the address, so a verified passcode is enough to make (or
# find) the user.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

has 'db';

sub find_or_create_by_email ($self, $email) {
    return $self->db->query('users/upsert_by_email', { email => $email })->hash;
}

sub get ($self, $user_id) {
    return $self->db->query('users/get', { user_id => $user_id })->hash;
}

sub by_email ($self, $email) {
    return $self->db->query('users/get_by_email', { email => $email })->hash;
}

1;
