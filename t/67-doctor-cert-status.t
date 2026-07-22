use strict;
use warnings;
use Test::More;
use Deploy::Command::doctor;

# doctor classifies each probed host into ok / warn / fail so it can (a) show a
# meaningful message per failure layer and (b) exit non-zero while there is
# still time - a cert inside the 30-day window is a WARN that must trip the
# exit code, so a cron alerts BEFORE the cert expires (the missing safety net
# in the api.zorda.co incident).

subtest 'valid cert, comfortably outside the window' => sub {
    my ($tier, $msg) = Deploy::Command::doctor::_tier(
        { ok => 1, expiring => 0, days_remaining => 60 });
    is $tier, 'ok', 'ok tier';
    like $msg, qr/60 days/, 'days shown';
};

subtest 'cert inside the 30-day window is a warning' => sub {
    my ($tier, $msg) = Deploy::Command::doctor::_tier(
        { ok => 1, expiring => 1, days_remaining => 12 });
    is $tier, 'warn', 'warn tier';
    like $msg, qr/12 days/, 'names the window';
};

subtest 'expired cert is a failure and says so' => sub {
    my ($tier, $msg) = Deploy::Command::doctor::_tier(
        { ok => 0, expired => 1, reachable => 1, error => 'certificate expired 2 day(s) ago' });
    is $tier, 'fail', 'fail tier';
    like $msg, qr/expired/, 'expired, not "no TLS response"';
};

subtest 'hostname mismatch is a failure naming the mismatch' => sub {
    my ($tier, $msg) = Deploy::Command::doctor::_tier(
        { ok => 0, host_match => 0, reachable => 1, error => 'cert is for other.do, not demo.do' });
    is $tier, 'fail', 'fail tier';
    like $msg, qr/not demo\.do/, 'mismatch message';
};

subtest 'unreachable host is a failure at the TCP/TLS layer' => sub {
    my ($tier, $msg) = Deploy::Command::doctor::_tier(
        { ok => 0, reachable => 0, error => 'no TCP/TLS response (host unreachable on 443)' });
    is $tier, 'fail', 'fail tier';
    like $msg, qr/TCP\/TLS|unreachable/, 'points at the transport layer';
};

subtest 'the exit-worthy set is fail + warn' => sub {
    ok  Deploy::Command::doctor::_needs_attention('fail'),  'fail trips exit';
    ok  Deploy::Command::doctor::_needs_attention('warn'),  'warn trips exit';
    ok !Deploy::Command::doctor::_needs_attention('ok'),    'ok does not';
};

done_testing;
