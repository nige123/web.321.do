use strict;
use warnings;
use Test::More;
use Deploy::CertProvider;

my $p = Deploy::CertProvider->new;

subtest 'choose provider by target' => sub {
    is $p->pick('live'), 'certbot';
    is $p->pick('dev'),  'mkcert';
};

subtest 'mkcert cert paths' => sub {
    my $paths = $p->cert_paths(provider => 'mkcert', host => 'dev.love.do');
    like $paths->{cert}, qr{/dev\.love\.do\.pem$};
    like $paths->{key},  qr{/dev\.love\.do-key\.pem$};
};

subtest 'certbot cert paths' => sub {
    my $paths = $p->cert_paths(provider => 'certbot', host => 'love.do');
    is $paths->{cert}, '/etc/letsencrypt/live/love.do/fullchain.pem';
    is $paths->{key},  '/etc/letsencrypt/live/love.do/privkey.pem';
};

subtest 'mkcert command' => sub {
    my $cmd = $p->acquire_cmd(provider => 'mkcert', host => 'dev.love.do');
    like $cmd, qr/\bmkcert\b/;
    like $cmd, qr/-cert-file/;
    like $cmd, qr/-key-file/;
    like $cmd, qr/\bdev\.love\.do\b/;
};

subtest 'certbot command' => sub {
    my $cmd = $p->acquire_cmd(provider => 'certbot', host => 'love.do');
    like $cmd, qr/\bcertbot\b/;
    like $cmd, qr/-d love\.do/;
};

done_testing;
