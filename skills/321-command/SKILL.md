---
name: 321-command
description: Use when deploying, restarting, starting/stopping, checking status, or pulling logs for any 123.do-family service (api.123.do, web.321.do, tui.123.do, sibling project repos with a 321.yml). 321 is the canonical deploy tool — do not invoke ubic/morbo/systemctl/certbot directly.
---

# Using 321

`321` is the deploy tool for 123.do-family services. It's a single Mojolicious daemon (`bin/321.pl` in `/home/s3/web.321.do`, port 9321) that also exposes a CLI. It reads `<repo>/321.yml` manifests, generates ubic unit files, manages nginx + SSL, and deploys to dev (local) and live (remote via SSH).

**Authoritative manual:** `/home/s3/web.321.do/AGENT.md`. Read it if anything below feels under-specified.

## When this skill applies

Any task involving:

- Deploying code changes to a service (dev or live)
- Restarting/starting/stopping a service after config or code changes
- Checking whether a service is up and on what port
- Pulling logs after a failed request or crash
- Diagnosing privacy warnings / cert issues on live HTTPS
- First-time setup of a new service

If you reach for `ubic`, `morbo`, `systemctl`, `certbot`, `nginx -s reload`, or hand-rolled `git pull && cpanm && restart` — stop. Use `321` instead.

## Service naming

`<group>.<name>` with a dot. Examples:

| Service | Repo |
|---|---|
| `123.api` | `/home/s3/api.123.do` |
| `321.web` | `/home/s3/web.321.do` |
| `123.tui` (if registered) | `/home/s3/tui.123.do` |
| `zorda.web` | `/home/s3/web.zorda.co` |

Most `321` commands accept a prefix/substring (`321 status zorda` → `zorda.web`). Ambiguous matches are reported.

## Quick decision table

| Intent | Command |
|---|---|
| "Push my changes to dev" | `321 go` (from inside the service repo) — or `321 go 123.api` |
| "Push my changes to live" | `321 go 123.api live` |
| "Restart this service" (e.g. after editing 321.yml or config) | `321 restart 123.api [target]` |
| "What's the status of …?" | `321 status 123.api [target]` |
| "Why isn't it responding?" | `321 status <name>` then `321 logs <name> --stderr -n 50` |
| "Show me the last N log lines from live" | `321 logs <name> live -n 200` (default 100, max 1000; one-shot, exits — agent-safe) |
| "Live stderr from the last failure" | `321 logs <name> live --stderr -n 200` |
| "Grep live logs for a phrase" | `321 logs <name> live --search=ERROR -n 50` |
| "Privacy warning on https://X" | `321 doctor live` to confirm, `321 go X live` to auto-fix |
| "First time setting up a new service" | Edit `<repo>/321.yml`, then `321 install <name>` (or `321 go` — auto-installs) |
| "List everything" | `321 list` |
| "I changed the port in 321.yml and dev didn't pick it up" | `321 restart <name>` — auto-regenerates the ubic file |
| "Restart this service AND its minion/workers" | `321 restart <parent>` — cascades to workers in sorted name order |
| "Cycle just one stuck worker" | `321 restart <parent>.<workerName>` — naming a worker directly skips the cascade |
| "Bring the whole unit (web + workers) up/down" | `321 start <parent>` / `321 stop <parent>` — start cascades sorted, stop in reverse |
| "Stop / start every local service at once" | `321 stop all` / `321 start all` — acts on all dev-target services (with workers); live-only services are skipped |
| "Deploy and want workers on new code too" | `321 go <parent>` — main redeploys, workers bounced via `ubic restart` after |
| "Run the app's own subcommand (e.g. create_admin) on live" | `321 do <name> live <subcommand> [args]` — reproduces the service's perl + env, over SSH |
| "Run a Mojo subcommand from inside the repo" | `321 do <target> <subcommand> [args]` — service inferred from the cwd `321.yml` |

## The most useful commands

```
321 status [name] [target]      # ubic status; per-service detail or fleet-wide
321 list                        # all known services with mode/runner/port
321 go <name> [target]          # deploy: install if first time, otherwise hot-restart
321 restart <name> [target]     # ubic restart; auto-regenerates ubic file if 321.yml is newer
321 start | stop <name> [target]
321 stop all | start all        # stop/start every local (dev-target) service; skips live-only
321 logs <name> [target] [--stderr|--ubic] [-n 100]   # one-shot snapshot, exits
321 logs <name> [target] -f                            # tail -f (humans only — hangs until Ctrl-C)
321 logs <name> [target] --search=TERM [-n 50]         # grep matches
321 logs <name> [target] --analyse [-n 1000]           # error/warning summary
321 do [name] <target> <subcmd> [args]                 # run the app's own Mojo subcommand at a target
321 doctor [target]             # probe HTTPS certs + audit repos for the fragile @INC glob
321 install <name> [target]     # explicit first-time bring-up
321 nginx <name> [target] [--force]  # nginx + SSL setup
321 generate                    # regenerate every ubic unit file from current manifests
```

