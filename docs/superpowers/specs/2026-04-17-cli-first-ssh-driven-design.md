# 321 CLI-First, SSH-Driven Architecture

## Overview

321 becomes a local-only CLI tool + web dashboard running on the developer's machine. All production operations happen over SSH. No 321 service runs in production — eliminating the security surface and enabling multi-server support.

**Before:** 321 deployed as a web service on every server, controlling local services via system calls. Production dashboard exposed with HTTP Basic Auth.

**After:** 321 runs only on the dev machine. CLI commands drive remote servers via SSH. The web dashboard at `321.do.dev` is local-only.

## Core Model

Every operation works the same regardless of target. The difference is transport: local shell exec vs SSH exec.

```
321 restart love.web          →  local exec:  ubic restart love.web
321 restart love.web live     →  ssh exec:    ubic restart love.web
321 restart love.web live2    →  ssh exec:    ubic restart love.web (different server)
```

- Target is the optional last CLI argument. Omit = local dev.
- A target without `ssh` config is local.
- A target with `ssh` + `ssh_key` is remote.
- Multiple remote targets supported: `live`, `live1`, `live2`, etc.

## Service Configuration

Each service YAML keeps the current structure. Targets include SSH connection details for remote targets.

```yaml
# services/love.web.yml
name: love.web
repo: /home/s3/love.honeywillow.com
branch: main
targets:
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
  live2:
    ssh: ubuntu@ec2-52-17-100-50.eu-west-1.compute.amazonaws.com
    ssh_key: ~/.ssh/kaizen-nige.pem
    host: love.honeywillow.com
    port: 8888
    runner: hypnotoad
```

### Manifest: `321.yml`

Each service repo ships a `321.yml` (not dot-hidden) at the repo root declaring code-side facts:

```yaml
name: love.web
entry: bin/app.pl
runner: hypnotoad
perl: perl-5.42.0
health: /health
env_required:
  DATABASE_URL: "Postgres DSN"
env_optional:
  LOG_LEVEL:
    default: info
```

Deploy-side YAML (host, port, SSH, target config) stays in the 321 repo. Manifest (entry point, runner, perl, env) travels with the service code.

The `repo` path is the same on all machines — `/home/s3/<repo>`. This convention means the service YAML doesn't need per-target repo paths.

## CLI Commands

All subcommands via Mojolicious::Commands (`Deploy::Command::*`). Target is the optional last argument.

```
# Service lifecycle
321 start <service> [target]
321 stop <service> [target]
321 restart <service> [target]
321 go <service> [target]          # full deploy: git pull + cpanm + migrate + restart
321 update <service> [target]      # git pull + cpanm + migrate (no restart)
321 migrate <service> [target]     # run bin/migrate only

# First-time setup
321 install <service> [target]     # clone + perlbrew + cpanm + ubic + nginx + ssl

# Status
321 status [service] [target]      # one or all services
321 list [target]                  # all services with status, port, runner

# Logs
321 logs <service> [target]                # tail stdout (default)
321 logs <service> [target] --stderr       # tail stderr
321 logs <service> [target] --ubic         # tail ubic log
321 logs <service> [target] --search=ERR   # search logs
321 logs <service> [target] --analyse      # error/warning aggregation

# Maintenance
321 rebuild [target]               # regenerate all ubic service files + symlinks
321 hosts                          # update /etc/hosts managed block (local only)

# Dashboard
321 dash                           # start the local web dashboard
```

Service names accept prefix/substring matches (e.g. `love` matches `love.web`).

## Module Architecture

```
Deploy::Transport    — NEW: interface for command execution
Deploy::SSH          — NEW: SSH transport implementation
Deploy::Local        — NEW: local exec transport implementation
Deploy::Config       — REFACTORED: resolves target from CLI arg, merges manifest
Deploy::Service      — REFACTORED: all operations go through Transport
Deploy::Ubic         — KEEP: generates ubic service files (runs via Transport)
Deploy::Nginx        — KEEP: generates nginx config (runs via Transport)
Deploy::CertProvider — KEEP: certbot vs mkcert (runs via Transport)
Deploy::Logs         — REFACTORED: tail/search/analyse via Transport
Deploy::Manifest     — KEEP: loads 321.yml (renamed from .321.yml)
Deploy::Hosts        — KEEP: local only, dev /etc/hosts management
Deploy::Command::*   — REFACTORED: Mojolicious::Commands subcommands
```

