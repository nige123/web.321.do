package F6::Web::Controller::Seo;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Seo.pm
# Description:  Crawler endpoints - the sitemap. robots.txt is static.
#
# Ported from favsix.com (shipped 2026-07-14). To adapt: rename the
# package to your app's namespace, swap the model class/method for
# whatever lists your public rows, and edit @MARKETING_PAGES. Route:
#     $r->get('/sitemap.xml')->to('Seo#sitemap');
# Keep this controller session-free and flash-free - crawlers hammer it
# and a Set-Cookie here churns sessions and breaks caching (see
# references/gotchas.md #2).
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;

use F6::Model::FavArrays;

my @MARKETING_PAGES = qw(
    /
    /creators
    /teams
    /community
    /about
    /pricing
    /bookmarklet
    /home-screen
    /privacy
    /terms
);

sub sitemap ($c) {

    my @urls = map { { loc => $c->url_for($_)->to_abs->to_string } }
               @MARKETING_PAGES;

    my $boards = F6::Model::FavArrays->new(db => $c->db)
                                     ->list_public_for_sitemap;

    push @urls, map {
        {
            loc     => $c->url_for("/\@$_->{handle}/$_->{slug}")
                          ->to_abs->to_string,
            lastmod => $_->{lastmod},
        }
    } @$boards;

    return $c->render(
        template => 'seo/sitemap',
        format   => 'xml',
        urls     => \@urls,
    );
}

1;
