use strict;
use warnings;

BEGIN {
    $ENV{MOJO_MODE}   ||= 'testing';
    $ENV{MOJO_CONFIG} ||= 't/conf/test.conf';
}

use Test::Most;
use lib 'lib';
use lib 't/lib';
use Test::L2D qw(test_mojo);
use L2D::Auth::Passcodes;
use L2D::Model::Users;
use L2D::Model::Accounts;

my $t  = test_mojo();
my $db = $t->app->db;

subtest 'auth pages render' => sub {
    $t->get_ok('/signin')->status_is(200)->element_exists('input[name="email"]');
    $t->get_ok('/signup')->status_is(200)
      ->element_exists('input[name="email"]')
      ->element_exists('input[name="handle"]');
};

subtest 'signup creates user + personal account + owner membership' => sub {
    $t->post_ok('/signup' => form => { email => 'new@example.com', handle => 'newbie' })
      ->status_is(302);
    my $u = L2D::Model::Users->new(db => $db)->by_email('new@example.com');
    ok $u, 'user created';
    my $a = L2D::Model::Accounts->new(db => $db)->get_by_handle('newbie');
    ok $a, 'account created';
    is $a->{kind}, 'personal', 'personal account';
    is $a->{owner_user_id}, $u->{user_id}, 'owned by the new user';
};

subtest 'passcode sign-in mints a session and lands on the account' => sub {
    # A real code (signup already issued one; issue a fresh known one).
    my $code = L2D::Auth::Passcodes->new(db => $db)->issue('new@example.com')->{code};
    $t->post_ok('/signin/code' => form => { code => $code })
      ->status_is(302)->header_like(Location => qr{/\@newbie});
    # The session cookie now authenticates the client.
    $t->get_ok('/')->status_is(302)->header_like(Location => qr{/\@newbie});
};

subtest 'a wrong code is rejected' => sub {
    my $t2 = test_mojo();
    my $db2 = $t2->app->db;
    L2D::Model::Users->new(db => $db2)->find_or_create_by_email('x@example.com');
    $t2->post_ok('/signin' => form => { email => 'x@example.com' })->status_is(302);
    $t2->post_ok('/signin/code' => form => { code => '000000' })
       ->status_is(200)->content_like(qr/wrong or expired/i);
};

subtest 'taken handle is rejected' => sub {
    my ($t3) = test_mojo();
    $t3->post_ok('/signup' => form => { email => 'a@example.com', handle => 'dup' })
       ->status_is(302);
    $t3->post_ok('/signup' => form => { email => 'b@example.com', handle => 'dup' })
       ->status_is(200)->content_like(qr/taken/i);
};

done_testing;
