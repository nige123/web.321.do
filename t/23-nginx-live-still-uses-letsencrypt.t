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
  live:
    host: demo.do
    port: 9400
YAML

my $sites = tempdir(CLEANUP => 1);
my $cfg = Deploy::Config->new(app_home => $home, target => 'live');
my $n   = Deploy::Nginx->new(
    config          => $cfg,
    sites_available => "$sites",
    sites_enabled   => "$sites",
);

subtest 'live target without SSL cert renders HTTP-only' => sub {
    my $r = $n->generate('demo.web');
    is $r->{status}, 'ok';
    ok !$r->{ssl}, 'no SSL until letsencrypt cert exists';

    my $conf = path($sites, 'demo.do')->slurp_utf8;
    like   $conf, qr/listen 80/,      'HTTP block present';
    unlike $conf, qr/listen 443 ssl/, 'no HTTPS block when cert absent';
    unlike $conf, qr/mkcert/,         'live target never mentions mkcert';
    unlike $conf, qr{\.local/share},  'no mkcert dir path leak';
};

subtest 'live target with fake SSL cert renders letsencrypt paths (no mkcert leak)' => sub {
    # Ask the provider where it expects live certs to live, then drop a fake one there.
    my $fake_le = tempdir(CLEANUP => 1);
    my $provider = Deploy::CertProvider->new;

    # Monkey-patch for test: redirect certbot cert_paths to our tempdir.
    no warnings 'redefine';
    local *Deploy::CertProvider::cert_paths = sub {
        return {
            cert => "$fake_le/fullchain.pem",
            key  => "$fake_le/privkey.pem",
        };
    };
    path($fake_le, 'fullchain.pem')->spew_utf8('');
    path($fake_le, 'privkey.pem')->spew_utf8('');

    my $nn = Deploy::Nginx->new(
        config          => $cfg,
        sites_available => "$sites",
        sites_enabled   => "$sites",
        cert_provider   => $provider,
    );
    my $r = $nn->generate('demo.web');
    is $r->{status}, 'ok',        'generate ok';
    is $r->{ssl},    1,           'ssl detected via provider-chosen path';

    my $conf = path($sites, 'demo.do')->slurp_utf8;
    like   $conf, qr/listen 443 ssl/,                              'HTTPS block rendered';
    like   $conf, qr{ssl_certificate\s+\Q$fake_le\E/fullchain\.pem},
                                                                    'uses provider-supplied cert path';
    unlike $conf, qr/mkcert/,                                      'no mkcert leakage in SSL block';
    unlike $conf, qr{\.local/share},                               'no mkcert dir leakage';
};

done_testing;
