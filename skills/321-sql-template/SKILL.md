---
name: 321-sql-template
description: Use when a Perl Mojolicious + Mojo::Pg app should keep SQL out of Perl - each query in its own file, called by name like $db->query('group/name', {binds}). Covers the runtime SQL-template layer, [bind] placeholder extraction, Mojo::Template for dynamic SQL, injection-safe parameter binding, and the .sql.ep file convention.
---

# SQL in template files, called by name

## Overview

Keep SQL out of your Perl. Each query lives in its own file
`sql/<group>/<name>.sql.ep`; code runs it by name with a hash of binds:

```perl
$db->query('tile_clicks/recent', { array_id => $id, limit => 5 });
```

A **two-layer** engine does the work: **Mojo::Template** renders the file first
(so authors get `<% ... %>` for optional clauses and windowed ranges), then a
**`[bind]` pass** rewrites each `[name]` to a `?` and collects the values in
order - so the driver parameterizes them and injection is impossible. The whole
point of a named-placeholder pass (over hand-writing `?`) is that **a bind may
repeat**: each `[array_id]` occurrence emits its own `?` in the right position.

Built for Mojolicious 9.x + Mojo::Pg. `templates/DB.pm` (resolver) and
`templates/DB-SQL.pm` (renderer) are the real, tested engine - port them and
rename the package.

**Read `references/gotchas.md` first** - the failures that cost hours (the `@`
trap under `vars => 1`, bind-vs-interpolate as the entire injection story,
`[name]` rewritten inside string literals, `IN (...)` lists not expanding,
`undef` becoming `NULL`, template caching needing a restart) are all there.

## When to use

- A Mojolicious/Mojo::Pg app where you want SQL in versioned `.sql.ep` files,
  not heredocs or an ORM, called by a short `group/name` key.
- You need light dynamic SQL (optional `WHERE`, a date window, a toggled join)
  without hand-building strings and losing parameterization.
- Any work on the `$db->query('group/name', {...})` layer: adding a query,
  debugging a bind, or understanding why a `[name]` didn't bind.

**Not for:** heavy dynamic query building (use SQL::Abstract / an ORM);
non-Mojolicious stacks (the two-layer idea ports, the Mojo::Template specifics
don't); parameterizing identifiers (table/column/`ASC` - those can't be binds,
see gotchas).

## The engine

1. **Resolve** (`templates/DB.pm`, `query($name, \%binds)`): validate `$name`
   against `\A[a-z0-9_]+/[a-z0-9_]+\z` (one slash, word chars only - this is
   the path-traversal guard **and** enforces the flat `group/name` layout),
   slurp `sql/<group>/<name>.sql.ep`, cache it in-process, hand off to the
   renderer, run the result on the request's `Mojo::Pg::Database`.
2. **Render layer 1 - dynamic** (`templates/DB-SQL.pm`): run the file through
   `Mojo::Template` with `vars => 1` (bind keys become lexicals, so a template
   can say `<% if (defined $tile_id) { %>`) and `auto_escape => 0` (you're
   emitting SQL, not HTML).
3. **Render layer 2 - binds:** regex-rewrite each `[name]` to `?`, `push`ing
   `$record->{name}` onto an ordered bind list. Each occurrence pushes its own
   value, so repeats bind correctly. A `[name]` with no matching key **dies**;
   a passed key never referenced only **warns** (likely a typo).
4. **Return** `($sql, \@bind)`; the resolver calls `$db->query($sql, @bind)`.

## Wire it into Mojolicious

- **Deps** (`templates/cpanfile-deps.md`): `Mojolicious` (ships Mojo::Template +
  Mojo::File), `Mojo::Pg`. No extra CPAN for the engine itself.
- **Construct per request:** give `DB.pm` the request's `Mojo::Pg::Database` and
  your `sql/` path - a helper (`$c->db`) that returns
  `F6::DB->new(db => $c->pg->db, sql_dir => app->home->child('sql'))`.
- **Author queries** in `sql/<group>/<name>.sql.ep`. Values go through `[bind]`,
  never `<%= %>`. See `templates/example-query.sql.ep` for repeated binds, an
  optional clause, and a windowed range done right.
- **Read results** with the usual Mojo::Pg result API: `->hash`,
  `->hashes->to_array`, `->expand->hash`. See `templates/usage.pl`.

## Decisions baked into the engine

- **Two layers, not one.** Mojo::Template handles structure/logic; the `[bind]`
  pass handles values. Keeping them separate is what makes "dynamic SQL" and
  "always parameterized" coexist.
- **Named `[bind]`, not positional `?`.** Authors never count placeholders, and
  a bind can repeat freely - the reason for the named pass.
- **Missing dies, unused warns.** A wrong `[name]` is a hard error you want
  immediately; a leftover bind key is a soft nudge.
- **Templates cached forever in-process.** Fast in prod; means **edits need a
  service restart** in dev (via 321) - a deliberate trade, flagged in gotchas.
- **Name is validated, not trusted.** The regex blocks `../` and deep nesting,
  so a `group/name` from a variable can't escape `sql/`.

## Verify

`templates/sql-template.t` is a headless test of the renderer (no DB): `[name]`
-> `?` extraction, **repeated-bind ordering**, missing-bind dies, unused-bind
warns, a Mojo::Template `<% if %>` branch, and the `\@` escape. For a live
check, point `DB.pm` at a scratch `sql/` dir and run one real query.

## Common mistakes

See `references/gotchas.md`. The top three: **`<%= $user_value %>` is raw
interpolation** (injection) - values must be `[bind]`; a bare **`@` in SQL must
be `\@`** under `vars => 1`; and **`[name]` is rewritten even inside a quoted
string or comment**, so avoid literal square brackets in SQL text.