Default target is `dev`. From inside a service repo with a `321.yml`, `321 go` infers the service name from the manifest.

`321 go` is the workhorse: deploys (apt → git pull → cpanm → zero-downtime USR2 hot swap for running hypnotoad services, stop/start bounce otherwise → health gate), and on live re-probes the public HTTPS cert + auto-runs nginx setup + cert acquisition if missing. A live deploy whose health gate fails rolls the repo back to the previous sha and re-serves the old release (status: `rolled_back`) - nothing stays broken. Apps that override `pid_file` in their hypnotoad config must mirror it in `321.yml`, or deploys fall back to the cold bounce.

## Hard rules — don't bypass

- **Don't** manually run `certbot`, `ubic`, `morbo`, `systemctl`, `nginx -s reload`, or `service <x> restart` on a managed service. Use `321 <command>`. The tooling encodes apt-deps, env-required checks, port probes, and cert flows you'll skip otherwise.
- **Don't** edit `~/ubic/service/<group>/<name>` by hand. Edit `<repo>/321.yml` and run `321 restart` (or any restart auto-regenerates from the manifest).
- **Don't** hand-roll `git pull && cpanm && ubic restart`. Use `321 go`.
- **Don't** SSH to the live box to run an app subcommand by hand (`ssh … perlbrew exec … perl bin/app.pl create_admin …`). Use `321 do <name> live <subcommand> [args]` — it reproduces the right perl, `MOJO_MODE`/`MOJO_CONFIG`, and repo-local libs, and is interactive (prompts work).
- **Workers are part of the unit**: when a service has a `workers:` block (e.g. a minion worker), `321 <go|start|stop|restart> <parent>` cascades to every worker. Don't run `321 restart parent` then `ubic restart parent.worker` by hand — the cascade already did it. Name the worker directly only when you want it isolated.
- **Confirm before destructive operations**: `git push --force`, `ubic destroy`, removing a live nginx config, deleting an app's config file. Reversible ops (deploy, restart, regenerate) don't need confirmation.
- **Sibling repo edits**: when working in one service's repo, propose changes to other service repos as diffs — don't edit them directly unless the user explicitly asks.

## Diagnosis playbook

When a service is reported as broken:

1. **`321 status <name>`** — Is the process running? On what port? In what mode (dev/live)?
2. **If running but unresponsive**: `321 logs <name> --stderr -n 50`. Common causes: missing env var, unreachable DB, wrong perl version, wrong port, syntax error.
3. **If not running**: `321 logs <name> --ubic -n 50` to see why ubic failed to start it.
4. **If a privacy warning on live**: `321 doctor live` confirms the cert mismatch; `321 go <name> live` auto-fixes via the post-deploy probe → nginx setup → certbot.
5. **If editor saved a half-written file and morbo died**: a clean save fixes it; if morbo doesn't recover, `321 restart <name>`.
6. **If a subcommand dies with `Global symbol "%Config" requires explicit package name` (e.g. via `321 do`) but the daemon runs fine**: the app's `bin/*.pl` globs every subdir of `local/lib/perl5` onto `@INC`, so a namespace dir (e.g. `HTTP/`) shadows core `Config.pm`. The daemon dodges it (hypnotoad loads `Config` early); subcommands don't. Run `321 doctor` to locate the offending file, then fix the app's entry script to resolve only the arch dir (`$Config{archname}`) instead of globbing the whole tree. `321 do` preloads core `Config` as a stopgap, but the app is still wrong.

## 321.yml manifest essentials

Lives in the service repo root. Required: `name`, `entry`, `runner` (`hypnotoad` | `morbo` | `script`). Plus per-target `host`/`port`/`ssh`/`env`. Optional: `health` (post-deploy probe path), `workers:` block (each worker becomes its own ubic service named `<group>.<workerName>`, including Minion workers).

When you change the manifest, just run `321 restart <name>` — the ubic file regenerates automatically because the manifest mtime is newer than the unit file.

## HTTP API (less common)

321 also exposes an HTTP API on port 9321 (HTTPS via `321.do` or `321.do.dev`), Basic auth `321:kaizen` on live. Useful when scripting; the CLI is the canonical surface. See AGENT.md for the route list.

## When in doubt

```bash
321 <command>          # with no args, prints Usage
cat /home/s3/web.321.do/AGENT.md
```

Source of truth for each command lives at `/home/s3/web.321.do/lib/Deploy/Command/<command>.pm`.
