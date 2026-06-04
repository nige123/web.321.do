# Agent Prompt — Using 321

You are an agent operating a deployment tool called **321** that manages Perl/Mojolicious services. This document is your operating manual: when you receive a task that involves deploying, restarting, diagnosing, or configuring a service, prefer 321's commands over hand-rolled SSH or systemctl invocations. They encode conventions you don't have.

## What 321 is

321 is a single Mojolicious daemon (`bin/321.pl`, port 9321) that:

- Reads per-service manifests (`<repo>/321.yml`) discovered under `/home/s3/`
- Generates ubic unit files at `~/ubic/service/<group>/<name>` and starts services via ubic (which wraps Hypnotoad for hot-restart, or Morbo for dev)
- Manages nginx + SSL (mkcert on dev, certbot on live, both via the same template)
- Deploys both **locally** (dev box) and **remotely** (live box, via SSH)
- Same daemon serves an HTTP dashboard and a CLI

Run from `/home/s3/web.321.do`. Paths in this document are absolute.

## Mental model

- **Service name** is `<group>.<name>` (e.g. `321.web`, `123.api`, `zorda.web`). The dot is a delimiter — the group becomes a ubic directory, the name a file inside it.
- **Targets**: every service has a `dev:` and (usually) a `live:` block in its `321.yml`. The active target is set by the `target` cookie on HTTP routes, or by the second positional argument on CLI commands (`321 go zorda.web live`).
- **Resolution**: most commands accept a prefix or substring of the service name (`321 status zorda` resolves to `zorda.web`). If ambiguous it tells you.
- **Secrets**: not 321's job. Each service repo loads its own secrets from its own config files (e.g. `conf/production.conf`). 321 only passes through the non-sensitive vars declared in a target's `env:` block.
- **No database** — 321 is stateless; the YAML manifests and the ubic state on the box are the source of truth.

## CLI commands (most useful first)

```
321 status [name] [target]      # ubic status; per-service detail or fleet-wide
321 list                        # all known services with mode/runner/port
321 go <name> [target]          # deploy: install if first time, otherwise hot-restart
321 install <name> [target]     # explicit first-time bring-up (clone, deps, ubic, nginx, SSL, start)
321 restart <name> [target]     # ubic restart; auto-regenerates ubic file if 321.yml is newer
321 start | stop <name> [target]
321 logs <name> [target] [--stderr|--ubic] [-n 100]
321 do [name] <target> <subcommand> [args]   # run the app's own Mojolicious subcommand at a target
321 doctor [target]             # probe each non-localhost host's HTTPS cert, report mismatches; exits non-zero on failure
321 nginx <name> [target] [--force]  # check/setup nginx + SSL for a service
321 generate                    # regenerate every ubic unit file from current manifests
321 hosts --print               # print the /etc/hosts block 321 would manage on dev
321 update                      # update dependencies, push to live, etc. (project-specific)
```

Default target is `dev` for most commands. `321 go` from inside a service repo with a `321.yml` infers the service name from the manifest.

`321 go` is the workhorse: it deploys, hot-restarts via Hypnotoad's SIGUSR2, checks the port responded, and on live also re-probes the public HTTPS cert and auto-runs `nginx setup` + `acquire_cert` if the cert is missing or wrong.

## When to reach for which command

