use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
path($home, 'secrets')->mkpath;

my $repo = tempdir(CLEANUP => 1);
path($repo, '.321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/demo.pl
runner: hypnotoad
perl: perl-5.42.1
health: /health
env_required:
  API_KEY: "upstream API"
env_optional:
  LOG_LEVEL:
    default: info
YAML

path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
branch: master
targets:
  live:
    host: demo.do
    port: 9400
YAML

my $c = Deploy::Config->new(app_home => $home, target => 'live');
my $svc = $c->service('demo.web');

is $svc->{bin},      'bin/demo.pl',    'bin from manifest entry';
is $svc->{runner},   'hypnotoad',      'runner from manifest';
is $svc->{perlbrew}, 'perl-5.42.1',    'perl from manifest';
is $svc->{port},     9400,             'port from deploy yaml';
is $svc->{host},     'demo.do',        'host from deploy yaml';
is $svc->{health},   '/health',        'health from manifest';
is_deeply $svc->{env_required}, { API_KEY => 'upstream API' };
is $svc->{env_optional}{LOG_LEVEL}{default}, 'info';

# Deploy YAML override wins
path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
bin: bin/override.pl
targets:
  live:
    host: demo.do
    port: 9400
YAML
$c->reload;
is $c->service('demo.web')->{bin}, 'bin/override.pl', 'deploy yaml overrides manifest';

done_testing;
