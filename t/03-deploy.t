use strict;
use warnings;
use Test::More;
use Test::Mojo;
use MIME::Base64;

$ENV{MOJO_MODE} = 'production';

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));

my $auth      = { Authorization => 'Basic ' . encode_base64('321:kaizen', '') };
my $wrong_auth = { Authorization => 'Basic ' . encode_base64('321:wrong', '') };

# Deploy without auth
$t->post_ok('/service/123.api/deploy')
  ->status_is(401);

# Deploy unknown service
$t->post_ok('/service/nonexistent/deploy', $auth)
  ->status_is(200)
  ->json_is('/status' => 'error')
  ->json_like('/message' => qr/Unknown service/);

# Wrong password
$t->post_ok('/service/123.api/deploy', $wrong_auth)
  ->status_is(401);

done_testing;
