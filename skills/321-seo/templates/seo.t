use strict;
use warnings;

# Ported from favsix.com t/73-seo.t. Adapt the boot block and fixture
# model calls to your app; keep all four pins - each catches a real
# failure mode (see references/gotchas.md):
#   1. robots.txt content (Sitemap line + a token-path Disallow)
#   2. sitemap lists public rows ONLY (unlisted AND private excluded)
#   3. XML content type + lastmod shape
#   4. no Set-Cookie on an anonymous sitemap fetch
# Mutation-test pins 2 and 4 once after porting: drop the SQL WHERE
# clause (2 must fail), add $c->session(probe => 1) to the controller
# (4 must fail), then revert. Beware: if create() derives the slug from
# the title, assert on the DERIVED slug, not the title.

BEGIN {
    $ENV{MOJO_MODE}   ||= 'testing';
    $ENV{MOJO_CONFIG} ||= 't/conf/test.conf';
}

use Test::Most;
use lib 'lib';
use lib 't/lib';
use Test::F6 qw(test_mojo);
use F6::Model::Users;
use F6::Model::Accounts;
use F6::Model::FavArrays;

my $t  = test_mojo();
my $db = $t->app->db;
my $u  = F6::Model::Users->new(db => $db)
            ->find_or_create_by_email('seo@example.com');
my $accounts = F6::Model::Accounts->new(db => $db);
my $personal = $accounts->create_personal(
    { user_id => $u->{user_id}, handle => 'seo' })->{account};

my $arrays = F6::Model::FavArrays->new(db => $db);
$arrays->create({ account_id => $personal->{account_id},
                   title      => 'Public Board',
                   visibility => 'public' });
$arrays->create({ account_id => $personal->{account_id},
                   title      => 'Hidden Board',
                   visibility => 'unlisted' });
$arrays->create({ account_id => $personal->{account_id},
                   title      => 'Secret Board',
                   visibility => 'private' });

subtest 'robots.txt' => sub {
    $t->get_ok('/robots.txt')->status_is(200)
      ->content_like(qr{Sitemap: https://favsix\.com/sitemap\.xml})
      ->content_like(qr{Disallow: /invite/});
};

subtest 'sitemap lists marketing pages and public boards only' => sub {
    $t->get_ok('/sitemap.xml')->status_is(200)
      ->header_like('Content-Type' => qr{xml})
      ->content_like(qr{<urlset})
      ->content_like(qr{<loc>[^<]*/pricing</loc>})
      ->content_like(qr{<loc>[^<]*/\@seo/public-board</loc>})
      ->content_unlike(qr{hidden-board})
      ->content_unlike(qr{secret-board})
      ->content_like(qr{<lastmod>\d{4}-\d{2}-\d{2}</lastmod>});
};

subtest 'no session cookie for anonymous sitemap fetch' => sub {
    $t->get_ok('/sitemap.xml')->status_is(200);
    is $t->tx->res->headers->set_cookie, undef, 'no Set-Cookie on sitemap';
};

done_testing;
