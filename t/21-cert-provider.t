use strict;
use warnings;
use Test::More;
use Deploy::CertProvider;

my $p = Deploy::CertProvider->new;

subtest 'choose provider by target' => sub {
    is $p->pick('live'), 'certbot';
    is $p->pick('dev'),  'mkcert';
};

subtest 'mkcert cert paths (default ssl_dir)' => sub {
    my $paths = $p->cert_paths(provider => 'mkcert', host => 'love.do.dev');
    is $paths->{cert}, '/etc/ssl/321/love.do.dev.pem';
    is $paths->{key},  '/etc/ssl/321/love.do.dev-key.pem';
};

subtest 'mkcert cert paths (custom ssl_dir)' => sub {
    my $pp = Deploy::CertProvider->new(ssl_dir => '/tmp/certs');
    my $paths = $pp->cert_paths(provider => 'mkcert', host => 'foo.do.dev');
    is $paths->{cert}, '/tmp/certs/foo.do.dev.pem';
    is $paths->{key},  '/tmp/certs/foo.do.dev-key.pem';
};

subtest 'certbot cert paths' => sub {
    my $paths = $p->cert_paths(provider => 'certbot', host => 'love.do');
    is $paths->{cert}, '/etc/letsencrypt/live/love.do/fullchain.pem';
    is $paths->{key},  '/etc/letsencrypt/live/love.do/privkey.pem';
};

subtest 'mkcert command' => sub {
    my $cmd = $p->acquire_cmd(provider => 'mkcert', host => 'love.do.dev');
    like $cmd, qr/\bmkcert\b/;
    like $cmd, qr/-cert-file/;
    like $cmd, qr/-key-file/;
    like $cmd, qr/\blove\.do\.dev\b/;
    like $cmd, qr{/etc/ssl/321/love\.do\.dev\.pem};
    like $cmd, qr/\bCAROOT=/,     'preserves CAROOT across sudo';
    like $cmd, qr/\bsudo\b/,      'runs with sudo so nginx can read the cert';
    like $cmd, qr/chgrp www-data/, 'key readable by nginx';
};

subtest 'certbot command' => sub {
    my $cmd = $p->acquire_cmd(provider => 'certbot', host => 'love.do');
    like $cmd, qr/\bcertbot\b/;
    like $cmd, qr/-d love\.do/;
};

done_testing;
