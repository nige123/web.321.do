# Gotchas - each one observed for real, each with its test pin

## 1. Unlisted content leaking into the sitemap

A sitemap entry is an explicit "please index this URL". `unlisted`
content exists precisely so its URL is only discoverable by being told
it - listing it in a public, crawler-fed file defeats the visibility
model entirely. `private` leaking is worse (the slug alone can be
sensitive).

**Rule:** the sitemap query selects `visibility = 'public'` and nothing
else. No "public-ish", no joins that widen it.

**Pin:** fixtures with one public, one unlisted, one private row;
`content_unlike` on both non-public slugs. **Mutation-test it once:**
delete the `WHERE` clause and run the test - it must fail. If it still
passes, your fixture slugs don't match what the fixture actually
produced (e.g. a `create` that derives slug from title).

## 2. Session cookies minted on crawler endpoints

Perl hash autovivification means even a *read* like

```perl
my $x = $c->session->{prefs}{theme};   # autovivifies prefs => {}
```

dirties the session and mints a `Set-Cookie` on the response. Layout
helpers (`current_user()`, banner/nudge helpers) are the usual carriers.
Crawlers hammer sitemap endpoints; every hit then churns a session row /
cookie and marks the response uncacheable.

**Rules:**
- The sitemap controller touches no session, no flash.
- Non-autovivifying reads elsewhere:
  `my $x = ($c->session->{prefs} // {})->{theme};`
- Keep the XML template layout-free so layout helpers never run
  (see gotcha 3).

**Pin:** `is $t->tx->res->headers->set_cookie, undef` on an anonymous
sitemap fetch, asserted on that fetch's own transaction (re-fetch inside
the subtest; don't reuse a transaction from an earlier assertion).
Mutation-test by adding `$c->session(probe => 1)` to the controller -
the pin must fail.

## 3. Layout bleed: verified non-issue across formats - with one trap

Empirically verified (Mojolicious 9): with an app-wide default layout
(`$app->defaults(layout => 'default')`) and only
`layouts/default.html.ep` on disk, rendering `format => 'xml'` does
**not** wrap - layout lookup is format-matched, `layouts/default.xml.ep`
isn't found, the body renders bare, no error.

The trap: if a `layouts/default.xml.ep` ever exists, every XML render
silently inherits it. Don't create one; keep crawler templates
layout-free. If you must be belt-and-braces, pass `layout => undef` in
the `render` call.

## 4. Mojolicious 9 format detection is off - use the literal path

```perl
$r->get('/sitemap.xml')->to('Seo#sitemap');   # just works
```

Mojo 9 no longer strips `.xml` as an auto-detected format, so the
literal path matches as-is. Do not add `[format => ['xml']]` route
constraints (that syntax expects `/sitemap` + extension handling and
changes matching semantics). Set the response type via
`render(format => 'xml')`, which yields `application/xml`.

## 5. XML escaping: `<%= %>` is already correct

Mojolicious `.ep` `<%= %>` runs `Mojo::Util::xml_escape` (the name is
literal) - `& < > " '` are all escaped, which is valid XML entity
escaping. If your handles/slugs are constrained to `[a-z0-9-]` at
creation this never fires; it's the safety net for the day that
constraint loosens. Never build the XML by string concatenation in the
controller.

## 6. Absolute URLs behind a reverse proxy: two valid strategies

- **`$c->url_for($path)->to_abs`** - derives scheme/host from the
  request, which behind nginx means trusting `X-Forwarded-Proto`/`Host`
  (needs the reverse-proxy flag: `MOJO_REVERSE_PROXY=1` or hypnotoad
  `proxy => 1`). Right choice when the app *already* relies on those
  headers elsewhere (OG tags, share URLs) - then the sitemap can't be
  the only thing that's wrong. One misconfiguration symptom: every
  `<loc>` reads `http://127.0.0.1:PORT/...`.
- **Config `public_origin` + `url_for` for the path only** - zero proxy
  trust; needs a config value per deploy.

Pick ONE per app and match what the app already does. Either way,
robots.txt's `Sitemap:` line hardcodes the live origin - it's a static
file.

## 7. lastmod: format it in SQL, date precision is enough

`to_char(updated_at, 'YYYY-MM-DD')` in the query avoids Perl-side
timezone/strftime bugs and is a valid W3C value. Full datetime
(`YYYY-MM-DD"T"HH24:MI:SS"Z"` with `AT TIME ZONE 'UTC'`) is fine too,
just unnecessary. Omit `<lastmod>` for static marketing pages rather
than faking one; the template's `if` guard handles rows without it.

## 8. Don't cache prematurely; mind the 50k cap

The sitemap query is one indexed scan - serve it fresh. In-process
caching (`my $cached` at module level) leaks across Test::Mojo instances
in one process and staggers staleness per prefork worker; if scale ever
demands caching, use `Cache-Control` headers and let the proxy/CDN do
it. Protocol caps: 50,000 URLs / 50MB per sitemap; past that, serve a
sitemap index (`<sitemapindex>` of child sitemaps) - a follow-up, not a
day-one concern.

## 9. robots.txt: what actually belongs in Disallow

It's a courtesy list for well-behaved crawlers, NOT access control -
auth in controllers is the protection. Disallow the surface that's
non-content or dangerous-if-indexed:

- **Token-bearing paths** (`/invite/`) - if a token URL leaks into a
  crawlable page, you don't want it indexed and preserved.
- **Iframe-only embeds** (`/embed/`) - avoids duplicate-content indexing
  of pages meant to render inside another site.
- `/api/`, auth endpoints, `/billing/`, `/health`, bookmarklet targets.

Wildcards (`Disallow: /*/settings`) work on Google/Bing only - fine as
courtesy, don't rely on them. Static file in `public/` is served before
the router, so nothing can shadow it; per-environment policy (staging
`Disallow: /`) is a deploy/nginx concern, not app logic.

## 10. After shipping

Submit the sitemap URL in Google Search Console + Bing Webmaster Tools
(same-day pickup vs eventually-via-robots.txt), and spot-check live by
content: the `Sitemap:` line, a public `<loc>`, and the absence of a
known unlisted slug.
