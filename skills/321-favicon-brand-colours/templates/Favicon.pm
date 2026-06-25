package F6::Util::Favicon;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Favicon.pm
# Description:  Derive a favicon image URL from a tile destination, and
#               sample its dominant brand-palette colour for smart defaults.
#------------------------------------------------------------------------------

use Mojo::Base -strict, -signatures;

use Imager;
use Mojo::UserAgent;

#------------------------------------------------------------------------------
# _host_from_url - lower-case host (no port) for an http(s) destination, or
#   undef. Tolerates scheme-less input ('stripe.com') by assuming https,
#   matching what a browser does in its address bar.
#------------------------------------------------------------------------------
sub _host_from_url ($url) {

    return undef unless defined $url && length $url;
    $url = "https://$url" unless $url =~ m{\Ahttps?://}i;
    return undef unless $url =~ m{\Ahttps?://([^/?#\s]+)}i;

    my $host = lc $1;
    $host =~ s/:\d+\z//;
    return length $host ? $host : undef;
}

sub _ddg_url    ($host) { "https://icons.duckduckgo.com/ip3/$host.ico" }
sub _google_url ($host) { "https://www.google.com/s2/favicons?domain=$host&sz=64" }

#------------------------------------------------------------------------------
# _favicon_sources - the icon-provider URLs to try for one host, in order.
#   DuckDuckGo first (crisp, high-res icons), then Google's S2 service as a
#   fallback. Both are third-party proxies, so neither ever fetches the user's
#   own origin (SSRF-safe). The Google fallback earns its keep because DDG now
#   serves a growing number of icons as WebP, which Imager can't decode without
#   the optional Imager::File::WEBP binding (+ system libwebp-dev); Google's S2
#   endpoint always returns PNG, so a WebP-only site (whatsapp.com, and at times
#   youtube.com / tiktok.com) still yields a real brand colour instead of
#   silently falling through to a palette default. See gotchas.md ("the silent
#   format gap").
#------------------------------------------------------------------------------
sub _favicon_sources ($host) {
    return (_ddg_url($host), _google_url($host));
}

#------------------------------------------------------------------------------
# for_destination - favicon URL for an http(s) destination, or undef.
#   Uses the exact host; the colour sampler (below) additionally falls back
#   to the registrable domain when a subdomain has no icon of its own. This is
#   the URL the BROWSER renders directly (it decodes WebP fine), so it stays on
#   DDG - the Google fallback only matters for server-side colour extraction.
#------------------------------------------------------------------------------
sub for_destination ($url) {

    my $host = _host_from_url($url) or return undef;
    return _ddg_url($host);
}

#------------------------------------------------------------------------------
# Two-level public suffixes where the registrable domain is three labels
# (foo.co.uk, not co.uk). We never query a bare public suffix for an icon,
# so subdomain fallback stops at the registrable domain.
#------------------------------------------------------------------------------
my %PUBLIC_SUFFIX_2 = map { $_ => 1 } qw(
    co.uk org.uk ac.uk gov.uk me.uk ltd.uk plc.uk net.uk sch.uk nhs.uk
    com.au net.au org.au gov.au edu.au
    co.nz org.nz govt.nz
    co.jp or.jp ne.jp
    co.za org.za
    co.in net.in org.in firm.in gen.in
    com.br com.mx com.ar com.tr com.cn com.sg com.hk com.tw
);

#------------------------------------------------------------------------------
# _favicon_hosts - the host plus its parent domains to try, most specific
#   first, stopping at the registrable domain. So 'admin.shopify.com' yields
#   ('admin.shopify.com', 'shopify.com') - DuckDuckGo has no icon for the
#   admin subdomain, but does for shopify.com. Never descends to a bare
#   public suffix ('com', 'co.uk').
#------------------------------------------------------------------------------
sub _favicon_hosts ($host) {

    my @labels = split /\./, $host;
    my @hosts;
    while (@labels >= 2) {
        push @hosts, join('.', @labels);
        last if @labels == 2;                       # registrable: stop before bare TLD
        my $rest = join('.', @labels[1 .. $#labels]);
        last if $PUBLIC_SUFFIX_2{$rest};            # stop before foo.co.uk -> co.uk
        shift @labels;
    }
    return @hosts;
}

#------------------------------------------------------------------------------
# dominant_colour - sniff the favicon for a destination URL and return a tile
#   colour DERIVED from it as a '#rrggbb' hex (the site's own hue, tuned into
#   a legible tone for the tile's white text), or undef if no favicon can be
#   fetched, decoded, or has any salient coloured pixels (e.g. a pure-grey
#   logo). Tries the exact host first, then the registrable domain. When this
#   returns undef the caller falls back to a brand default.
#------------------------------------------------------------------------------
sub dominant_colour ($url) {

    my $host = _host_from_url($url) or return undef;

    my $ua = Mojo::UserAgent->new
        ->connect_timeout(2)
        ->request_timeout(3)
        ->max_redirects(3);

    for my $h (_favicon_hosts($host)) {
        my $rgb = _rgb_for_host($ua, $h) or next;
        return _tune_for_tile($rgb);
    }
    return undef;
}

#------------------------------------------------------------------------------
# _rgb_for_host - the dominant salient [r,g,b] for one host, trying each icon
#   provider in turn (DDG, then Google) until one fetches, decodes, and yields
#   a salient colour. undef if none do. A provider that returns an undecodable
#   format (DDG's WebP) or a hueless placeholder just falls through to the next.
#------------------------------------------------------------------------------
sub _rgb_for_host ($ua, $host) {

    for my $src (_favicon_sources($host)) {
        my $tx  = $ua->get($src);
        my $res = $tx->result;
        next unless $res && $res->is_success;

        my $bytes = $res->body;
        next unless length $bytes;

        my $img = _decode_favicon($bytes) or next;
        my $rgb = _image_dominant_rgb($img)  or next;
        return $rgb;
    }
    return undef;
}

#------------------------------------------------------------------------------
# _decode_favicon - decode favicon bytes to the largest Imager frame, or
#   undef. ICO carries multiple sub-images; PNG/JPEG/GIF are single. Try
#   read_multi first (ICO), fall back to a single read for PNG-shaped
#   favicons DDG sometimes returns. ICO containers can also embed a PNG
#   (rather than a classic DIB) which Imager's ICO reader misses - scan for
#   the PNG signature and decode from there. Finally, PNGs rejected for an
#   incorrect sRGB profile (libpng's pet peeve, common in the wild) get
#   their iCCP chunk stripped and retried.
#------------------------------------------------------------------------------
sub _decode_favicon ($bytes) {

    my @frames = eval { Imager->read_multi(data => $bytes) };
    @frames = () if $@;
    unless (@frames) {
        my $img = eval { Imager->new->read(data => $bytes) };
        @frames = ($img) if !$@ && $img;
    }
    unless (@frames) {
        my $sig = pack('C8', 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A);
        my $idx = index($bytes, $sig);
        if ($idx >= 0) {
            my $payload = substr($bytes, $idx);
            my $img = eval { Imager->new->read(data => $payload) };
            unless (!$@ && $img) {
                my $stripped = _strip_png_iccp($payload);
                if ($stripped) {
                    $img = eval { Imager->new->read(data => $stripped) };
                }
            }
            @frames = ($img) if $img;
        }
    }
    unless (@frames) {
        my $stripped = _strip_png_iccp($bytes);
        if ($stripped) {
            my $img = eval { Imager->new->read(data => $stripped) };
            @frames = ($img) if !$@ && $img;
        }
    }
    return undef unless @frames;

    my ($img) = sort { ($b->getwidth * $b->getheight) <=> ($a->getwidth * $a->getheight) } @frames;
    return $img;
}

#------------------------------------------------------------------------------
# _image_dominant_rgb - the favicon's dominant salient colour as [r,g,b], or
#   undef if no pixel has a salient hue (e.g. a pure-grey logo). Salient
#   pixels are binned by hue (24 x 15deg) and the most-populated bin's mean
#   colour is returned. Binning first, then averaging, keeps a multi-colour
#   logo (Google) clean - it returns the single dominant hue's true colour
#   rather than a muddy whole-image average.
#------------------------------------------------------------------------------
sub _image_dominant_rgb ($img) {

    my $w = $img->getwidth;
    my $h = $img->getheight;
    return undef unless $w && $h;

    my (@cnt, @sr, @sg, @sb);
    for my $y (0 .. $h - 1) {
        for my $x (0 .. $w - 1) {
            my $c = $img->getpixel(x => $x, y => $y);
            next unless $c;
            my ($r, $g, $b, $a) = $c->rgba;
            next if defined $a && $a < 128;

            my $max = $r; $max = $g if $g > $max; $max = $b if $b > $max;
            my $min = $r; $min = $g if $g < $min; $min = $b if $b < $min;
            next if ($max - $min) < 40;              # near-grey: no hue
            next if $max > 245 && $min > 230;        # near-white
            next if $max < 25;                       # near-black

            my $bin = int(_hue_deg($r, $g, $b, $max, $min) / 15) % 24;
            $cnt[$bin]++;
            $sr[$bin] += $r; $sg[$bin] += $g; $sb[$bin] += $b;
        }
    }

    my ($best, $best_n) = (-1, 0);
    for my $i (0 .. 23) {
        next unless ($cnt[$i] // 0) > $best_n;
        ($best, $best_n) = ($i, $cnt[$i]);
    }
    return undef if $best < 0;

    return [
        int($sr[$best] / $best_n + 0.5),
        int($sg[$best] / $best_n + 0.5),
        int($sb[$best] / $best_n + 0.5),
    ];
}

#------------------------------------------------------------------------------
# _tune_for_tile - turn a sampled [r,g,b] into a tile hex. Keeps the favicon's
#   hue but clamps saturation and lightness into a band that looks intentional
#   and stays legible under the tile's white (paper) text. So a pale or
#   over-bright favicon colour still yields a readable tile, while a colour
#   already in band passes through essentially unchanged.
#------------------------------------------------------------------------------
sub _tune_for_tile ($rgb) {

    my ($hue, $sat, $lum) = _rgb_to_hsl(@$rgb);

    $sat = 0.50 if $sat < 0.50;          # never washed out
    $sat = 0.85 if $sat > 0.85;
    $lum = 0.34 if $lum < 0.34;          # never so dark it reads black
    $lum = 0.50 if $lum > 0.50;          # never so light white text drops out

    my ($r, $g, $b) = _hsl_to_rgb($hue, $sat, $lum);
    return sprintf('#%02x%02x%02x', $r, $g, $b);
}

#------------------------------------------------------------------------------
# _rgb_to_hsl / _hsl_to_rgb - standard conversions. Hue in [0,360),
#   saturation and lightness in [0,1].
#------------------------------------------------------------------------------
sub _rgb_to_hsl ($r, $g, $b) {

    my ($R, $G, $B) = ($r / 255, $g / 255, $b / 255);
    my $max = $R; $max = $G if $G > $max; $max = $B if $B > $max;
    my $min = $R; $min = $G if $G < $min; $min = $B if $B < $min;

    my $l = ($max + $min) / 2;
    my $d = $max - $min;
    my ($hue, $s) = (0, 0);
    if ($d > 0) {
        $s = $d / (1 - abs(2 * $l - 1));
        if    ($max == $R) { $hue = ($G - $B) / $d }
        elsif ($max == $G) { $hue = ($B - $R) / $d + 2 }
        else               { $hue = ($R - $G) / $d + 4 }
        $hue *= 60;
        $hue += 360 if $hue < 0;
    }
    return ($hue, $s, $l);
}

sub _hsl_to_rgb ($hue, $s, $l) {

    my $c  = (1 - abs(2 * $l - 1)) * $s;
    my $hp = $hue / 60;
    my $x  = $c * (1 - abs(($hp - 2 * int($hp / 2)) - 1));
    my $m  = $l - $c / 2;

    my ($r, $g, $b);
    if    ($hp < 1) { ($r, $g, $b) = ($c, $x, 0) }
    elsif ($hp < 2) { ($r, $g, $b) = ($x, $c, 0) }
    elsif ($hp < 3) { ($r, $g, $b) = (0, $c, $x) }
    elsif ($hp < 4) { ($r, $g, $b) = (0, $x, $c) }
    elsif ($hp < 5) { ($r, $g, $b) = ($x, 0, $c) }
    else            { ($r, $g, $b) = ($c, 0, $x) }

    return (
        _clamp255(($r + $m) * 255),
        _clamp255(($g + $m) * 255),
        _clamp255(($b + $m) * 255),
    );
}

sub _clamp255 ($v) {
    $v = int($v + 0.5);
    return $v < 0 ? 0 : $v > 255 ? 255 : $v;
}

#------------------------------------------------------------------------------
# _hue_deg - HSV hue in degrees [0,360) for an RGB triple. Avoids Perl's
#   integer '%' operator (which would truncate fractional hues).
#------------------------------------------------------------------------------
sub _hue_deg ($r, $g, $b, $max, $min) {

    my $d = $max - $min;
    return 0 if $d <= 0;

    my $hue;
    if    ($max == $r) { $hue = ($g - $b) / $d }         # red max: -1 .. 1
    elsif ($max == $g) { $hue = ($b - $r) / $d + 2 }
    else               { $hue = ($r - $g) / $d + 4 }

    $hue *= 60;
    $hue += 360 if $hue < 0;
    return $hue;
}

#------------------------------------------------------------------------------
# _strip_png_iccp - remove any iCCP chunk from a PNG byte string. libpng
#   rejects PNGs with the well-known broken Photoshop sRGB profile, and a
#   surprising fraction of real-world favicons carry it. Removing the chunk
#   produces a PNG that Imager will happily decode (browsers ignore iCCP
#   when it's wrong, which is why this never bothers anyone reading the
#   image normally). Returns undef if the input isn't a PNG.
#------------------------------------------------------------------------------
sub _strip_png_iccp ($bytes) {
    my $sig = pack('C8', 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A);
    return undef unless length($bytes) >= 8 && substr($bytes, 0, 8) eq $sig;
    my $out = $sig;
    my $pos = 8;
    my $found = 0;
    while ($pos + 12 <= length $bytes) {
        my $len  = unpack 'N', substr($bytes, $pos, 4);
        my $type = substr($bytes, $pos + 4, 4);
        my $size = 4 + 4 + $len + 4;   # length + type + data + crc
        last if $pos + $size > length $bytes;
        if ($type eq 'iCCP') {
            $found = 1;
        }
        else {
            $out .= substr($bytes, $pos, $size);
        }
        $pos += $size;
        last if $type eq 'IEND';
    }
    return $found ? $out : undef;
}

1;
