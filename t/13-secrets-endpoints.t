use strict;
use warnings;
use Test::More;
use Test::Mojo;
use MIME::Base64;
use Path::Tiny qw(tempdir path);

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
path($home, 'secrets')->mkpath;

my $repo = tempdir(CLEANUP => 1);
path($repo, '.321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/demo.pl
runner: hypnotoad
env_required:
  API_KEY: required
env_optional:
  LOG_LEVEL:
    default: info
YAML

path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
targets:
  live:
    host: demo.do
    port: 9400
YAML

$ENV{MOJO_MODE} = 'production';
$ENV{APP_HOME}  = $home;

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));
my $auth = { Authorization => 'Basic ' . encode_base64('321:kaizen', '') };

# GET secrets: missing key
$t->get_ok('/service/demo.web/secrets', $auth)
  ->status_is(200)
  ->json_is('/status' => 'success')
  ->json_is('/data/missing/0' => 'API_KEY')
  ->json_is('/data/present' => []);

# POST set key
$t->post_ok('/service/demo.web/secrets' => $auth => json => { key => 'API_KEY', value => 'abc' })
  ->status_is(200)
  ->json_is('/status' => 'success');

# GET again: now present
$t->get_ok('/service/demo.web/secrets', $auth)
  ->json_is('/data/missing' => [])
  ->json_is('/data/present/0' => 'API_KEY');

# Reject bad key
$t->post_ok('/service/demo.web/secrets' => $auth => json => { key => 'lowercase', value => 'x' })
  ->status_is(200)
  ->json_is('/status' => 'error')
  ->json_like('/message' => qr/invalid key/);

# DELETE key
$t->post_ok('/service/demo.web/secrets/delete' => $auth => json => { key => 'API_KEY' })
  ->status_is(200)
  ->json_is('/status' => 'success');

# Confirm deleted
$t->get_ok('/service/demo.web/secrets', $auth)
  ->json_is('/data/missing/0' => 'API_KEY');

done_testing;
