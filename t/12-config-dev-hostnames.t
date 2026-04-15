use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;

# Two services share dev.shared.do; one has no dev target; one has localhost
path($home, 'services', 'a.web.yml')->spew_utf8(<<'YAML');
name: a.web
repo: /tmp/a
targets:
  dev:
    host: dev.a.do
    port: 9001
YAML

path($home, 'services', 'b.web.yml')->spew_utf8(<<'YAML');
name: b.web
repo: /tmp/b
targets:
  dev:
    host: dev.shared.do
    port: 9002
YAML

path($home, 'services', 'c.web.yml')->spew_utf8(<<'YAML');
name: c.web
repo: /tmp/c
targets:
  dev:
    host: dev.shared.do
    port: 9003
YAML

path($home, 'services', 'd.web.yml')->spew_utf8(<<'YAML');
name: d.web
repo: /tmp/d
targets:
  live:
    host: d.do
    port: 9004
YAML

path($home, 'services', 'e.web.yml')->spew_utf8(<<'YAML');
name: e.web
repo: /tmp/e
targets:
  dev:
    host: localhost
    port: 9005
YAML

my $c = Deploy::Config->new(app_home => $home);
is_deeply $c->dev_hostnames, ['dev.a.do', 'dev.shared.do'],
    'dedupes, skips localhost, skips services without dev target, sorts';

done_testing;
