# 321.web

The deploy dashboard for managing Perl/Mojolicious services.

## Prerequisites

This service is managed by [321.do](https://321.do). You need:

- **321** installed and running on the target machine
- **perlbrew** with `perl-5.42.0`

If 321 isn't set up yet, see `docs/ec2-dev-setup.md`.

## Setup

### 1. Register the service

If `321.web` isn't already registered, create `services/321.web.yml` in the 321 repo (or use the dashboard's **+ ADD SERVICE** form).

### 2. Install

```
321 install 321.web
```

This handles everything: clone, deps, ubic, nginx, SSL.

### 3. Set secrets (if any)

Check what's needed:

```
321 status 321.web
```

Set required env vars from the dashboard's SECRETS panel, or via API:

```
curl -u 321:kaizen -X POST -H 'Content-Type: application/json' \
  -d '{"key":"MOJO_MODE","value":"production"}' \
  https://321.do/service/321.web/secrets
```

## Day-to-day

```
321 status 321.web     # is it running?
321 restart 321.web    # bounce after config change
321 go 321.web         # full deploy (git pull + deps + restart)
321 stop 321.web       # stop the service
321 start 321.web      # start it back up
```

### Other lifecycle commands

```
321 update 321.web     # pull + deps + migrate (no restart)
321 migrate 321.web    # run bin/migrate only
```

## Logs

From the dashboard, click the service name and use the **stdout / stderr / ubic** tabs.

Or tail directly:

```
tail -f /tmp/321.do.stdout.log
tail -f /tmp/321.do.stderr.log
```

## Configuration

### `.321.yml` (this repo)

Declares what the app needs to run:

```yaml
name: 321.web
entry: bin/321.pl
runner: hypnotoad
perl: perl-5.42.0
health: /health
env_required:
  MOJO_MODE: "production or development"
env_optional:
  DEPLOY_TOKEN:
    desc: "Token for remote deploy endpoint"
```

### `services/321.web.yml` (in the 321 repo)

Declares where and how to run it per target:

```yaml
name: 321.web
repo: /home/s3/web.321.do
branch: master
targets:
  dev:
    host: 321.do.dev
    port: 9321
    runner: morbo
  live:
    host: 321.do
    port: 9321
    runner: hypnotoad
```

### What goes where

| Fact | Where | Why |
|------|-------|-----|
| Entry point, runner, perl version | `.321.yml` (this repo) | Travels with the code |
| Required/optional env vars | `.321.yml` (this repo) | App knows what it needs |
| Host, port, target config | `services/*.yml` (321 repo) | Operator decides where it runs |
| Secret values | `secrets/*.env` (321 repo, gitignored) | Never in source control |

## Dev mode

On the dev machine, 321 runs with `morbo` (auto-reload on file changes). No need to restart after editing code — just save and refresh.

```
321 go 321.web    # on dev, skips git pull — just restarts with local changes
```