| Situation | Command |
|-----------|---------|
| "Push my latest changes to dev/live" | `321 go` (from the service's repo dir) |
| "Why is the dashboard slow" | `321 status` then `321 logs <name> --stderr` |
| "Privacy warning on https://X" | `321 doctor live` to confirm, then `321 go X live` to auto-fix |
| "I changed the port in 321.yml and dev didn't pick it up" | `321 restart <name>` — auto-regenerates the ubic file |
| "First time setting up a new service" | Edit `<repo>/321.yml`, then `321 install <name>` (or just `321 go` — it auto-installs if not present) |
| "Worker for an existing service stopped" | `321 status <group>.<worker>` — workers are full ubic services with names of the form `<group>.<workerName>` |
| "Run the app's own subcommand (create_admin, a one-off script) on a target" | `321 do <name> <target> <subcommand> [args]` — reproduces the service's perl + `MOJO_MODE`/`MOJO_CONFIG` + repo libs; interactive over `ssh -t` on live |

## HTTP API surface (port 9321; HTTPS via 321.do or 321.do.dev)

All JSON responses follow `{ status, message, data }`. Auth is HTTP Basic (`321:kaizen`) on live; skipped on dev. `GET /health` is always public.

```
GET  /services?target=live          # list services + status (dashboard hot path)
GET  /service/:name/status?target=  # detailed status (pid, port, git_sha, mode, runner)
POST /service/:name/deploy          # full deploy (git pull + cpanm + restart)
POST /service/:name/deploy-dev      # cpanm + restart only, no git pull
POST /service/:name/{start|stop|restart}
GET  /service/:name/logs?type=stdout|stderr|ubic&n=100
GET  /service/:name/logs/search?q=…&n=50
GET  /service/:name/logs/analyse?n=1000
GET  /service/:name/config                  # raw 321.yml
POST /service/:name/config                  # update + git commit
GET  /service/:name/nginx                   # config_exists, enabled, ssl
POST /service/:name/nginx/setup             # generate + enable + test + reload
POST /service/:name/nginx/certbot           # acquire cert (uses --webroot now)
GET  /target | POST /target                 # read/set the active target cookie
GET  /git/status | POST /git/push
```

The dashboard at `/` calls `/services?target=…` on every refresh — keep changes to `Deploy::Service::all_status` cheap.

## Manifest contract (321.yml)

```yaml
name: zorda.web              # required: <group>.<name>
entry: bin/app.pl            # required: the script Hypnotoad/Morbo starts
runner: hypnotoad            # required: hypnotoad | morbo | script
perl: perl-5.42.0            # optional: perlbrew version
health: /health              # optional: post-deploy probe path
branch: master               # optional: git branch to deploy from (default: master)
test: prove -lr t            # optional: runs before deploying to live
favicon: https://…           # optional: dashboard avatar
force_https: true            # optional: when false, HTTP also proxies to backend (no 301)

apt_deps: [libpq-dev]        # apt packages installed before cpanm

dev:
  host: zorda.co.dev
  port: 8002
  runner: morbo

live:
  host: zorda.co
  port: 8002
  ssh: ubuntu@zorda.co
  ssh_key: ~/.ssh/kaizen-nige.pem
  env:                       # baked into the ubic wrapper as `env KEY=VAL` — non-secret vars only
    MOJO_MODE: production

workers:                     # optional: each becomes <group>.<worker> service, runner=script
  printer:
    cmd: bin/printer-worker.pl
```

## Workers and the lifecycle cascade

`workers:` entries in a service's `321.yml` become independent ubic services named `<group>.<workerName>`. The lifecycle commands treat parent + workers as one unit when the parent is named:

- `321 go <parent>`  — main redeploy, then `ubic restart` each worker (sorted)
- `321 start <parent>`  — main start, then start each worker (sorted)
- `321 restart <parent>`  — main restart, then `ubic restart` each worker
- `321 stop <parent>`  — stop workers in reverse sorted order, then stop main

Naming a worker directly (`321 restart 123.minion`) only touches that worker — the escape hatch when a single worker needs cycling.

Failed worker steps are reported but don't abort the cascade or the main step. A failed main step skips the worker pass.

## Common gotchas

- **Privacy warnings on a live host** mean nginx is falling through to the default SSL server because no 443 block was emitted for that hostname. Run `321 doctor live`, then `321 go <name> live` — the post-deploy hook auto-acquires the cert and regenerates with SSL.
- **Service "running (pid X) but port Y not responding"** — the process is up but failed to bind. Look at `321 logs <name> --stderr -n 50`. Common cause: missing required env var, DSN points to an unreachable DB, or wrong perl version.
- **`Set MOJO_CONFIG at .../app.pl line N`** — your app's startup demands MOJO_CONFIG; declare it in the target's `env:` block in `321.yml` and run `321 restart` (the ubic file auto-regenerates because the manifest mtime is newer).
- **Live ubic file is a stale symlink to `<repo>/ubic/...`** — old layout. `321 install` and `321 go` now `rm -f` the destination before uploading; just rerun.
- **`321 install` says perlbrew or cpanm fails** — check the live target has `ssh:` populated; an empty `ssh:` resolves to `ubuntu@` with no host and SSH errors out cryptically.
- **Editing sibling repos** — when working in `web.321.do`, propose changes to other service repos as diffs; don't edit them directly unless the user explicitly asks.

## Operational rules

- **Don't manually run certbot or stop nginx** on a live box. Use `321 nginx <name> live --force` or let `321 go live` auto-fix via the post-deploy probe — both use `--webroot` so nginx stays up.
- **Don't edit `~/ubic/service/<group>/<name>` by hand.** Edit `321.yml` and run `321 generate` (or any restart, which auto-regenerates).
- **Don't bypass `321 go`** with hand-rolled `git pull && cpanm && ubic restart` — you'll skip the apt-deps precheck, the migrate step, the post-deploy port probe, and the dev /etc/hosts + nginx + SSL fixup.
- **Always confirm before destructive operations**: `git push --force`, `ubic destroy`, removing a live nginx config, deleting an app's config file. Reversible operations (deploy, restart, regenerate) don't need confirmation.
- **On dev**, the dashboard shows every service across both targets. **On live**, it shows only services actually installed on the box (auto-filtered when `MOJO_MODE=production`).

## Where to read more

- `CLAUDE.md` (this repo) — full architecture overview, conventions, endpoint list
- `lib/Deploy/Service.pm` — deploy step logic (apt → git → cpanm → ubic → port check)
- `lib/Deploy/Nginx.pm` — nginx config rendering, cert acquisition, SSL probe
- `lib/Deploy/Ubic.pm` — unit file generation
- `lib/Deploy/Command/*.pm` — one file per CLI subcommand; read these to understand exactly what a command does

When in doubt, run the command with no args to see its `Usage:` text.
