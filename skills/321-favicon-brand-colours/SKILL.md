---
name: 321-favicon-brand-colours
description: Use when deriving a brand or accent colour from a website's favicon in a Perl Mojolicious app - sourcing the favicon for a destination URL, extracting and tuning its dominant colour, and storing it - or when working with Imager favicon decoding (ICO/PNG), dominant-colour extraction, hue-based colour selection, or auto-colouring UI (tiles/cards/buttons) from a URL.
---

# Branding colours from client favicons

## Overview

Turn a destination URL into a tasteful brand/accent colour by reading its
favicon: **source** the icon, **extract** its dominant colour, **tune** it into a
legible UI tone, **store** it as a `#rrggbb` hex (or fall back to a brand
default), and **apply** it as an accent. So a Shopify link tiles in Shopify
green, Stripe in Stripe purple, YouTube in red - automatically.

Built for Perl Mojolicious (Imager + Mojo::UserAgent). `templates/Favicon.pm` is
the real, tested engine - port it (rename the package); the helpers have no
framework deps.

**Read `references/gotchas.md` first** - the failures that cost hours
(RGBA-alpha-in-tests, hue-vs-RGB snapping, ICO decode fallbacks, the silent JPEG
gap, multi-colour means, legibility tuning, DDG subdomain 404s) are all there.

## When to use

- Auto-colouring UI (tiles, cards, buttons, link-in-bio entries) from a URL.
- Any Perl favicon/colour work: Imager ICO/PNG decoding, dominant-colour
  extraction, hue-based selection, RGB<->HSL tuning.

**Not for:** colour from a full screenshot/page (this is favicon-only); precise
brand-guideline colours (favicons approximate); non-Mojolicious stacks (the
Imager/HSL logic ports, the endpoint/JS are Mojo-shaped).

## The pipeline (`templates/Favicon.pm`)

1. **Source** - `for_destination($url)` -> a DuckDuckGo icon URL
   (`icons.duckduckgo.com/ip3/<host>.ico`). `dominant_colour` tries the exact
   host, then parent domains down to the registrable domain (subdomains 404 on
   DDG), never a bare public suffix. For the colour fetch it tries **two
   providers per host** - DDG, then Google S2 (`_favicon_sources`) - because DDG
   now serves some icons as WebP that Imager can't decode; Google S2 always
   returns PNG so WebP-only sites (whatsapp.com) still resolve. Both proxies are
   SSRF-safe (you never fetch the user's origin). See `gotchas.md`.
2. **Decode** - `_decode_favicon` with the full fallback chain (read_multi ->
   single read -> embedded-PNG scan -> iCCP strip). Take the largest frame.
3. **Extract** - `_image_dominant_rgb`: bin salient pixels by hue, return the
   dominant bin's mean (binning beats a muddy whole-image average on multi-colour
   logos). Skip near-grey/white/black.
4. **Tune** - `_tune_for_tile`: keep the hue, clamp HSL saturation + lightness
   into a consistent vibrant band. Returns `#rrggbb`. **Caveat:** this is a
   hue-blind *tone* clamp, NOT a contrast guarantee - light hues (green/yellow)
   land ~2:1 on white text (Shopify green `#92bf40` = 2.15:1). Fine for bold
   white text on saturated tiles by design; if you need guaranteed WCAG
   white-text contrast, the recommended fix keeps the vibrant colour and picks
   the TEXT colour per accent luminance (`templates/Colour-ink.pm`'s `ink_for`:
   light text unless it fails WCAG AA-large, then dark) - see `gotchas.md`.
5. **Result** - `dominant_colour($url)` returns the hex, or `undef` when there's
   no salient colour - the caller then assigns a brand default.

## Wire it into Mojolicious

- **Deps** (`templates/cpanfile-deps.md`): `Imager`, `Imager::File::PNG`,
  `Mojo::UserAgent`. JPEG favicons need `Imager::File::JPEG` + system
  `libjpeg-dev` or they silently yield undef.
- **Endpoint** (`templates/controller-endpoint.pl`): a small auth-gated
  `GET /api/brand-colour?url=` returning `{ colour: "#rrggbb" | null }`.
- **Client** (`templates/client.js`): on the destination field's `blur`, fetch
  the colour and apply it to the preview/swatch - unless the user already picked
  one. A `#` value is a favicon colour; `null` means let the default stand.
- **Non-JS create paths derive server-side (bookmarklet / API / plain forms).**
  The client fetch only fires on a `blur` in the rich editor. ANY other path
  that creates a coloured row - a "save this page" bookmarklet, an API endpoint,
  a server-rendered form with no JS - has no blur, so it MUST call
  `dominant_colour($url)` itself at create time and store the result. Skip this
  and every row saved that way silently lands on the palette default (the bug
  that shipped: a bookmarklet-saved page with a green favicon stored as the
  default amber). Do the fetch in the **controller**, never the model - a model
  that reaches the network would try to fetch favicons during unit tests. On
  undef, the model's default still applies, so the only change is "derive first,
  default second".
- **Store**: validate `^#[0-9a-f]{6}$`, keep it sticky on the row, and when the
  extractor returns undef assign a brand default (e.g. a palette colour by
  position so it never shifts on reorder).

## Decisions baked into the templates

- **Return the actual tuned hex**, not a snap to a fixed palette - bespoke
  per-site colour (Shopify green, not "nearest of 5"). (If you DO want a fixed
  palette, snap by hue, never RGB distance - see gotchas.)
- **Tone-tuned** to a vibrant band (S >= 0.50, L 0.34..0.50) - for a brand that
  puts bold white text on saturated colour. This is NOT a WCAG contrast
  guarantee for light hues; swap in the contrast-aware variant (`gotchas.md`) if
  you need it.
- **DDG-sourced** (SSRF-safe) with registrable-domain fallback.
- **Graceful undef -> brand default** when no salient colour.

## Verify

`templates/favicon-colour.t` is the headless test (no network): host-fallback
list, RGB<->HSL round-trips, the tuning bands, hue selection on real brand
colours, and an end-to-end dominant-colour on a synthetic image. **Use
`channels => 4` test images** (the RGBA-alpha trap). For a live sanity check,
call `dominant_colour` against a few real URLs and eyeball the hexes.

## Common mistakes

See `references/gotchas.md`. The top three: the **RGBA-alpha trap** in tests
(3-channel images skip every pixel); **hue-bin** the dominant colour (don't mean
the whole image); and if you snap to a palette, snap by **hue, not RGB
distance**.
