use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

my $home = tempdir(CLEANUP => 1);
my $scan = tempdir(CLEANUP => 1);

my $repo = path($scan, 'web.demo.do');
$repo->mkpath;
path($repo, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/demo.pl
runner: hypnotoad
perl: perl-5.42.1
health: /health
live:
  host: demo.do
  port: 9400
YAML

my $c = Deploy::Config->new(app_home => $home, scan_dir => "$scan", target => 'live');
my $svc = $c->service('demo.web');

is $svc->{bin},      'bin/demo.pl',    'bin from manifest entry';
is $svc->{runner},   'hypnotoad',      'runner from manifest';
is $svc->{perlbrew}, 'perl-5.42.1',    'perl from manifest';
is $svc->{port},     9400,             'port from manifest live target';
is $svc->{host},     'demo.do',        'host from manifest live target';
is $svc->{health},   '/health',        'health from manifest';

done_testing;
