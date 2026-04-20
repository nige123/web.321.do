use strict;
use warnings;
use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new(Mojo::File->new('bin/321.pl'));

# No auth needed — 200, rendered markdown
$t->get_ok('/docs')
  ->status_is(200)
  ->content_type_like(qr{text/html})
  ->content_like(qr{<h1>.*Operator Guide}s, 'renders top-level heading')
  ->content_like(qr{<code>.*321 install.*</code>}s, 'renders fenced code / inline code')
  ->content_like(qr{<a href="/docs" class="mission-nav">DOCS</a>}, 'DOCS link present in mission bar');

done_testing;
