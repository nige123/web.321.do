use strict;
use warnings;
use Test::More;
use Test::Mojo;

# Set a test token
$ENV{DEPLOY_TOKEN} = 'test-token-123';

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));

# Health endpoint is public - no auth needed
$t->get_ok('/health')
  ->status_is(200)
  ->json_is('/status' => 'success')
  ->json_has('/data/uptime')
  ->json_has('/data/services/total')
  ->json_has('/data/services/running');

done_testing;
