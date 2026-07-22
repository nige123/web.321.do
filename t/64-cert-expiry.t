use strict;
use warnings;
use Test::More;
use Time::Piece;
use Deploy::Nginx;

# Expiry-aware cert probing. The two pure helpers underneath probe_cert:
#   _days_until - parse an openssl notAfter date into days-from-now
#   _cert_verdict - given host + CN/SANs + days remaining, classify the cert
# (missing/expired/expiring/mismatch/valid) so a renewal decision is possible.

sub openssl_date {
    my ($days_from_now) = @_;
    return gmtime(time + $days_from_now * 86400)->strftime('%b %e %H:%M:%S %Y GMT');
}

subtest '_days_until parses openssl notAfter into days-from-now' => sub {
    my $d = Deploy::Nginx::_days_until(openssl_date(45));
    ok $d >= 44 && $d <= 45, "future date ~45 days (got $d)";

    my $past = Deploy::Nginx::_days_until(openssl_date(-3));
    ok $past < 0, "expired date is negative (got $past)";

    is Deploy::Nginx::_days_until('not a date'), undef, 'garbage -> undef';
    is Deploy::Nginx::_days_until(undef),        undef, 'undef -> undef';
};

subtest '_cert_verdict: valid cert well within window' => sub {
    my $v = Deploy::Nginx::_cert_verdict('demo.do', 'demo.do', [], 60);
    is $v->{ok},       1, 'ok';
    is $v->{expired},  0, 'not expired';
    is $v->{expiring}, 0, 'not expiring';
    ok !$v->{error}, 'no error';
};

subtest '_cert_verdict: expired cert' => sub {
    my $v = Deploy::Nginx::_cert_verdict('demo.do', 'demo.do', [], -2);
    is $v->{ok},      0, 'not ok';
    is $v->{expired}, 1, 'expired';
    like $v->{error}, qr/expired/i, 'error says expired';
};

subtest '_cert_verdict: expiring within the renewal window' => sub {
    my $v = Deploy::Nginx::_cert_verdict('demo.do', 'demo.do', [], 12);
    is $v->{ok},       1, 'still ok (not yet expired)';
    is $v->{expiring}, 1, 'flagged expiring';
    like $v->{error}, qr/12 days|expires/i, 'error names the window';
};

subtest '_cert_verdict: hostname mismatch' => sub {
    my $v = Deploy::Nginx::_cert_verdict('demo.do', 'other.do', ['www.other.do'], 60);
    is $v->{ok},         0, 'not ok';
    is $v->{host_match}, 0, 'no host match';
    like $v->{error}, qr/not demo\.do/, 'error names the mismatch';
};

subtest '_cert_verdict: SAN match counts' => sub {
    my $v = Deploy::Nginx::_cert_verdict('www.demo.do', 'demo.do', ['www.demo.do'], 60);
    is $v->{ok},         1, 'matched via SAN';
    is $v->{host_match}, 1, 'host match';
};

done_testing;
