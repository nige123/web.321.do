use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Nginx;
use Deploy::CertProvider;

my $home_obj = tempdir(CLEANUP => 1);
my $scan_obj = tempdir(CLEANUP => 1);

my $repo = path($scan_obj, 'web.demo.do');
$repo->mkpath;
path($repo, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/app.pl
runner: hypnotoad
dev:
  host: demo.do.dev
  port: 9400
  aliases:
    - www.demo.do.dev
live:
  host: demo.do
  port: 9400
  aliases:
    - www.demo.do
YAML

subtest 'aliases resolve from the target' => sub {
    my $cfg = Deploy::Config->new(app_home => "$home_obj", scan_dir => "$scan_obj", target => 'live');
    is_deeply $cfg->service('demo.web')->{aliases}, ['www.demo.do'];
};

subtest 'certbot command with aliases expands the canonical lineage' => sub {
    my $p = Deploy::CertProvider->new;
    my $cmd = $p->acquire_cmd(provider => 'certbot', host => 'demo.do', aliases => ['www.demo.do']);
    like $cmd, qr/-d demo\.do -d www\.demo\.do/, 'both domains requested';
    like $cmd, qr/--cert-name demo\.do/,         'lineage pinned to canonical host';
    like $cmd, qr/--expand/,                     'existing cert can grow new SANs';

    my $plain = $p->acquire_cmd(provider => 'certbot', host => 'demo.do');
    unlike $plain, qr/--expand/,    'no expand without aliases';
    unlike $plain, qr/--cert-name/, 'no cert-name without aliases';
};

subtest 'mkcert command covers aliases' => sub {
    my $p = Deploy::CertProvider->new;
    my $cmd = $p->acquire_cmd(provider => 'mkcert', host => 'demo.do.dev', aliases => ['www.demo.do.dev']);
    like $cmd, qr/demo\.do\.dev www\.demo\.do\.dev/, 'alias passed to mkcert';
};

subtest 'rendered config redirects aliases to the canonical host' => sub {
    my $fake_ssl_dir = tempdir(CLEANUP => 1);
    path($fake_ssl_dir, 'demo.do.dev.pem')->spew_utf8('');
    path($fake_ssl_dir, 'demo.do.dev-key.pem')->spew_utf8('');

    my $sites = tempdir(CLEANUP => 1);
    my $cfg = Deploy::Config->new(app_home => "$home_obj", scan_dir => "$scan_obj", target => 'dev');
    my $n = Deploy::Nginx->new(
        config          => $cfg,
        sites_available => "$sites",
        sites_enabled   => "$sites",
        cert_provider   => Deploy::CertProvider->new(ssl_dir => "$fake_ssl_dir"),
    );

    my $r = $n->generate('demo.web');
    is $r->{status}, 'ok';

    my $conf = path($sites, 'demo.do.dev')->slurp_utf8;
    like $conf, qr{server_name demo\.do\.dev www\.demo\.do\.dev;},
        'port 80 answers canonical host and alias';
    like $conf, qr{return 301 https://demo\.do\.dev\$request_uri},
        'redirects go to the literal canonical host';
    like $conf, qr{server_name www\.demo\.do\.dev;\n},
        'dedicated HTTPS server block for the alias';
    like $conf, qr{server_name demo\.do\.dev;\n},
        'canonical HTTPS server block unchanged';
};

done_testing;
