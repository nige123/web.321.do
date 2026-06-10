use strict;
use warnings;
use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));

# Deploy unknown service - no auth needed, returns error payload
$t->post_ok('/service/nonexistent/deploy')
  ->status_is(200)
  ->json_is('/status' => 'error')
  ->json_like('/message' => qr/Unknown service/);

done_testing;
