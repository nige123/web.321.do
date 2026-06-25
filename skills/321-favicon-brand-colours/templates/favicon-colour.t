use Mojo::Base -strict, -signatures;

use Test::Most;
use Imager;
use F6::Util::Favicon;

# HSL of a '#rrggbb' tile hex, for asserting hue/lightness/saturation bands.
sub hsl_of ($hex) {
    my ($r, $g, $b) = map { hex } ($hex =~ /\A#(..)(..)(..)\z/);
    return F6::Util::Favicon::_rgb_to_hsl($r, $g, $b);
}

#------------------------------------------------------------------------------
# Subdomain fallback - try the exact host, then the registrable domain, so a
# site whose subdomain has no icon (admin.shopify.com) still finds one.
#------------------------------------------------------------------------------
is_deeply [ F6::Util::Favicon::_favicon_hosts('admin.shopify.com') ],
          [ qw(admin.shopify.com shopify.com) ],
          'subdomain falls back to the registrable domain';

is_deeply [ F6::Util::Favicon::_favicon_hosts('www.shopify.com') ],
          [ qw(www.shopify.com shopify.com) ],
          'www is stripped to the registrable domain';

is_deeply [ F6::Util::Favicon::_favicon_hosts('shopify.com') ],
          [ qw(shopify.com) ],
          'a registrable domain is left as-is';

is_deeply [ F6::Util::Favicon::_favicon_hosts('shop.honeywillow.co.uk') ],
          [ qw(shop.honeywillow.co.uk honeywillow.co.uk) ],
          'stops at the registrable domain, never queries the co.uk suffix';

#------------------------------------------------------------------------------
# Provider fallback - try DuckDuckGo first, then Google's S2 service. DDG now
# serves some icons as WebP (whatsapp.com), which Imager can't decode; Google's
# endpoint always returns PNG, so the colour still resolves instead of falling
# through to a palette default.
#------------------------------------------------------------------------------
{
    my @src = F6::Util::Favicon::_favicon_sources('whatsapp.com');
    is scalar(@src), 2, 'two icon providers are tried per host';
    like $src[0], qr{\Ahttps://icons\.duckduckgo\.com/ip3/whatsapp\.com\.ico\z},
        'DuckDuckGo is tried first (crisp, high-res)';
    like $src[1], qr{\Ahttps://www\.google\.com/s2/favicons\?domain=whatsapp\.com&sz=\d+\z},
        'Google S2 (always-PNG) is the fallback for WebP-only icons';
}

#------------------------------------------------------------------------------
# RGB <-> HSL round-trips within rounding tolerance.
#------------------------------------------------------------------------------
for my $rgb ([0x95,0xBF,0x47], [0xE5,0x5B,0x47], [0x52,0x46,0xE0], [18,140,102]) {
    my ($h, $s, $l) = F6::Util::Favicon::_rgb_to_hsl(@$rgb);
    my @back = F6::Util::Favicon::_hsl_to_rgb($h, $s, $l);
    my $ok = 1;
    $ok &&= abs($back[$_] - $rgb->[$_]) <= 2 for 0 .. 2;
    ok $ok, "rgb->hsl->rgb round-trips for (@$rgb) -> (@back)";
}

#------------------------------------------------------------------------------
# _tune_for_tile - keeps the favicon's hue but lands the colour in a legible
# band (lightness 0.34..0.50, saturation >= 0.50) so the tile's white text
# stays readable.
#------------------------------------------------------------------------------
{
    # Shopify yellow-green: in-band lightness, just needs a touch more chroma.
    my $hex = F6::Util::Favicon::_tune_for_tile([132, 175, 68]);
    like $hex, qr/\A#[0-9a-f]{6}\z/, 'tune returns a hex';
    my ($h, $s, $l) = hsl_of($hex);
    cmp_ok $h, '>=', 70,   'shopify hue stays in the green family (lower)';
    cmp_ok $h, '<=', 175,  'shopify hue stays in the green family (upper)';
    cmp_ok $l, '<=', 0.51, 'shopify tile is dark enough for white text';
    cmp_ok $s, '>=', 0.49, 'shopify tile is saturated enough to look intentional';
}
{
    # Pale pastel green: too light + too washed out -> pulled into band.
    my ($h, $s, $l) = hsl_of(F6::Util::Favicon::_tune_for_tile([200, 235, 200]));
    cmp_ok $l, '<=', 0.51, 'a pale colour is darkened into the legible band';
    cmp_ok $s, '>=', 0.49, 'a washed-out colour is saturated up';
    cmp_ok $h, '>=', 70,   'hue is still green after taming';
    cmp_ok $h, '<=', 175,  'hue is still green after taming';
}
{
    # Near-black navy: too dark -> lifted into band, hue preserved.
    my ($h, $s, $l) = hsl_of(F6::Util::Favicon::_tune_for_tile([8, 16, 60]));
    cmp_ok $l, '>=', 0.33, 'a near-black colour is lifted into the legible band';
    cmp_ok $h, '>=', 200,  'blue hue preserved (lower)';
    cmp_ok $h, '<=', 260,  'blue hue preserved (upper)';
}

#------------------------------------------------------------------------------
# _image_dominant_rgb - dominant salient hue's mean colour; grey casts no vote.
#------------------------------------------------------------------------------
{
    my $img = Imager->new(xsize => 10, ysize => 10, channels => 4);     # RGBA, like a real favicon
    $img->box(filled => 1, color => Imager::Color->new(120, 120, 120, 255));            # grey border
    $img->box(filled => 1, xmin => 2, ymin => 2, xmax => 7, ymax => 7,
              color => Imager::Color->new(0x95, 0xBF, 0x47, 255));                       # Shopify green
    my $rgb = F6::Util::Favicon::_image_dominant_rgb($img);
    ok $rgb, 'a green favicon yields a dominant rgb';
    my $ok = 1; $ok &&= abs($rgb->[$_] - (0x95,0xBF,0x47)[$_]) <= 2 for 0 .. 2;
    ok $ok, 'dominant rgb is the green field, not muddied by the grey border';

    # End to end: dominant rgb -> tuned tile hex is a legible green.
    my ($h, $s, $l) = hsl_of(F6::Util::Favicon::_tune_for_tile($rgb));
    cmp_ok $h, '>=', 70,   'green favicon -> green tile (lower)';
    cmp_ok $h, '<=', 175,  'green favicon -> green tile (upper)';
    cmp_ok $l, '<=', 0.51, 'green tile is legible under white text';
}
{
    # A purely grey logo has no salient hue -> undef -> caller's brand default.
    my $grey = Imager->new(xsize => 8, ysize => 8, channels => 4);
    $grey->box(filled => 1, color => Imager::Color->new(140, 140, 140, 255));
    is F6::Util::Favicon::_image_dominant_rgb($grey), undef,
        'a grey favicon has no dominant colour (falls back to a brand default)';
}

done_testing;
