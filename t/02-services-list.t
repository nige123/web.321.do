use strict;
use warnings;
use Test::More;
use Test::Mojo;
use MIME::Base64;

$ENV{MOJO_MODE} = 'production';

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));

my $auth = { Authorization => 'Basic ' . encode_base64('321:kaizen', '') };

# Without auth — should get 401
$t->get_ok('/services')
  ->status_is(401);

# With auth — should list services
$t->get_ok('/services', $auth)
  ->status_is(200)
  ->json_is('/status' => 'success')
  ->json_has('/data');

# Service status for known service
$t->get_ok('/service/123.api/status', $auth)
  ->status_is(200)
  ->json_is('/status' => 'success')
  ->json_is('/data/name' => '123.api')
  ->json_has('/data/port')
  ->json_has('/data/running');

# Unknown service
$t->get_ok('/service/nonexistent/status', $auth)
  ->status_is(200)
  ->json_is('/status' => 'error')
  ->json_like('/message' => qr/Unknown service/);

done_testing;
