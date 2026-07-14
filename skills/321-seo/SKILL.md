---
name: 321-seo
description: Use when a Perl Mojolicious app needs crawler plumbing - robots.txt, sitemap.xml - or shows the symptoms of missing it (pages absent from Google/Bing, unlisted/private content leaking into a sitemap, crawler endpoints minting session cookies, sitemap URLs pointing at localhost behind a reverse proxy).
---

# SEO plumbing: robots.txt + sitemap.xml for Mojolicious

## Overview

Two artefacts that look like one feature but aren't: **robots.txt** is a
static policy file (never touches the DB), **sitemap.xml** is a live,
dynamic view of your *public* content. Ship them as a static file plus a
small controller.

`templates/` holds the real, tested engine shipped on favsix.com - port
it (rename the package, adapt table/column names); the pattern has no
deps beyond core Mojolicious + Mojo::Pg.

**Read `references/gotchas.md` first** - the traps that matter
(unlisted-content leaks, session-cookie minting on crawler endpoints,
reverse-proxy host trust, Mojo 9 format detection, the XML-escaping
facts) are all there, each with its test pin.

## When to use

- Any public Mojolicious app that should be indexed: marketing pages +
  user-generated public pages.
- Auditing an existing sitemap: is unlisted/private content leaking? Do
  crawler hits mint cookies?

**Not for:** access control (robots.txt is a courtesy to well-behaved
crawlers, never protection - that's auth in controllers); non-Mojolicious
stacks (the SQL and robots.txt port; the route/render/escaping specifics
are Mojo-shaped).

## The pattern

1. **`public/robots.txt`** (static - `templates/robots.txt`).
   Mojolicious serves `public/` files before the router, so no route is
   needed. Disallow the non-content surface: token-bearing paths
   (`/invite/`), iframe-only embeds, `/api/`, auth, billing, health.
   End with a `Sitemap:` line hardcoding the **live** origin (a static
   file can't interpolate; dev serving the live URL is harmless).
2. **Route** - a literal path next to your marketing routes:
   `$r->get('/sitemap.xml')->to('Seo#sitemap');`
   (Mojolicious 9 does not auto-detect formats; the literal path just
   matches. No `[format => ...]` gymnastics.)
3. **Controller** (`templates/Seo.pm`) - build a flat list of
   `{loc, lastmod}` hashes: the static marketing pages first, then every
   **public** row from the model. Render with `format => 'xml'`.
4. **SQL** (`templates/list_public_sitemap.sql.ep`) -
   `WHERE visibility = 'public'`, zero binds, `lastmod` formatted in SQL
   (`to_char(updated_at, 'YYYY-MM-DD')`). Pairs with the 321-sql-template
   layer or a plain query.
5. **XML template** (`templates/sitemap.xml.ep`) - the standard
   `<urlset>`; `<%= %>` already XML-escapes (it IS
   `Mojo::Util::xml_escape`).
6. **Test** (`templates/seo.t`) - four pins, all load-bearing: robots
   content, public-only listing (`content_unlike` on the unlisted AND
   private fixtures), XML content type, and **no `Set-Cookie`** on an
   anonymous sitemap fetch.

## Quick reference

| Decision | Default | When to deviate |
|---|---|---|
| robots.txt static vs dynamic | Static file in `public/` | Per-env policy (staging `Disallow: /`) - swap the file at deploy or via nginx, not app logic |
| Absolute URLs | `$c->url_for($path)->to_abs` | Proxy headers untrusted → hardcode a `public_origin` config value instead (see gotchas) |
| `lastmod` | `YYYY-MM-DD` from SQL | Full W3C datetime if you want it; date is enough for crawlers |
| What's listed | Marketing pages + `visibility = 'public'` rows | Never unlisted ("index me" defeats unlisted), never private |
| Caching | None - the query is one indexed scan | Only at real scale, and prefer `Cache-Control` headers over in-process state |
| Scale cap | Fine to 50,000 URLs | Past that, a sitemap index file listing child sitemaps |

## Verify

Port `templates/seo.t` (fixtures: one public, one unlisted, one private
row). Then mutation-test your pins once: drop the `WHERE` clause - the
unlisted/private `content_unlike` assertions must fail; add a
`$c->session(probe => 1)` to the controller - the no-Set-Cookie pin must
fail. Revert both. A pin that can't fail isn't a pin.

After shipping: submit the sitemap URL in Google Search Console and Bing
Webmaster Tools - crawlers find it via robots.txt eventually, but
submission is same-day.

## Common mistakes

See `references/gotchas.md`. The top three: **unlisted content in the
sitemap** (an explicit index-me signal for URLs whose whole point is
non-discovery); **session cookies on crawler endpoints** (hash
autovivification mints them silently); **trusting `->to_abs` behind a
misconfigured proxy** (every `<loc>` silently becomes
`http://127.0.0.1:PORT/...`).
