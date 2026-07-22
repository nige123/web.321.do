use strict;
use warnings;
use Test::More;
use Deploy::Command;

# The shared renewal decision both `321 go` and `321 nginx` use. A cert is
# (re)acquired when it is missing, or - on live - unreachable, expired, for
# the wrong host, or inside the 30-day renewal window. A valid cert well
# outside the window is left alone. This is the fix for the class of bug where
# an expired-but-present cert was treated as "fully configured" and skipped.

my $cmd = Deploy::Command->new;

subtest 'missing cert file always needs acquisition' => sub {
    ok $cmd->_needs_cert('live', { ssl => 0 }, undef), 'live, no file';
    ok $cmd->_needs_cert('dev',  { ssl => 0 }, undef), 'dev, no file';
};

subtest 'dev: a present cert file (mkcert) is enough' => sub {
    ok !$cmd->_needs_cert('dev', { ssl => 1 }, undef), 'dev + file -> no renew';
};

subtest 'live: valid cert outside the window is left alone' => sub {
    my $probe = { ok => 1, expiring => 0, expired => 0, days_remaining => 60 };
    ok !$cmd->_needs_cert('live', { ssl => 1 }, $probe), 'valid + 60 days -> no renew';
};

subtest 'live: expired cert triggers renewal' => sub {
    my $probe = { ok => 0, expired => 1, expiring => 0, days_remaining => -2 };
    ok $cmd->_needs_cert('live', { ssl => 1 }, $probe), 'expired -> renew';
};

subtest 'live: cert inside the 30-day window triggers renewal' => sub {
    my $probe = { ok => 1, expired => 0, expiring => 1, days_remaining => 12 };
    ok $cmd->_needs_cert('live', { ssl => 1 }, $probe), 'expiring -> renew';
};

subtest 'live: wrong-host or unreachable cert triggers renewal' => sub {
    ok $cmd->_needs_cert('live', { ssl => 1 }, { ok => 0, host_match => 0 }),
        'mismatch -> renew';
    ok $cmd->_needs_cert('live', { ssl => 1 }, { ok => 0, reachable => 0 }),
        'unreachable -> renew';
    ok $cmd->_needs_cert('live', { ssl => 1 }, undef),
        'no probe result -> renew (do not assume good)';
};

done_testing;
