# 321 — Operator Quickstart

**321.do** is a standalone deploy + log + ops daemon for Perl/Mojolicious services. It owns ubic, nginx, and certbot so your apps don't have to. One daemon on port **9321**, per-service config under `services/`, no database.

If something is unclear here, the canonical reference is `CLAUDE.md` in the repo root.

---

## Getting started (first-time install)

1. Clone the repo to the canonical path: `/home/s3/web.321.do`.
2. Run the installer — it sets up perlbrew, deps, ubic, nginx, SSL:
   ```
   sudo perl bin/install.pl
   ```
3. The dashboard is then at `https://321.do/` (prod) or `http://127.0.0.1:9321/` (dev). Basic-auth with `321:kaizen`.

On dev boxes you'll also need **mkcert** for local SSL — see *Dev parity* below.

---

## Day-to-day workflow

### Deploy a service (first time)

```
321 install <service>     # clone, cpanm, ubic, nginx, certbot/mkcert
```

The service name is `<group>.<name>` (e.g. `zorda.web`, `123.api`). You can shorten it — any unambiguous prefix or substring works.

### Deploy an update

From the dashboard: click **GO** on the service tile.
From the CLI:
```
321 go <service>          # git fetch + reset --hard + cpanm + ubic restart + port check
```

In dev mode, `go` skips the git pull — you work directly in the checkout.

### Start / stop / restart

```
321 start   <service>
321 stop    <service>
321 restart <service>
321 status  [service]     # ubic status for one, or all if omitted
321 list                  # all services with mode, runner, port
```

---

## Adding a new service

1. **Create the config** — either via the dashboard (**+ NEW SERVICE** button) or by dropping a YAML under `services/<name>.yml`. Shape:

   ```yaml
   name: foo.web
   repo: /home/s3/foo.web
   branch: master
   bin: bin/foo.pl
   perlbrew: perl-5.42.0
   targets:
     dev:
       host: dev.foo.do
       port: 9600
       runner: morbo
     live:
       host: foo.do
       port: 9600
       runner: hypnotoad
   ```

2. **Encrypt sensitive fields** — `sops encrypt -i services/foo.web.yml` if anything in `env:` is a secret. The `env` regex is already in `.sops.yaml`.

3. **Install**:
   ```
   321 install foo.web
   ```

4. **Regenerate ubic files** for all services (useful after editing existing YAMLs):
   ```
   321 generate
   ```

---

## Dev vs live targets

Each service YAML has `targets: { dev: {…}, live: {…} }`. The active target is driven by the `target` cookie — set in the dashboard (top nav) or with:

```
curl -fsS -u 321:kaizen -X POST -H 'Content-Type: application/json' \
    -d '{"target":"dev"}' http://127.0.0.1:9321/target
```

Default: `dev` in development mode, `live` in production.

Use dev for local iteration (morbo autoreload, mkcert SSL, `dev.*.do` hostnames). Use live for the real thing (hypnotoad, letsencrypt, real domains).

---

## Per-repo Perl deps (`local/`)

Each service repo keeps its own CPAN dependencies under `./local/`. Deploys run `cpanm -L local/ --notest --installdeps .`; the generated ubic wrapper prepends `PERL5LIB=<repo>/local/lib/perl5` and `PATH=<repo>/local/bin:$PATH` so the running daemon finds them. No sharing with system `site_perl`; no cross-service pollution.

**Every service repo must gitignore `/local/`**. A one-liner to add it:

```
echo '/local/' >> .gitignore && git add .gitignore && git commit -m 'Ignore cpanm --local dir'
```

If a later need arises for reproducible builds across boxes, layer [Carton](https://metacpan.org/pod/Carton) on top — it commits a `cpanfile.snapshot` and uses the same `./local/` tree.

---

## Secrets

Plaintext secrets live in `secrets/<name>.env` — shell-style `KEY=value`, one per line. They are gitignored. 321 loads them into the ubic wrapper env when a service starts.

Secret values inside `services/<name>.yml` (the `env:` block) are SOPS-encrypted with age recipients. The dashboard's **CONFIG** editor handles decrypt + re-encrypt transparently.

---

## Logs

- `/tmp/<service>.stdout.log` — app stdout
- `/tmp/<service>.stderr.log` — app stderr
- `/tmp/<service>.ubic.log` — ubic lifecycle

From the dashboard: **LOGS** button per service. From the CLI, use `tail -f` or the HTTP routes:

```
GET /service/<name>/logs           ?type=stdout|stderr|ubic&n=100
GET /service/<name>/logs/search    ?q=error&type=stderr&n=50
GET /service/<name>/logs/analyse   ?n=1000     # error/warning aggregation
```

---

## Dev parity

Dev mirrors production byte-for-byte — same nginx templates, same `listen 443 ssl`, same proxy headers. Two mechanisms:

- **`/etc/hosts` managed block** — `321 generate` and `321 install` rewrite the block between `# BEGIN 321.do managed` / `# END 321.do managed` with every dev-target hostname. Needs sudo for the write. Preview with `321 hosts --print`; apply with `sudo -E perl bin/321.pl hosts`.
- **mkcert on dev, certbot on live** — `Deploy::CertProvider` picks automatically based on the active target. One-time dev setup:
  ```
  sudo apt install libnss3-tools mkcert   # Linux
  brew install mkcert                     # macOS
  mkcert -install                         # adds local CA to system + Firefox/Chrome
  ```

Prod never needs mkcert; dev never needs certbot.

---

## Common problems

- **"Port N not responding" after deploy** — the service crashed on startup. Check `/tmp/<name>.stderr.log`.
- **"ubic restart" hangs or fails** — try `ubic stop <name>` then `ubic start <name>`. If a stale hypnotoad is bound to the port: `fuser -k <port>/tcp`.
- **nginx reload fails** — `sudo nginx -t` will show the template error. The 321 config at `/etc/nginx/sites-available/<host>` is regenerated on every deploy.
- **mkcert cert not trusted by the browser** — you skipped `libnss3-tools` or didn't run `mkcert -install` after installing the package. Do both, then regenerate the cert.
- **"missing required secret"** (future; Plan 1 work) — the service repo's `.321.yml` declares required env keys and the dashboard refuses to deploy until they're set.

---

## Further reading

- `CLAUDE.md` — full architecture, endpoint inventory, coding conventions.
- `docs/superpowers/plans/` — implementation plans (internal; not operator-facing).
