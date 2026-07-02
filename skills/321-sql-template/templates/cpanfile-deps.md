# Dependencies

The engine itself needs nothing beyond Mojolicious + a database driver.

```perl
# cpanfile
requires 'Mojolicious';   # ships Mojo::Template, Mojo::File, Mojo::Base
requires 'Mojo::Pg';      # Postgres. Swap for Mojo::mysql / Mojo::SQLite if needed.
```

- **`Mojo::Template`** (in Mojolicious core) is layer 1 of the renderer - the
  `.ep` logic engine. No separate install.
- **`Mojo::File`** (core) provides `path()` for locating `sql/<group>/<name>.sql.ep`.
- **`Mojo::Pg`** gives you the `$c->pg->db` request database and the
  `->hash` / `->hashes` / `->expand` result API used in `usage.pl`. The
  renderer is driver-agnostic; only the placeholder style (`?`) and the
  `->query` call assume a DBI-ish driver, which Mojo::Pg / Mojo::mysql /
  Mojo::SQLite all satisfy.

No `Imager`, no XS, no system packages. The renderer is pure Perl + core Mojo.
