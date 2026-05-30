# CLAUDE.md

## Project Overview

321.do — 3... 2... 1... deploy! A standalone deploy, log analysis, and operations service for managing Perl/Mojolicious services. Replaces in-app deploy endpoints that caused outages by restarting themselves mid-request.

Runs on both the dev machine (`dev.321.do`) and production (`321.do`). The same daemon can deploy locally or remotely; production deploys do a `git fetch` + `git reset --hard origin/<branch>` first.

## Tech Stack

- **Language:** Perl 5.42 (`Mojo::Base -base, -signatures`)
- **Framework:** Mojolicious::Lite
- **Service controller:** UBIC (wrapping Hypnotoad for hot-restart zero-downtime deploys, or Morbo for dev)
- **Web server:** nginx (config managed by 321; SSL via letsencrypt/certbot on live, mkcert on dev — see Dev parity)
- **Config:** A `321.yml` manifest at the root of every service repo. 321 scans sibling directories under `/home/s3` for these. Legacy flat `services.yml` is still read as a fallback.
- **Secrets:** **not 321's job** — each service repo handles its own secrets via its own config files / env loading. 321 only passes through whatever non-sensitive env vars are declared per-target in `321.yml` (`env:`).
- **No database** — stateless, config-driven.

## Architecture

Single lightweight daemon on port **9321**. Entry point is `bin/321.pl` (Mojolicious::Lite). A thin `bin/321` wrapper `exec`s it so the same app serves HTTP routes and CLI commands.

Core modules (`lib/Deploy/`):

- `Config.pm` — loads per-repo `321.yml` manifests, resolves the active target (`dev`/`live`) into a flat service descriptor.
- `Service.pm` — `status`, `deploy` (git + cpanm + ubic restart + port check), `deploy_dev` (no git pull), log writes under `/tmp/321.do/deploys/`.
- `Ubic.pm` — generates `ubic/service/<group>/<name>` files from config and installs symlinks under `~/ubic/service/<group>/<name>`. Builds the `perlbrew exec --with … env KEY=VAL hypnotoad -f …` (or `morbo`) command line.
- `Nginx.pm` — renders `/etc/nginx/sites-available/<host>` (HTTP + optional SSL), enables the site, runs `nginx -t` + `systemctl reload nginx`. Delegates cert paths and acquisition commands to `CertProvider`.
- `CertProvider.pm` — chooses certbot (live) or mkcert (dev) based on active target; returns cert/key paths and the acquire command. See `## Dev parity`.
- `Hosts.pm` — rewrites the `# BEGIN 321.do managed` block in `/etc/hosts` with dev-target hostnames pulled from `Config->dev_hostnames`. See `## Dev parity`.
- `Logs.pm` — tail / search / analyse for stdout, stderr, and ubic logs.
- `Command.pm` + `Command/` — Mojolicious CLI subcommands registered via `app->commands->namespaces`.

### Targets (dev vs live)

Each service YAML has `targets: { dev: {…}, live: {…} }` with per-target `host`, `port`, `runner`, `env`, `logs`. The active target comes from the `target` cookie (defaults to `dev` in development mode, `live` in production). `POST /target` and `GET /target` set/read it; `Config->service($name)` resolves to the active target.

### Service naming

Service names are `<group>.<name>` (e.g. `321.web`, `123.api`). The group/name split drives the ubic symlink layout: `~/ubic/service/<group>/<name>` → `<repo>/ubic/service/<group>/<name>`.

### Workers and the lifecycle cascade

Services declared under a parent's `workers:` block in `321.yml` are expanded into independent ubic services named `<group>.<workerName>` (a minion worker on `123.api` becomes the ubic service `123.minion`). They share the parent's repo, perl version, and target config, but they have their own pid, logs, and ubic file.

`321 go`, `321 start`, `321 stop`, and `321 restart` treat the parent and its workers as one unit when the *parent* is named. The parent runs first on start/go/restart; workers are restarted after in sorted name order. Stop iterates in reverse — workers first, parent last — so jobs settle before the connection they depend on goes away. Naming a worker directly (`321 restart 123.minion`) acts only on that worker, so a stuck worker can be cycled without disturbing the web tier.

Per-worker failures are reported but don't abort the cascade or the main step. A failed main step skips the worker pass — there is nothing useful to cascade to.

### Endpoints

