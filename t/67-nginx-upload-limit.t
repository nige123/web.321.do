use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Nginx;

my $home = tempdir(CLEANUP => 1);
my $scan = tempdir(CLEANUP => 1);
my $sites = tempdir(CLEANUP => 1);

sub add_service {
    my ($dir, $yaml) = @_;
    my $repo = path($scan, $dir);
    $repo->mkpath;
    path($repo, '321.yml')->spew_utf8($yaml);
}

add_service('web.limited.do', <<'YAML');
name: limited.web
entry: bin/app.pl
runner: hypnotoad
client_max_body_size: 8m
live:
  host: limited.do
  port: 9400
  client_max_body_size: 17m
YAML

add_service('web.default.do', <<'YAML');
name: default.web
entry: bin/app.pl
runner: hypnotoad
live:
  host: default.do
  port: 9401
YAML

add_service('web.invalid.do', <<'YAML');
name: invalid.web
entry: bin/app.pl
runner: hypnotoad
client_max_body_size: 17mb
live:
  host: invalid.do
  port: 9402
YAML

my $cfg = Deploy::Config->new(app_home => "$home", scan_dir => "$scan", target => 'live');
my $nginx = Deploy::Nginx->new(
    config          => $cfg,
    sites_available => "$sites",
    sites_enabled   => "$sites",
);

subtest 'target upload limit overrides root and renders in proxy server' => sub {
    is $cfg->service('limited.web')->{client_max_body_size}, '17m',
        'target value wins over root value';
    my $result = $nginx->generate('limited.web');
    is $result->{status}, 'ok', 'config generated';
    my $conf = path($sites, 'limited.do')->slurp_utf8;
    like $conf, qr/^    client_max_body_size 17m;$/m,
        '17m upload limit rendered';
};

subtest 'unset upload limit is omitted' => sub {
    my $result = $nginx->generate('default.web');
    is $result->{status}, 'ok', 'config generated';
    my $conf = path($sites, 'default.do')->slurp_utf8;
    unlike $conf, qr/client_max_body_size/, 'directive omitted';
};

subtest 'invalid upload limit is rejected' => sub {
    my $result = $nginx->generate('invalid.web');
    is $result->{status}, 'error', 'generation rejected';
    like $result->{message}, qr/Invalid client_max_body_size: 17mb/,
        'validation error identifies invalid value';
    ok !path($sites, 'invalid.do')->exists, 'invalid config not written';
};

done_testing;
