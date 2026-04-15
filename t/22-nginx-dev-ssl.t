use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Nginx;
use Deploy::CertProvider;

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
my $repo = tempdir(CLEANUP => 1);

path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
targets:
  dev:
    host: dev.demo.do
    port: 9400
  live:
    host: demo.do
    port: 9400
YAML

my $fake_mkcert_dir = tempdir(CLEANUP => 1);
path($fake_mkcert_dir, 'dev.demo.do.pem')->spew_utf8('');
path($fake_mkcert_dir, 'dev.demo.do-key.pem')->spew_utf8('');

my $sites = tempdir(CLEANUP => 1);
my $cfg = Deploy::Config->new(app_home => $home, target => 'dev');
my $n = Deploy::Nginx->new(
    config          => $cfg,
    sites_available => "$sites",
    sites_enabled   => "$sites",
    cert_provider   => Deploy::CertProvider->new(mkcert_dir => "$fake_mkcert_dir"),
);

my $r = $n->generate('demo.web');
is $r->{status}, 'ok';
is $r->{ssl},    1, 'detects mkcert cert as SSL';

my $conf = path($sites, 'dev.demo.do')->slurp_utf8;
like $conf, qr{listen 443 ssl},                'ssl block present';
like $conf, qr{ssl_certificate\s+\Q$fake_mkcert_dir\E/dev\.demo\.do\.pem};
like $conf, qr{ssl_certificate_key\s+\Q$fake_mkcert_dir\E/dev\.demo\.do-key\.pem};
unlike $conf, qr{/etc/letsencrypt}, 'no letsencrypt paths in dev config';

done_testing;
