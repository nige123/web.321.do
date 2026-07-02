# SQL-template gotchas

The failures that cost hours. Read before authoring `.sql.ep` files or touching
the renderer.

---

## 1. Bind vs. interpolate is the ENTIRE injection story

Two ways to get a value into the SQL look almost identical and behave nothing
alike:

```sql
WHERE email = [email]        -- SAFE: becomes ? , value bound by the driver
WHERE email = '<%= $email %>' -- INJECTION: value concatenated into the SQL string
```

`[name]` is a placeholder the driver parameterizes. `<%= $name %>` is raw
Mojo::Template interpolation straight into the SQL text. **Never** put a
user-supplied value through `<%= %>`. Use `<%= %>` only for structural decisions
from a fixed allowlist (a column name you validated, `ASC`/`DESC`). A single
`<%= $user_input %>` is a textbook hole and it sits one character away from the
safe form.

## 2. You cannot bind an identifier

`?` / `[bind]` stand in for **values only** - never a table name, column name,
`ORDER BY` target, or `ASC`/`DESC`. Those genuinely need `<%= %>`, so validate
them against an allowlist in Perl before they reach the template:

```perl
my %SORT = (recent => 'created_at', title => 'title');   # allowlist
my $col  = $SORT{ $param } // 'created_at';              # never the raw param
$db->query('tiles/sorted', { array_id => $id, sort_col => $col });
```
```sql
 ORDER BY <%= $sort_col %> DESC   -- safe ONLY because $sort_col came from the allowlist
```

## 3. The `\@` trap under `vars => 1`

The renderer runs Mojo::Template with `vars => 1` so bind keys are lexicals
(`<% if (defined $tile_id) %>`). The cost: Mojo::Template now reads a bare `@`
as the start of a Perl array. **Any `@` in the SQL must be escaped `\@`:**

```sql
-- WRONG: '@' starts an array var -> render error
WHERE email LIKE '%@example.com'
-- RIGHT:
WHERE email LIKE '%\@example.com'
```

Bites Postgres array/operator syntax and any literal email in SQL or comments.
Fails at render time, not when you save the file.

## 4. `[name]` is rewritten even inside strings and comments

The `[name]` -> `?` pass is a regex, not SQL-aware. A literal `[foo]` inside a
`'...'` string or after `--` still becomes `?` and demands a bind:

```sql
-- this comment mentioning [limit] will break: it turns into ? and wants a bind
SELECT '[not a bind]' AS label   -- also rewritten
```

Avoid literal square brackets in SQL text. If you must emit one, build it via
`<%= %>` from a constant.

## 5. Missing bind DIES; unused bind only WARNS - and branches hide both

```perl
# [name] with no matching key  -> dies "Missing bind parameter [name]"
# key passed but no [name]      -> warns "unused bind parameter [name]"
```

With optional `<% if %>` branches, a `[name]` can be "missing" only on the path
actually taken - so a key that's unused *on this branch* won't even warn, and a
bind referenced *only* on the untaken branch won't fire. **Test both branches.**

## 6. Every `$var` a template references must be a passed key

Because logic runs under `vars => 1`, an optional clause like
`<% if (defined $tile_id) { %>` needs `tile_id` present in the binds. Always
pass optional params explicitly as `undef` rather than omitting them:

```perl
$db->query('clicks/recent', { array_id => $id, tile_id => undef, days => 7 });
```

Omitting `tile_id` makes `$tile_id` an unknown variable in the template, not a
tidy `undef`. Pass it; let the `<% if (defined ...) %>` decide.

## 7. `undef` binds as SQL `NULL`, which changes meaning

`[status]` with `$record->{status} = undef` binds `NULL`, and `col = NULL` is
**never true**. For a genuinely optional filter, branch on it - don't bind NULL
and hope:

```sql
% if (defined $status) {
   AND status = [status]
% }
```
Not `AND status = [status]` with `status => undef`.

## 8. `IN (...)` lists do not expand

`[ids]` with an arrayref binds **one** placeholder holding an array, not
`?,?,?`. Use Postgres array membership instead of trying to build a comma list:

```sql
WHERE tile_id = ANY([ids])     -- $record->{ids} = [1,2,3]  (Mojo::Pg -> int[])
```
Never assemble `IN (` . join(',', @ids) . `)` by hand - that's back to string
concatenation (gotcha #1).

## 9. One statement per call

`Mojo::Pg::Database::query` runs a single statement. Don't put two
`;`-separated statements in one `.sql.ep` expecting both to run - split them
into two queries, or wrap them in a Perl-side transaction (`$db->begin`).

## 10. Leading `%` is a Mojo::Template line of code

Mojo::Template treats a line whose first non-space char is `%` as Perl, and
`%#` as a comment. That's how you write `% if (...) {` control lines - but it
means an SQL line must never *start* with `%`. Modulo/`LIKE '%x%'` mid-line is
fine; a line beginning with `%` is not. Use `--` for SQL comments, `%#` for
template comments.

## 11. Templates are cached in-process - edits need a restart

`DB.pm` caches each slurped template in a package hash that never expires. Great
for throughput; a footgun in dev: **editing a `.sql.ep` has no effect until the
service restarts** (via 321, never a manual `pkill`). If a query change "isn't
taking", you forgot to restart.

## 12. Repeated binds follow textual output order

`[user_id]` used three times pushes three values, in the order they appear in
the *rendered* SQL. If `<% %>` logic conditionally emits a `[bind]`, its
position in the bind list shifts with it - which is correct, but means you read
bind order off the rendered output, not the source. The headless renderer test
(`templates/sql-template.t`) pins this.
