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
    host: demo.do.dev
    port: 9400
  live:
    host: demo.do
    port: 9400
YAML

# Simulate mkcert-provisioned certs in the ssl_dir
my $fake_ssl_dir = tempdir(CLEANUP => 1);
path($fake_ssl_dir, 'demo.do.dev.pem')->spew_utf8('');
path($fake_ssl_dir, 'demo.do.dev-key.pem')->spew_utf8('');

my $sites = tempdir(CLEANUP => 1);
my $cfg = Deploy::Config->new(app_home => $home, target => 'dev');
my $n = Deploy::Nginx->new(
    config          => $cfg,
    sites_available => "$sites",
    sites_enabled   => "$sites",
    cert_provider   => Deploy::CertProvider->new(ssl_dir => "$fake_ssl_dir"),
);

my $r = $n->generate('demo.web');
is $r->{status}, 'ok';
is $r->{ssl},    1, 'detects mkcert cert as SSL';

my $conf = path($sites, 'demo.do.dev')->slurp_utf8;
like $conf, qr{listen 443 ssl},                'ssl block present';
like $conf, qr{ssl_certificate\s+\Q$fake_ssl_dir\E/demo\.do\.dev\.pem};
like $conf, qr{ssl_certificate_key\s+\Q$fake_ssl_dir\E/demo\.do\.dev-key\.pem};
unlike $conf, qr{/etc/letsencrypt}, 'no letsencrypt paths in dev config';

done_testing;
