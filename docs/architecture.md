# 321 Architecture

## What 321 is

A local CLI tool and dashboard for managing Perl/Mojolicious services. It runs on your dev machine and drives both local and remote servers.

**321 never runs in production.** All production operations happen over SSH from your local machine.

## How it works

```
Your machine                         Remote server
┌────────────────────┐               ┌──────────────────┐
│  321 CLI           │──── SSH ────> │  ubic (process)  │
│  321 dashboard     │               │  nginx (proxy)   │
│  secrets/*.env     │               │  your app        │
└────────────────────┘               └──────────────────┘
```

## Service discovery

321 scans `/home/s3/*/321.yml` to find services. Any directory with a `321.yml` manifest is a managed service. No registry, no config database — just convention.

## The 321.yml manifest

Each service repo has a `321.yml` at its root — the single source of truth:

```yaml
name: love.web
repo: git@github.com:nige123/love.honeywillow.com.git
entry: bin/app.pl
runner: hypnotoad
perl: perl-5.42.0
branch: main

dev:
    host: love.honeywillow.com.dev
    port: 8888
    runner: morbo

live:
    ssh: ubuntu@ec2-34-248-234-254.eu-west-1.compute.amazonaws.com
    ssh_key: ~/.ssh/kaizen-nige.pem
    host: love.honeywillow.com
    port: 8888
    runner: hypnotoad

env_required:
    DATABASE_URL: "Postgres connection string"
```

**What goes in 321.yml:**
- Service identity (name, entry point, runner, perl version)
- Git clone URL (for remote installs)
- Target configs (dev/live/live2 — host, port, SSH details)
- Required/optional env var declarations (descriptions, not values)

**What does NOT go in 321.yml:**
- Secret values — those live in `secrets/<name>.env` in the 321 repo

## Targets

A target is a named deployment destination. Every service can have multiple targets.

- **dev** — local machine, morbo (auto-reload), no SSH
- **live** — remote server, hypnotoad (zero-downtime), via SSH
- **live2, staging, etc.** — additional remote servers

The target is always the last CLI argument:
```
321 restart love.web live     # restart on production
321 restart love.web          # restart locally (dev)
321 restart                   # infer service from cwd, dev target
```

## Transport layer

Every command goes through a Transport — either `Deploy::Local` (shell exec) or `Deploy::SSH` (SSH exec). The caller never knows which.

```
Deploy::Transport->for_target($svc_config)
  → returns Deploy::Local (no ssh: field)
  → returns Deploy::SSH   (has ssh: field)
```

Both have the same interface: `run`, `run_in_dir`, `stream`, `upload`.

## Process management (ubic)

321 uses ubic to manage service processes. Key points:

- **Ubic service files live at `~/ubic/service/<group>/<name>`** — not in the repo
- **Generated dynamically by `321 rebuild`** — never committed to git
- **Secrets are sourced at runtime** — `set -a && . secrets/<name>.env && set +a` runs when the process starts
- **No credentials on disk** in repo directories

The generated ubic file contains:
- Working directory (the repo path)
- The run command (perlbrew + env vars + runner + entry point)
- Log file paths (conventional: `/tmp/<name>.{stdout,stderr,ubic}.log`)

## Secrets

Managed as simple `KEY=VALUE` files at `secrets/<name>.env` in the 321 repo:
- chmod 600
- gitignored
- Loaded at service start time (not baked into config files)
- Declarations (what keys are needed) live in `321.yml` → `env_required`

## Log paths

Convention-based, not configured:
```
/tmp/<name>.stdout.log
/tmp/<name>.stderr.log
/tmp/<name>.ubic.log
```

## Config auto-reload

321 tracks mtimes of all `321.yml` files. When any file changes on disk, config reloads automatically on the next request or CLI call. No restart needed.

## CLI commands

```
321 init                    # scaffold a 321.yml in the current repo
321 install <svc> [target]  # first-time: clone, deps, ubic, nginx, ssl
321 start <svc> [target]    # start the service
321 stop <svc> [target]     # stop the service
321 restart <svc> [target]  # restart + verify
321 go <svc> [target]       # deploy: pull + deps + migrate + restart
321 update <svc> [target]   # pull + deps + migrate (no restart)
321 migrate <svc> [target]  # run bin/migrate only
321 status [svc] [target]   # show running state
321 list [target]           # all services
321 logs <svc> [target]     # tail/search/analyse logs
321 rebuild [target]        # regenerate ubic files
321 dash                    # start local web dashboard
```

Service name is optional when you're in a repo with a `321.yml` — 321 infers it.

## Dashboard

Local-only web UI at `321.do.dev` (via `321 dash`). Shows:
- Service status tiles with green/red LEDs
- Live log streaming
- Deploy and restart buttons
- Target switching

No auth — it's local-only, never exposed to the internet.

## File layout

```
/home/s3/web.321.do/           # the 321 tool itself
├── bin/321.pl                 # Mojolicious app (CLI + dashboard)
├── bin/321                    # CLI wrapper
├── lib/Deploy/                # core modules
│   ├── Config.pm              # service discovery + resolution
│   ├── Manifest.pm            # 321.yml parser
│   ├── Service.pm             # deploy/restart/update orchestration
│   ├── Transport.pm           # Local/SSH factory
│   ├── Local.pm               # local command execution
│   ├── SSH.pm                 # remote command execution
│   ├── Ubic.pm                # ubic service file generator
│   ├── Nginx.pm               # nginx config + SSL
│   ├── CertProvider.pm        # certbot vs mkcert
│   ├── Hosts.pm               # /etc/hosts managed block
│   ├── Logs.pm                # tail/search/analyse
│   └── Command/               # CLI subcommands
├── secrets/                   # per-service .env files (gitignored)
├── 321.yml                    # 321's own manifest (dogfood)
└── docs/

/home/s3/<service-repo>/       # each managed service
├── 321.yml                    # service manifest
├── bin/app.pl                 # entry point
├── cpanfile                   # perl deps
├── local/                     # cpanm-installed deps (gitignored)
└── ...

~/ubic/service/                # ubic runtime (generated, not in git)
├── 321/web
├── love/web
├── zorda/web
└── ...
```
