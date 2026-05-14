use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

my $base = tempdir(CLEANUP => 1);

my $repo_a = path($base, 'web.alpha.do');
$repo_a->mkpath;
path($repo_a, '321.yml')->spew_utf8(<<'YAML');
name: alpha.web
entry: bin/app.pl
runner: hypnotoad
perl: perl-5.42.0
dev:
    host: alpha.do.dev
    port: 9100
    runner: morbo
live:
    ssh: ubuntu@example.com
    ssh_key: ~/.ssh/key.pem
    host: alpha.do
    port: 9100
    runner: hypnotoad
YAML

my $repo_b = path($base, 'api.beta.do');
$repo_b->mkpath;
path($repo_b, '321.yml')->spew_utf8(<<'YAML');
name: beta.api
entry: bin/api.pl
runner: hypnotoad
dev:
    host: beta.do.dev
    port: 9200
    runner: morbo
YAML

path($base, 'no-manifest')->mkpath;

my $home = tempdir(CLEANUP => 1);

my $c = Deploy::Config->new(app_home => $home, scan_dir => "$base", target => 'dev');

subtest 'discovers services from repo scan' => sub {
    my @names = sort @{ $c->service_names };
    is_deeply \@names, [qw(alpha.web beta.api)], 'found both services';
};

subtest 'resolves dev target' => sub {
    my $svc = $c->service('alpha.web');
    is $svc->{name}, 'alpha.web';
    is $svc->{host}, 'alpha.do.dev';
    is $svc->{port}, 9100;
    is $svc->{runner}, 'morbo';
    is $svc->{bin}, 'bin/app.pl';
    is $svc->{perlbrew}, 'perl-5.42.0';
    is $svc->{repo}, "$repo_a";
};

subtest 'resolves live target with ssh' => sub {
    $c->target('live');
    my $svc = $c->service('alpha.web');
    is $svc->{host}, 'alpha.do';
    is $svc->{runner}, 'hypnotoad';
    is $svc->{ssh}, 'ubuntu@example.com';
    is $svc->{ssh_key}, '~/.ssh/key.pem';
    $c->target('dev');
};

subtest 'conventional log paths' => sub {
    my $svc = $c->service('alpha.web');
    is $svc->{logs}{stdout}, '/tmp/alpha.web.stdout.log';
    is $svc->{logs}{stderr}, '/tmp/alpha.web.stderr.log';
    is $svc->{logs}{ubic},   '/tmp/alpha.web.ubic.log';
};

subtest 'service without live target falls back' => sub {
    $c->target('live');
    my $svc = $c->service('beta.api');
    is $svc->{runner}, 'hypnotoad', 'default runner';
    is $svc->{host}, 'localhost', 'default host';
    $c->target('dev');
};

subtest 'dev_hostnames' => sub {
    my @hosts = sort @{ $c->dev_hostnames };
    is_deeply \@hosts, [qw(alpha.do.dev beta.do.dev)];
};

done_testing;
