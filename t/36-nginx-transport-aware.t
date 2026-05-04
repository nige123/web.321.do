use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Nginx;
use Deploy::CertProvider;

# Fake transport that records run() invocations and replies from a fixture.
{
    package FakeTransport;
    use Mojo::Base -base, -signatures;
    has commands => sub { [] };
    has replies  => sub { {} };
    sub isa ($self, $name) { $name eq 'Deploy::SSH' || $name eq __PACKAGE__ }
    sub run ($self, $cmd, %_o) {
        push @{ $self->commands }, $cmd;
        for my $pat (keys %{ $self->replies }) {
            return $self->replies->{$pat} if $cmd =~ /$pat/;
        }
        return { ok => 0, output => '' };
    }
    sub upload ($self, $local, $remote) { 1 }
}

my $home_obj = tempdir(CLEANUP => 1);
my $scan_obj = tempdir(CLEANUP => 1);
my $repo = path($scan_obj, 'web.demo.do');
$repo->mkpath;
path($repo, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/app.pl
runner: hypnotoad
live:
  host: demo.do
  port: 39400
YAML

my $cfg = Deploy::Config->new(app_home => "$home_obj", scan_dir => "$scan_obj", target => 'live');

subtest 'status uses transport for remote checks (one round trip)' => sub {
    my $tx = FakeTransport->new;
    $tx->replies({
        'sites-available' => { ok => 1, output => "A\nB\nC\n" },
    });
    my $n = Deploy::Nginx->new(config => $cfg, transport => $tx);
    my $s = $n->status('demo.web');
    is $s->{config_exists}, 1, 'config_exists from transport';
    is $s->{enabled},       1, 'enabled from transport';
    is $s->{ssl},           1, 'ssl from transport';
    is scalar(@{ $tx->commands }), 1, 'all checks in a single round trip';
    like $tx->commands->[0], qr/sudo test -f .*letsencrypt/, 'cert check uses sudo';
};

subtest 'acquire_cert uses transport with sudo for existing-cert probe' => sub {
    my $tx = FakeTransport->new;
    $tx->replies({
        '^sudo test -f .*letsencrypt' => { ok => 0, output => '' },
        'certbot certonly'             => { ok => 1, output => 'success' },
    });
    my $n = Deploy::Nginx->new(config => $cfg, transport => $tx);
    my $r = $n->acquire_cert('demo.web');
    is $r->{status}, 'ok', 'cert acquisition via transport succeeded';
    ok grep(/certbot.*--webroot.*-d demo\.do/, @{ $tx->{commands} }), 'used --webroot mode';
};

subtest 'acquire_cert short-circuits when cert already present' => sub {
    my $tx = FakeTransport->new;
    $tx->replies({
        '^sudo test -f .*letsencrypt' => { ok => 1, output => '' },
    });
    my $n = Deploy::Nginx->new(config => $cfg, transport => $tx);
    my $r = $n->acquire_cert('demo.web');
    is $r->{status}, 'ok', 'returns ok when cert already exists';
    is $r->{message}, 'SSL cert already exists', 'short-circuit message';
    ok !grep(/certbot/, @{ $tx->{commands} }), 'did not run certbot';
};

subtest 'probe_cert rejects invalid hosts without shelling out' => sub {
    my $n = Deploy::Nginx->new(config => $cfg);
    my $r = $n->probe_cert('not a host;rm -rf /');
    is $r->{ok}, 0, 'invalid host rejected';
    is $r->{error}, 'invalid host', 'error reported';
};

subtest 'rendered config has acme-challenge location for HTTP-only' => sub {
    my $sites = tempdir(CLEANUP => 1);
    my $n = Deploy::Nginx->new(
        config => $cfg, sites_available => "$sites", sites_enabled => "$sites",
    );
    $n->generate('demo.web');
    my $conf = path($sites, 'demo.do')->slurp_utf8;
    like $conf, qr{location /\.well-known/acme-challenge/}, 'has acme location';
    like $conf, qr{root /var/www/letsencrypt},              'webroot path present';
};

done_testing;
