use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Path::Tiny qw(path);

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));

# Logs for unknown service - no auth needed
$t->get_ok('/service/nonexistent/logs')
  ->status_is(200)
  ->json_is('/status' => 'error');

# Create a temporary log file for testing
my $test_log = path('/tmp/test-deploy-do-stderr.log');
$test_log->spew_utf8(join("\n",
    '2026-04-03T07:00:00 [info] Server started',
    '2026-04-03T07:01:00 [error] Something went wrong',
    '2026-04-03T07:02:00 [warn] Disk space low',
    '2026-04-03T07:03:00 [info] Request processed 200',
    '2026-04-03T07:04:00 [error] Connection timeout',
) . "\n");

# Search logs - missing query
$t->get_ok('/service/123.api/logs/search')
  ->status_is(200)
  ->json_is('/status' => 'error')
  ->json_like('/message' => qr/Missing query/);

# Analyse for unknown service
$t->get_ok('/service/nonexistent/logs/analyse')
  ->status_is(200)
  ->json_is('/status' => 'error');

# Analyse for known service (may have no log files in test env)
$t->get_ok('/service/123.api/logs/analyse')
  ->status_is(200)
  ->json_has('/data/errors')
  ->json_has('/data/warnings')
  ->json_has('/data/statusCodes');

# Cleanup
$test_log->remove;

done_testing;
