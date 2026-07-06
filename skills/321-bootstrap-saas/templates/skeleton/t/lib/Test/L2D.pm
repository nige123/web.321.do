# Copyright Nige Ltd. Author: Nigel Hamilton.
package Test::L2D;

#------------------------------------------------------------------------------
# Test harness: build the app (auto-migrates) and reset the test database so
# each test file starts clean. Feature skills ADD their tables to @TABLES:
#   321-passkeys -> webauthn_credentials
#   321-stripe   -> stripe_events
#------------------------------------------------------------------------------

use Mojo::Base -strict, -signatures;

use Exporter 'import';
use Test::Mojo;
use L2D::Model::Users;
use L2D::Model::Accounts;

our @EXPORT_OK = qw(test_mojo test_mojo_keep_db reset_db make_user_with_account);

my @TABLES = qw(
    account_members accounts passcodes sessions users
);

#------------------------------------------------------------------------------
# test_mojo - build the app and start each test from a clean DB.
#------------------------------------------------------------------------------
sub test_mojo () {
    my $t = Test::Mojo->new('L2D::Web');
    reset_db($t->app);
    return $t;
}

#------------------------------------------------------------------------------
# test_mojo_keep_db - a fresh client (own cookie jar) that does NOT reset the
#   DB. For multi-client tests where one client must see rows another wrote.
#------------------------------------------------------------------------------
sub test_mojo_keep_db () { return Test::Mojo->new('L2D::Web'); }

#------------------------------------------------------------------------------
# reset_db - truncate every table and drain the Minion queue.
#------------------------------------------------------------------------------
sub reset_db ($app) {

    $app->pg->db->query(
        'TRUNCATE ' . join(', ', @TABLES) . ' RESTART IDENTITY CASCADE'
    );

    # Drain jobs left by other test files. `minion` is a helper, not a method,
    # so $app->can('minion') is always false - detect it via the renderer's
    # helper registry instead, or stale jobs leak across runs.
    $app->minion->reset({ all => 1 }) if $app->renderer->get_helper('minion');

    return 1;
}

#------------------------------------------------------------------------------
# make_user_with_account - create a user + personal account for testing.
#------------------------------------------------------------------------------
sub make_user_with_account ($email, $handle) {
    my $t  = test_mojo();
    my $db = $t->app->db;
    my $u  = L2D::Model::Users->new(db => $db)->find_or_create_by_email($email);
    my $r  = L2D::Model::Accounts->new(db => $db)
        ->create_personal({ user_id => $u->{user_id}, handle => $handle });
    return ($t, $db, $u, $r->{account});
}

1;
