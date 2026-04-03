use strict;
use warnings;
use Test::More;
use Test::Mojo;
use MIME::Base64;

$ENV{MOJO_MODE} = 'production';

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));

my $valid_auth   = { Authorization => 'Basic ' . encode_base64('321:kaizen', '') };
my $wrong_user   = { Authorization => 'Basic ' . encode_base64('admin:kaizen', '') };
my $wrong_pass   = { Authorization => 'Basic ' . encode_base64('321:wrong', '') };
my $empty_auth   = { Authorization => 'Basic ' . encode_base64(':', '') };

# Health is public — no auth needed
$t->get_ok('/health')
  ->status_is(200)
  ->json_is('/status' => 'success');

# No credentials — 401 with WWW-Authenticate header
$t->get_ok('/services')
  ->status_is(401)
  ->header_like('WWW-Authenticate' => qr/Basic realm="321\.do"/);

# Wrong username — 401
$t->get_ok('/services', $wrong_user)
  ->status_is(401);

# Wrong password — 401
$t->get_ok('/services', $wrong_pass)
  ->status_is(401);

# Empty credentials — 401
$t->get_ok('/services', $empty_auth)
  ->status_is(401);

# Valid credentials — 200
$t->get_ok('/services', $valid_auth)
  ->status_is(200)
  ->json_is('/status' => 'success');

# Valid credentials on dashboard
$t->get_ok('/', $valid_auth)
  ->status_is(200);

# Valid credentials on service detail
$t->get_ok('/service/123.api/status', $valid_auth)
  ->status_is(200)
  ->json_is('/status' => 'success');

# Bearer token no longer works
$t->get_ok('/services', { Authorization => 'Bearer test-token-123' })
  ->status_is(401);

done_testing;
