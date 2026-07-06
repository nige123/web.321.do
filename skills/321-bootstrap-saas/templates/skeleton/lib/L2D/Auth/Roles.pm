# Copyright Nige Ltd. Author: Nigel Hamilton.
package L2D::Auth::Roles;

#------------------------------------------------------------------------------
# Single source of truth for the team role hierarchy (owner > admin > member)
# and what each role may do. Every authorization decision about managing
# members routes through these predicates so the rule lives in one place.
# 321-stripe reuses can_administer_team to gate billing actions.
#------------------------------------------------------------------------------

use Mojo::Base -strict, -signatures;

use Exporter 'import';
our @EXPORT_OK = qw(
    can_add_member can_remove_member can_administer_team can_assign_role ROLES
);

# Higher rank = more power. 0 means "not a team member".
my %RANK = (member => 1, admin => 2, owner => 3);

# Roles a user may be assigned, weakest first (for building UI selectors).
use constant ROLES => qw(member admin owner);

sub _rank ($role) { $RANK{$role // ''} // 0 }

# can_add_member - any team member can extend access; removal is the gated part.
sub can_add_member ($actor_role) {
    return _rank($actor_role) >= $RANK{member};
}

# can_remove_member - owner removes anyone; admin removes anyone except owners;
#   member removes nobody. (Self-removal is handled by the caller.)
sub can_remove_member ($actor_role, $target_role) {
    return 1 if $actor_role && $actor_role eq 'owner';
    return 1 if $actor_role && $actor_role eq 'admin'
             && ($target_role // '') ne 'owner';
    return 0;
}

# can_administer_team - may $actor manage membership at all (roles + removal)?
sub can_administer_team ($actor_role) {
    return _rank($actor_role) >= $RANK{admin};
}

# can_assign_role - owner may set any role on anyone; admin may move members
#   between member/admin but may neither grant 'owner' nor touch an owner.
sub can_assign_role ($actor_role, $target_role, $new_role) {
    return 0 unless can_administer_team($actor_role);
    return 1 if $actor_role eq 'owner';
    return 0 if ($target_role // '') eq 'owner';   # can't touch owners
    return 0 if ($new_role    // '') eq 'owner';   # can't mint owners
    return 1;
}

1;
