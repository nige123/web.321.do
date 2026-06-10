use strict;
use warnings;
use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));

# The real service mgr will return "Unknown service" for our bogus name,
# but the route existing (200 with error payload) vs not existing (404)
# is what we're validating here.

for my $path (qw(/service/nonexistent/update /service/nonexistent/migrate /service/nonexistent/restart)) {
    # No auth needed - 200 with JSON error body
    $t->post_ok($path)
      ->status_is(200)
      ->json_is('/status' => 'error')
      ->json_like('/message' => qr/Unknown service/i);
}

done_testing;
