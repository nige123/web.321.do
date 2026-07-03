package L2D::Model::Accounts;

#------------------------------------------------------------------------------
# Unified public-identity model (personal + team). One handle namespace, one
# membership table, one billing surface. Handles are normalised + reserved-word
# checked before insert.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

has 'db';

my %RESERVED_HANDLES = map { $_ => 1 } qw(
    signin signup signout settings teams team account accounts admin api
    health www mail root login logout assets static js css img public
    favicon dashboard billing help about terms privacy pricing
);

#------------------------------------------------------------------------------
# create_personal - create a personal account and seed its owner membership.
#------------------------------------------------------------------------------
sub create_personal ($self, $input) {
    my $handle = $self->_normalise_handle($input->{handle});
    return { ok => 0, error => 'handle' } unless defined $handle;
    return { ok => 0, error => 'handle_taken' } if $self->get_by_handle($handle);
    return { ok => 0, error => 'one_personal_per_user' }
        if $self->_personal_for_user($input->{user_id});

    my $account = $self->db->query('accounts/insert', {
        handle        => $handle,
        kind          => 'personal',
        owner_user_id => $input->{user_id},
        display_name  => $input->{display_name},
    })->hash;

    $self->db->query('account_members/insert', {
        account_id => $account->{account_id},
        user_id    => $input->{user_id},
        role       => 'owner',
    });

    return { ok => 1, account => $account };
}

#------------------------------------------------------------------------------
# create_team - create a team account and seed its owner membership.
#------------------------------------------------------------------------------
sub create_team ($self, $input) {
    my $handle = $self->_normalise_handle($input->{handle});
    return { ok => 0, error => 'handle' } unless defined $handle;
    return { ok => 0, error => 'handle_taken' } if $self->get_by_handle($handle);

    my $account = $self->db->query('accounts/insert', {
        handle        => $handle,
        kind          => 'team',
        owner_user_id => $input->{user_id},
        display_name  => $input->{name},
    })->hash;

    $self->db->query('account_members/insert', {
        account_id => $account->{account_id},
        user_id    => $input->{user_id},
        role       => 'owner',
    });

    return { ok => 1, account => $account };
}

#------------------------------------------------------------------------------
# membership
#------------------------------------------------------------------------------
sub add_member ($self, $input) {
    return $self->db->query('account_members/insert', {
        account_id => $input->{account_id},
        user_id    => $input->{user_id},
        role       => $input->{role} // 'member',
    });
}

sub remove_member ($self, $account_id, $user_id) {
    return $self->db->query('account_members/delete',
        { account_id => $account_id, user_id => $user_id });
}

sub set_role ($self, $account_id, $user_id, $role) {
    return $self->db->query('account_members/set_role',
        { account_id => $account_id, user_id => $user_id, role => $role });
}

sub list_members ($self, $account_id) {
    return $self->db->query('account_members/list', { account_id => $account_id })
        ->hashes->to_array;
}

sub member_role ($self, $account_id, $user_id) {
    my $row = $self->db->query('account_members/get_role',
        { account_id => $account_id, user_id => $user_id })->hash;
    return $row ? $row->{role} : undef;
}

#------------------------------------------------------------------------------
# accounts_for_user - every account the user belongs to (for a switcher).
#------------------------------------------------------------------------------
sub accounts_for_user ($self, $user_id) {
    return $self->db->query('accounts/for_user', { user_id => $user_id })
        ->hashes->to_array;
}

#------------------------------------------------------------------------------
# reads
#------------------------------------------------------------------------------
sub get ($self, $account_id) {
    return $self->db->query('accounts/get', { account_id => $account_id })->hash;
}
sub get_by_handle ($self, $handle) {
    return $self->db->query('accounts/get_by_handle', { handle => $handle })->hash;
}

# personal_for_user - a user's personal account { account_id, handle }.
sub personal_for_user ($self, $user_id) {
    return $self->_personal_for_user($user_id);
}

sub update ($self, $input) {
    return $self->db->query('accounts/update', $input)->hash;
}

#------------------------------------------------------------------------------
# helpers
#------------------------------------------------------------------------------
sub _normalise_handle ($self, $h) {
    return undef unless defined $h;
    $h = lc $h;
    $h =~ s/\A\s+|\s+\z//g;
    $h =~ s/[^a-z0-9-]+/-/g;
    $h =~ s/-+/-/g;
    $h =~ s/\A-+|-+\z//g;
    return undef unless length $h >= 2 && length $h <= 32;
    return undef if $RESERVED_HANDLES{$h};
    return $h;
}

sub _personal_for_user ($self, $user_id) {
    return $self->db->query('accounts/personal_for_user',
        { user_id => $user_id })->hash;
}

1;