### Deploy::Transport

The interface everything calls. Returns a Local or SSH transport based on target config.

```perl
my $t = Deploy::Transport->for_target($target_config);

$t->run($cmd)                # execute, return {ok, output, exit_code}
$t->run_steps(\@cmds)        # execute sequence, abort on failure
$t->stream($cmd, $cb)        # streaming output (for tail -f)
$t->upload($local, $remote)  # scp file to target
```

### Deploy::SSH

Handles SSH connection, perlbrew env wrapping, key auth. Every command is wrapped with:

```
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.0 && <cmd>
```

```perl
my $ssh = Deploy::SSH->new(
    user     => 'ubuntu',
    host     => 'ec2-34-248-234-254.eu-west-1.compute.amazonaws.com',
    key      => '~/.ssh/kaizen-nige.pem',
    perlbrew => 'perl-5.42.0',
);

$ssh->run($cmd)       # wraps with perlbrew env, runs via ssh
$ssh->stream($cmd)    # holds connection open, streams output
$ssh->upload(...)     # scp
```

### Deploy::Local

Thin wrapper around `system()` / backticks with the same interface as SSH. Also wraps perlbrew if configured.

## Install Flow (Remote)

`321 install love.web live` — the most complex operation. SSHes into the target and bootstraps everything.

**Prerequisites (documented, not automated):**
- SSH access configured (key-based)
- Passwordless sudo on the target server
- Git access on the server (SSH key added to GitHub)

**Steps executed remotely via Transport:**

1. Check perlbrew — install if missing
2. Check perl version — install if missing (`perlbrew install perl-5.42.0 --notest -j4`)
3. Install cpanm
4. Clone repo (skip if exists)
5. Install deps (`cpanm -L local --notest --installdeps .`)
6. Bootstrap ubic (`ubic-admin setup --batch-mode --local`, first time only)
7. Generate ubic service file + install symlinks
8. Start service (`ubic start love.web`)
9. Setup nginx — generate config, write to `/etc/nginx/sites-available/`, enable, test, reload
10. SSL cert — `sudo certbot certonly` (skip if cert exists)

Each step reports pass/fail. Failure aborts with a clear message. Perlbrew/perl install (steps 1-2) is slow (10-20 min) but only happens once per server.

## Web Dashboard

Local-only Mojolicious app at `321.do.dev` via `321 dash`.

**Features:**
- Service tiles — name, status LED (green/red), port, runner, target selector
- Click service to expand:
  - Logs panel — live-streaming stdout/stderr, switchable
  - Status — pid, uptime, git sha, port health
  - Deploy / Restart buttons
- Target dropdown — switch between dev/live to see status and logs from different servers

**Dropped from current dashboard:**
- Add/edit service forms
- Secrets management forms
- Config editing UI
- Docs page
- HTTP Basic Auth (local-only, no auth needed)

The dashboard is a visual wrapper around `321 status`, `321 logs`, `321 go`, and `321 restart`.

## What Gets Removed

**Dropped from `bin/321.pl`:**
- HTTP Basic Auth
- Deploy token / remote deploy endpoint
- JSON API endpoints (dashboard calls modules directly)

**Dropped modules:**
- `Deploy::Secrets` (web UI for secrets — env files managed manually)

**Dropped mechanisms:**
- Target cookie (target is now a CLI argument)
- SOPS encryption on service YAMLs (they only live on dev machine)

**Dropped files:**
- `bin/install.pl` (replaced by `321 install <service> <target>`)
- `deploy.do/` directory
- `ubic/service/321/web` on production servers

**Kept but simplified:**
- `bin/321.pl` — Mojolicious::Lite entry point for local dashboard + CLI
- `bin/321` — CLI wrapper

## Target Server Requirements

Documented prerequisites for any server 321 manages:

- Ubuntu 22.04+ (or similar)
- SSH access with key-based auth
- Passwordless sudo for the SSH user
- Git configured with GitHub access (SSH key)
- Ports 80 + 443 open (for nginx/SSL)

Everything else (perlbrew, perl, cpanm, ubic, nginx config, SSL certs) is installed by `321 install`.
