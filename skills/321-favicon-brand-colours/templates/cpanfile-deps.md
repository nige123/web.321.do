# Dependencies

```perl
requires 'Imager';               # decode favicons + sample pixels
requires 'Imager::File::PNG';    # PNG-shaped favicons (most of them)
# requires 'Imager::File::JPEG'; # JPEG favicons (e.g. Airbnb) - needs system
#                                # libjpeg-dev. Without it, JPEG favicons SILENTLY
#                                # return undef and the caller falls back to a
#                                # default. Add it (and apt install libjpeg-dev on
#                                # every host) only when you need JPEG coverage.
# requires 'Imager::File::WEBP'; # WebP favicons - DDG now serves these for some
#                                # sites (whatsapp.com). Needs system libwebp-dev.
#                                # PREFER the Google S2 PNG fallback in Favicon.pm
#                                # (_favicon_sources) instead: no system package
#                                # on any host (incl. the live box) and it rescues
#                                # every WebP-only site. Add this binding only if
#                                # you specifically want native WebP decode.
requires 'Mojo::UserAgent';      # ships with Mojolicious
# MIME::Base64 (encode/decode_base64url) and Crypt::PRNG are only needed if you
# pair this with other features; the favicon module itself needs Imager + Mojo.
```

ICO support: Imager decodes ICO via its built-in reader, but real-world favicons
are messy - the module's `_decode_favicon` has fallbacks (read_multi, single
read, embedded-PNG-signature scan, iCCP strip). Keep all of them.
