# Favicon brand-colour extraction - gotchas

The non-obvious things. Read before and during implementation.

## Sourcing the favicon

- **Use DuckDuckGo's icon service, not the site's own /favicon.ico.**
  `https://icons.duckduckgo.com/ip3/<host>.ico`. This is also an **SSRF
  mitigation**: you never make a request to the user-supplied origin - you only
  hit DDG with a hostname - so a malicious URL can't make your server fetch
  internal/localhost/metadata endpoints. (If you fetch the site's own favicon
  directly, you MUST add SSRF guards: block private/loopback IPs, etc.)
- **Subdomains 404.** DDG has no icon for `admin.shopify.com` (404), but does for
  `shopify.com`. Walk up: try the exact host, then parent domains, stopping at
  the registrable domain. **Never query a bare public suffix** (`com`, `co.uk`) -
  keep a small two-level-suffix set (co.uk, com.au, ...) so `shop.foo.co.uk`
  stops at `foo.co.uk`.
- Short timeouts (connect ~2s, request ~3s) - this runs inline on a form blur.
- **Auth-gate the endpoint.** It triggers an outbound fetch on user input.
- **Use TWO providers, DDG then Google S2, for the colour fetch.** DDG gives
  crisp high-res icons but increasingly serves them as **WebP** (whatsapp.com,
  and at times youtube.com / tiktok.com) - and Imager can't decode WebP without
  the optional binding (see below), so the colour silently falls through to a
  palette default. Google's S2 (`https://www.google.com/s2/favicons?domain=<host>&sz=64`)
  **always returns PNG**, so trying it second rescues every WebP-only site.
  Google S2 is just as SSRF-safe (you hit Google, never the user's origin).
  Try DDG first per host, then Google, before walking up to the parent domain.
  Note: this only affects **server-side colour extraction** - the favicon
  *image* you show in the UI can stay on the DDG URL, because the browser
  decodes WebP natively.

## Decoding (Imager)

- **ICO is messy - keep all the fallbacks** (in `_decode_favicon`):
  1. `Imager->read_multi` (ICO has multiple sub-images),
  2. single `Imager->new->read` (DDG sometimes returns a bare PNG),
  3. scan for the PNG signature and decode from there (ICO containers that embed
     a PNG rather than a classic DIB - Imager's ICO reader misses these),
  4. strip the `iCCP` chunk and retry (libpng REJECTS PNGs with the broken
     Photoshop sRGB profile, which a surprising fraction of real favicons carry).
- **Imager needs the format plugins, and the gap is SILENT.** `Imager::File::PNG`
  for PNGs is usually all that's installed - check with
  `perl -MImager -e 'print join ",", sort keys %Imager::formats'` (a default
  install often shows ONLY `png`). Anything Imager can't decode returns undef and
  the caller quietly falls back to a default, so you wonder why some big sites
  have no colour:
  - **WebP** - DDG serves it now (whatsapp.com). Needs `Imager::File::WEBP` +
    system `libwebp-dev` (the `libwebp` *runtime* is usually already present; the
    `-dev` headers to BUILD the binding usually aren't). **The portable fix that
    needs no system packages on any host is the Google S2 PNG fallback above** -
    prefer it over chasing the binding onto every box (incl. the live one).
  - **JPEG** - e.g. Airbnb. Needs `Imager::File::JPEG` + `libjpeg-dev`.
  Decide per format whether you add the binding or lean on the always-PNG
  fallback source. For a 321-deployed app the fallback wins (no apt on live).
- Pick the **largest** frame: sort by `width*height` and take the biggest.

## Sampling pixels

- **RGBA alpha trap (bites in tests).** `$img->getpixel(...)->rgba` on a
  **3-channel** image returns alpha **0**, so an `alpha < 128` skip-transparent
  filter discards EVERY pixel and you get no colour. Real favicons are RGBA, so
  it works in production but fails on hand-built 3-channel test images. **Build
  test images with `channels => 4`** and opaque colours (alpha 255).
- Skip pixels that carry no brand signal: near-grey (chroma `(max-min) < 40`),
  near-white (`max>245 && min>230`), near-black (`max<25`).

## Selecting the colour

- **Dominant by HUE BIN, not raw mean.** Averaging all salient pixels muddies a
  multi-colour logo (Google) into brown. Bin salient pixels by hue (e.g. 24 x
  15deg), take the **most-populated bin's mean** - that's the true dominant
  colour, clean.
- **If you snap to a fixed palette, snap by HUE, not RGB distance.** Shopify's
  logo is a yellow-green (~84deg) that is numerically NEARER a warm "amber" than
  a teal "emerald" in RGB Euclidean space, yet reads as green. Snap by hue
  ranges aligned to colour names (red / orange / green / blue / purple), not
  nearest-RGB. **Better still: skip snapping** and return the actual tuned hex
  (below) - then Shopify is Shopify green, Stripe is Stripe purple, etc.
- **Tune for a usable tone - but know what the clamp does and doesn't do.**
  Convert to HSL and clamp saturation + lightness into a band (e.g. S >= 0.50,
  L in 0.34..0.50), keeping the hue. This gives a **consistent vibrant tone**.
  **It is NOT a white-text contrast guarantee.** HSL lightness is hue-blind
  (luminance is ~70% green), so light hues land low-contrast on white text:
  measured, Shopify green `#92bf40` is only **2.15:1** white-on-colour - below
  even WCAG AA-large (3:1). That can be fine on purpose (FavSix uses bold white
  text on saturated tiles deliberately; its own amber swatch is 2.09:1). But do
  NOT claim the HSL clamp makes text "legible" - it makes it *consistent*.
- **If you need guaranteed white-text legibility, darken on ACTUAL contrast.**
  Keep the hue, drop HSL lightness until white-on-colour clears a real
  relative-luminance contrast target (3.0 = AA-large, 4.5 = AA), with a floor so
  it never reads black. Light hues automatically go darker than blue/red because
  you test true contrast each step:

  ```perl
  sub _white_contrast ($r, $g, $b) {
      my @l = map { my $c = $_/255;
                    $c <= 0.03928 ? $c/12.92 : (($c+0.055)/1.055)**2.4 } ($r,$g,$b);
      my $L = 0.2126*$l[0] + 0.7152*$l[1] + 0.0722*$l[2];
      return 1.05 / ($L + 0.05);
  }
  sub _tune_legible ($rgb) {                       # alternative to _tune_for_tile
      my ($h, $s, $l) = _rgb_to_hsl(@$rgb);
      $s = 0.55 if $s < 0.55; $s = 0.90 if $s > 0.90;
      $l = 0.55 if $l > 0.55;
      my ($r, $g, $b) = _hsl_to_rgb($h, $s, $l);
      while (_white_contrast($r,$g,$b) < 3.0 && $l > 0.20) {   # 3.0 AA-large; 4.5 AA
          $l -= 0.02; ($r, $g, $b) = _hsl_to_rgb($h, $s, $l);
      }
      return sprintf('#%02x%02x%02x', $r, $g, $b);
  }
  ```

- **RECOMMENDED: keep the vibrant clamp, pick the INK per accent luminance.**
  Best of both - the colour stays bold and on-brand, and text stays legible,
  by choosing white-or-dark text per tile rather than darkening the colour.
  `templates/Colour-ink.pm` is the tested helper (`ink_for($hex)` -> 'paper' |
  'ink'): keep light text UNLESS it would fail WCAG AA-large (3:1) on the
  accent, then flip to dark. Needs your UI to support a per-item ink colour
  (a `--tile-ink` CSS var). Mirror the same formula in JS for any live preview
  so preview == saved:

  ```javascript
  function relLum(hex){var m=hex.replace(/^#/,'').match(/.{2}/g);if(!m)return 0;
    var l=m.slice(0,3).map(function(h){var v=parseInt(h,16)/255;
      return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4);});
    return 0.2126*l[0]+0.7152*l[1]+0.0722*l[2];}
  var PAPER_LUM=relLum('f4efe5');           // your light text colour
  function tileInk(hex){var bg=relLum(hex),hi=Math.max(PAPER_LUM,bg),lo=Math.min(PAPER_LUM,bg);
    return (hi+0.05)/(lo+0.05)>=3.0?'var(--paper)':'var(--ink)';}
  ```
- **Fall back to a brand default** when there's no salient colour (grey logo, no
  icon): return undef from the extractor and let the caller assign a default
  (e.g. a sticky palette colour by position, so it never shifts on reorder).

## Storing

- Validate as `^#[0-9a-f]{6}$` (lower-case it). Store the hex verbatim; render as
  an inline CSS custom property / accent.
- Keep it **sticky per item** (store the chosen colour on the row) so it doesn't
  recompute or shift when the item is moved/reordered.

## HSL conversion

Use a standard rgb<->hsl. Avoid Perl's integer `%` on fractional hues - compute
hue with float math and wrap with `+= 360 if < 0`. Round channel outputs and
clamp to 0..255.

## Porting it off the Mojolicious hot path

The module is framed as a Mojo library (`Mojo::Base -strict, -signatures`,
package `<NS>::Util::Favicon`). To use it in a plain script / CLI:

- Replace `use Mojo::Base -strict, -signatures;` with
  `use strict; use warnings; use feature 'signatures'; no warnings 'experimental::signatures';`
  - dropping `Mojo::Base` silently breaks every `sub foo ($x) {...}` signature.
- The favicon timeouts (connect 2s / request 3s) are tuned for a WARM inline
  form-blur. On a COLD first fetch (DNS + TLS to DDG, maybe a redirect) 3s can
  intermittently miss - relax to ~connect 4s / request 6s off the hot path.
