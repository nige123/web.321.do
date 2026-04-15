use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Hosts;

my $dir = tempdir(CLEANUP => 1);
my $hosts = path($dir, 'hosts');

subtest 'write block to fresh file' => sub {
    $hosts->spew_utf8("127.0.0.1  localhost\n::1  localhost\n");
    my $h = Deploy::Hosts->new(path => "$hosts");
    $h->write([qw(dev.love.do dev.zorda.do)]);

    my $content = $hosts->slurp_utf8;
    like $content, qr/localhost/, 'existing lines preserved';
    like $content, qr/# BEGIN 321\.do managed\n/, 'begin marker present';
    like $content, qr/127\.0\.0\.1\s+dev\.love\.do/, 'host 1 in block';
    like $content, qr/127\.0\.0\.1\s+dev\.zorda\.do/, 'host 2 in block';
    like $content, qr/# END 321\.do managed\n/, 'end marker present';
};

subtest 'idempotent rewrite' => sub {
    my $h = Deploy::Hosts->new(path => "$hosts");
    $h->write([qw(dev.love.do dev.zorda.do)]);
    my $first = $hosts->slurp_utf8;
    $h->write([qw(dev.love.do dev.zorda.do)]);
    my $second = $hosts->slurp_utf8;
    is $second, $first, 'second write produces identical content';
};

subtest 'replace block on change' => sub {
    my $h = Deploy::Hosts->new(path => "$hosts");
    $h->write([qw(dev.foo.do)]);
    my $content = $hosts->slurp_utf8;
    like   $content, qr/dev\.foo\.do/;
    unlike $content, qr/dev\.love\.do/, 'previous hosts removed';
    unlike $content, qr/dev\.zorda\.do/;
    like   $content, qr/localhost/, 'non-managed lines still preserved';
};

subtest 'empty list clears block' => sub {
    my $h = Deploy::Hosts->new(path => "$hosts");
    $h->write([]);
    my $content = $hosts->slurp_utf8;
    unlike $content, qr/BEGIN 321\.do/, 'markers removed';
    like   $content, qr/localhost/,     'other lines kept';
};

subtest 'read returns current managed hosts' => sub {
    my $h = Deploy::Hosts->new(path => "$hosts");
    $h->write([qw(dev.a.do dev.b.do)]);
    is_deeply [sort @{ $h->read }], [qw(dev.a.do dev.b.do)];
};

subtest 'reject invalid hostname' => sub {
    my $h = Deploy::Hosts->new(path => "$hosts");
    my $err = eval { $h->write(['bad host']); 0 } || $@;
    like $err, qr/invalid hostname/;
};

done_testing;