```
GET  /                                — Dashboard UI
GET  /ui/service/:name                — Service detail UI
GET  /health                          — health check (public, no auth)

GET  /services                        — list all services + status
GET  /service/:name/status            — detailed status (pid, port, git sha, mode, runner)
POST /service/:name/deploy            — git pull + cpanm + regenerate ubic + ubic restart + port check
POST /service/:name/deploy-dev        — cpanm + regenerate ubic + ubic restart (no git pull)
POST /service/:name/start             — ubic start
POST /service/:name/stop              — ubic stop
POST /service/:name/restart           — ubic restart

GET  /service/:name/logs              — tail logs (?type=stdout|stderr|ubic&n=100, max n=1000)
GET  /service/:name/logs/search       — search logs (?q=…&type=…&n=50, max n=500)
GET  /service/:name/logs/analyse      — error/warning aggregation (?n=1000, max n=10000)

GET  /service/:name/config            — raw service YAML
POST /service/:name/config            — update config (JSON body) + git commit
POST /services/create                 — create service (JSON body, requires `name`) + git commit + ubic generate
POST /service/:name/delete            — delete service + git commit
POST /services/generate-ubic          — regenerate all ubic files + install symlinks

GET  /service/:name/nginx             — nginx site status (config_exists, enabled, ssl)
POST /service/:name/nginx/setup       — generate + enable site, test, reload nginx
POST /service/:name/nginx/certbot     — request letsencrypt cert, regenerate config with SSL, reload

GET  /git/status                      — { branch, unpushed }
POST /git/push                        — git push in app home

GET  /target                          — { target, available }
POST /target                          — set active target cookie (JSON: { target })
```

All JSON responses follow `{ status, message, data }`.

### CLI

`bin/321` (or `perl bin/321.pl <subcommand>`):

```
321 list                   # all services with mode, runner, port
321 status [service]       # ubic status for one or all
321 start|stop|restart <service>
321 go <service>           # deploy: git pull + cpanm + ubic restart (dev mode: ubic restart only)
321 install <service>      # first-time: clone + cpanm + ubic + nginx + certbot
321 generate               # regenerate all ubic service files + symlinks
```

Service-name arguments accept prefix/substring matches (see `Deploy::Command::resolve_service`).

### Auth

HTTP Basic Auth required in production — credentials `321:kaizen`. Accepted via `Authorization: Basic …` header or `https://321:kaizen@…` URL userinfo. Auth is skipped in development mode and `/health` is always public.

## Dev parity

Dev mirrors production byte-for-byte — same nginx templates, same `listen 443 ssl`, same proxy headers. Two mechanisms keep it that way:

1. **`/etc/hosts` managed block** — `321 generate` (and `321 install`) rewrite the block between `# BEGIN 321.do managed` / `# END 321.do managed` with every dev-target hostname across `services/*.yml`. Non-managed lines are never touched. Needs sudo for the write; print the desired block with `321 hosts --print` first if you want to inspect.

2. **mkcert instead of certbot** — on dev targets, `Deploy::CertProvider` emits `mkcert -cert-file … -key-file …` commands; on live targets, certbot as before. Install once per dev machine:

   ```
   sudo apt install libnss3-tools mkcert   # or: brew install mkcert
   mkcert -install                         # installs the local CA into the system + Firefox/Chrome trust stores
   ```

   Cert files land in `~/.local/share/mkcert/<host>.pem`. The nginx template reads those paths the same way it reads letsencrypt paths in prod — no conditional blocks.

Prod never needs mkcert; dev never needs certbot. Both still use the same `Deploy::Nginx` templates.

## Service Repo Contract

Every service repo installed by 321 must ship a `321.yml` at the repo root. It declares everything 321 needs to clone, build, run, and serve the app — identity, runner, target-specific host/port, and any apt deps.

```yaml
name: love.web              # <group>.<name>
entry: bin/love.pl
runner: hypnotoad           # hypnotoad | morbo | script
perl: perl-5.42.1           # optional; perlbrew version
health: /health             # optional; post-deploy probe path
branch: main                # optional; defaults to master
repo: git@github.com:you/love.honeywillow.com.git
apt_deps:                   # optional; sudo apt-get install before cpanm
  - libfreetype-dev

dev:
    host: love.honeywillow.com.dev
    port: 8888
    runner: morbo
live:
    host: love.honeywillow.com
    port: 8888
    runner: hypnotoad
    ssh: ubuntu@zorda.co
    ssh_key: ~/.ssh/kaizen-nige.pem
    env:                    # plain (non-secret) overrides only
        MOJO_MODE: production
```

**Secrets are the service repo's responsibility, not 321's.** Each app loads its own secrets however it wants (its own config file, an environment loader at startup, etc.). 321 only passes through whatever non-sensitive env vars the target block declares under `env:`.

If a target's hypnotoad runner needs to listen on a specific port, the app's production config must set `hypnotoad => { listen => ['http://*:PORT'] }` to match the manifest port — 321 can't pass it on the command line. A mismatch shows up as a `port_check` failure with the actual bound port in the hint.

## Development

```bash
perl bin/321.pl daemon -l http://127.0.0.1:9321
prove -lr t
```

## Coding Conventions

- Four space indentation
- JSON responses: `{ status, message, data }`
- All endpoints require HTTP Basic Auth in production (except `GET /health`)
