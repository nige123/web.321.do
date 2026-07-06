# Copyright Nige Ltd. Author: Nigel Hamilton.
use strict;
use warnings;

BEGIN {
    $ENV{MOJO_MODE}   ||= 'testing';
    $ENV{MOJO_CONFIG} ||= 't/conf/test.conf';
}

use Test::Most;
use lib 'lib';
use lib 't/lib';
use Test::L2D qw(test_mojo reset_db);

my $t  = test_mojo();
my $db = $t->app->pg->db;

subtest 'every expected table exists' => sub {
    for my $table (qw(users passcodes sessions accounts account_members)) {
        my $exists = $db->query('SELECT to_regclass(?) AS t', "public.$table")
            ->hash->{t};
        ok $exists, "$table created";
    }
};

subtest 'schema is at version 1' => sub {
    # Bump this as feature skills add "-- N up" blocks.
    is $t->app->pg->migrations->active, 1, 'active migration version is 1';
};

subtest 'account_members roles are owner/admin/member' => sub {
    my $u = $db->query(
        "INSERT INTO users (email) VALUES ('r\@example.com') RETURNING user_id")
        ->hash->{user_id};
    my $a = $db->query(
        "INSERT INTO accounts (handle, kind, owner_user_id)
         VALUES ('team1', 'team', ?) RETURNING account_id", $u)->hash->{account_id};
    for my $role (qw(owner admin member)) {
        lives_ok {
            $db->query('INSERT INTO account_members (account_id, user_id, role)
                        VALUES (?, ?, ?) ON CONFLICT (account_id, user_id)
                        DO UPDATE SET role = EXCLUDED.role', $a, $u, $role)
        } "role '$role' accepted";
    }
    dies_ok {
        $db->query('INSERT INTO account_members (account_id, user_id, role)
                    VALUES (?, ?, ?)', $a, $u, 'superuser')
    } "unknown role rejected";
    reset_db($t->app);
};

done_testing;
