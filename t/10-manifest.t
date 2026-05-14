use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Manifest;

my $dir = tempdir(CLEANUP => 1);

subtest 'missing file returns undef' => sub {
    my $m = Deploy::Manifest->load($dir);
    ok !$m, 'returns undef when 321.yml absent';
};

subtest 'minimal manifest' => sub {
    path($dir, '321.yml')->spew_utf8(<<'YAML');
name: foo.web
entry: bin/app.pl
runner: hypnotoad
YAML
    my $m = Deploy::Manifest->load($dir);
    is $m->{name},   'foo.web';
    is $m->{entry},  'bin/app.pl';
    is $m->{runner}, 'hypnotoad';
};

subtest 'full manifest with perl + health' => sub {
    path($dir, '321.yml')->spew_utf8(<<'YAML');
name: love.web
entry: bin/love.pl
runner: hypnotoad
perl: perl-5.42.0
health: /health
YAML
    my $m = Deploy::Manifest->load($dir);
    is $m->{perl},   'perl-5.42.0';
    is $m->{health}, '/health';
};

subtest 'invalid: missing required field' => sub {
    path($dir, '321.yml')->spew_utf8("name: bad\n");
    my $err = eval { Deploy::Manifest->load($dir); 0 } || $@;
    like $err, qr/missing 'entry'/, 'rejects manifest without entry';
};

subtest 'invalid: unknown runner' => sub {
    path($dir, '321.yml')->spew_utf8(<<'YAML');
name: bad
entry: bin/x.pl
runner: supervisord
YAML
    my $err = eval { Deploy::Manifest->load($dir); 0 } || $@;
    like $err, qr/unknown runner/, 'rejects unsupported runner';
};

subtest 'manifest with target blocks' => sub {
    path($dir, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/app.pl
runner: hypnotoad
perl: perl-5.42.0
branch: main

dev:
    host: demo.do.dev
    port: 9400
    runner: morbo

live:
    ssh: ubuntu@example.com
    ssh_key: ~/.ssh/key.pem
    host: demo.do
    port: 9400
    runner: hypnotoad
YAML
    my $m = Deploy::Manifest->load($dir);
    is $m->{branch}, 'main', 'branch parsed';
    is_deeply [sort keys %{ $m->{targets} }], [qw(dev live)], 'both targets present';
    is $m->{targets}{dev}{host},        'demo.do.dev',        'dev host';
    is $m->{targets}{dev}{runner},      'morbo',              'dev runner';
    is $m->{targets}{live}{ssh},        'ubuntu@example.com', 'live ssh';
    is $m->{targets}{live}{ssh_key},    '~/.ssh/key.pem',     'live ssh_key';
    is $m->{targets}{live}{host},       'demo.do',            'live host';
    is $m->{repo}, "$dir", 'repo is set to repo_dir';
};

subtest 'manifest without targets defaults to empty hash' => sub {
    path($dir, '321.yml')->spew_utf8(<<'YAML');
name: bare.web
entry: bin/bare.pl
runner: morbo
YAML
    my $m = Deploy::Manifest->load($dir);
    is_deeply $m->{targets}, {}, 'targets defaults to empty hash';
    is $m->{branch}, 'master', 'branch defaults to master';
};

done_testing;
