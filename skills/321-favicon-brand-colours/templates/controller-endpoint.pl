# A tiny JSON endpoint the client calls to source a colour from a favicon.
# Mount in your router (auth-gate it - it triggers an outbound fetch):
#
#   $r->get('/api/brand-colour')->to('Colours#suggest');
#
# <NS> = your namespace; rename the Favicon module to match.

#------------------------------------------------------------------------------
# GET /api/brand-colour?url=...   (auth required)
#   Returns a colour DERIVED from the destination site's favicon, as a
#   '#rrggbb' hex (the site's own hue, tuned to stay legible), or
#   { colour: null } when no favicon colour can be found (a grey logo, no
#   icon). Auth-gated so only signed-in users can trigger the outbound fetch.
#------------------------------------------------------------------------------
sub suggest ($c) {
    return $c->render(json => { colour => undef }, status => 401)
        unless $c->current_user;
    my $url    = $c->param('url') // '';
    my $colour = <NS>::Util::Favicon::dominant_colour($url);   # '#rrggbb' or undef
    return $c->render(json => { colour => $colour });
}

# Storing the result (sketch): validate, keep it sticky, fall back to a brand
# default when there's no favicon colour. In your create/update model:
#
#   my %BRAND = map { $_ => 1 } qw(coral indigo emerald amber plum);
#   if ($BRAND{$colour})                  { }                       # named swatch
#   elsif ($colour =~ /^#[0-9a-fA-F]{6}$/) { $colour = lc $colour } # favicon hex
#   else  { $colour = $palette[$count % @palette] }  # sticky brand default by position
