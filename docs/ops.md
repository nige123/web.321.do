# 321 — Operator Quickstart

321 owns deploys, ubic, nginx, and SSL for a fleet of Perl/Mojolicious services. One daemon on port 9321, per-service YAML in `services/`, no database.

Dashboard: **https://321.do.dev/** (dev) or **https://321.do/** (prod). Basic auth: `321` / `kaizen`.

---

## Get a service up and running

End-to-end: from a fresh service repo to a running, verified service behind SSL. Steps build on each other — run them in order.

### 1. Describe the service

Drop a YAML under `services/<name>.yml`. Minimum shape:

```yaml
name: foo.web
repo: /home/s3/foo.web
branch: main                  # or master — match what the repo actually uses
bin: bin/app.pl               # entry point (Mojolicious app)
targets:
  dev:
    host: foo.do.dev          # <live-host>.dev — this is the convention
    port: 9600
    runner: morbo             # dev uses morbo (autoreload)
  live:
    host: foo.do
    port: 9600
    runner: hypnotoad         # live uses hypnotoad (hot restart)
apt_deps:                     # optional — system packages the app's XS deps need
  - libexpat1-dev             # XML::Parser
  - libpng-dev                # Image::PNG::Libpng
```

If the service needs secret env vars (`DB_PASS`, `API_KEY`, etc.), put them in `secrets/<name>.env` as `KEY=value` — plaintext but gitignored. 321 loads them into the service's env when it starts.

### 2. Install — phase 1, once per box

```
321 install foo.web
```

This:
- clones the repo to `/home/s3/foo.web` if missing
- runs `cpanm -L local --installdeps .` so the deps land in the repo's own `local/` (per-service, no sharing)
- generates the ubic service file, installs the symlink under `~/ubic/service/<group>/<name>`
- generates the nginx site, enables it, reloads nginx
- on dev targets: issues an mkcert certificate into `/etc/ssl/321/<host>.pem` and refreshes the `/etc/hosts` managed block
- on live targets: runs certbot against letsencrypt
- starts the service via ubic

If any step needs system packages that aren't installed, the deploy log shows the exact `sudo apt install -y …` line to run. Run it once, rerun install.

### 3. Verify

Three places to look, in order:

**a. Dashboard** (https://321.do.dev/): the service's tile should show a green LED and a non-zero PID.

**b. Health check**: click the service tile, then the **VISIT** button (or `curl -fsS https://foo.do.dev/health` if the app exposes `/health`). 200 = alive.

**c. Terminal tab on the service detail page**:
- `stderr` tab — any startup errors land here
- `ubic` tab — ubic's view of the service (running / restarting / exited)
- `deploy` tab — last deploy's per-step output, expanded on failure

If something's wrong, the failing step is auto-expanded on the `deploy` tab with the full output.

### 4. Deploy updates — phase 2, repeatable (DEPLOY button)

Click **DEPLOY** on the service detail. Or from the CLI:

```
321 go foo.web
```

Full pipeline: `apt_deps` → `git_pull` → `cpanm` → `migrate` (if `bin/migrate` exists) → `ubic_restart` → `port_check`. Runs without sudo, no interactive prompts. Safe to click repeatedly; no nginx/cert/hosts changes happen here.

On dev, `321 go` skips the git pull — you're iterating in the checkout, restart just picks up your local changes.

---

## Lifecycle actions

Four buttons on the service detail page:

- **DEPLOY** — full pipeline: `apt_deps` → `git_pull` → `cpanm` → `migrate` (if `bin/migrate` exists) → `ubic_restart` → `port_check`.
- **UPDATE** — `git_pull` + `cpanm` + `migrate`. No restart. Useful when you want to pull new code and migrate the DB before bouncing the service.
- **MIGRATE** — `bin/migrate` only. For re-running migrations without a code pull.
- **RESTART** — `ubic_restart` + `port_check` only. For picking up env or config changes without touching code.

Each renders per-step output in the same collapsible panel as DEPLOY; failed steps auto-expand.

### Migration convention

Drop a `bin/migrate` executable in the service repo. 321 invokes it with `PERL5LIB=<repo>/local/lib/perl5` and `PATH=<repo>/local/bin:$PATH` so the script can `use` your repo-local modules. Non-zero exit aborts the deploy before restart; the full stdout+stderr appears in the deploy log panel.

Pick whatever migration tool fits — `DBIx::Migration`, `App::Sqitch`, plain `psql -f migrations/<ts>.sql`, a `make migrate` shim. 321 only cares about the exit code.

---

## Troubleshooting

Work top-down — the common failures almost always match the first or second row.

| Symptom | Likely cause | Fix |
|---|---|---|
| `apt_deps` step failed in the deploy log | System package missing | Run the `sudo apt install -y …` command shown in the step's output |
| `cpanm` step failed: `Configure failed for XML-Parser` (or similar XS) | System `-dev` header missing | Add the right package to the YAML's `apt_deps`, redeploy |
| `git_pull` step: `ambiguous argument 'origin/master'` | Repo uses `main`, YAML says `master` | Fix `branch:` in `services/<name>.yml`, restart 321 |
| `ubic_restart` succeeds but service dies immediately | Port already in use | `ss -ltnp \| grep :<port>` — kill the orphan (often left over from pre-ubic runs); `fuser -k <port>/tcp` |
| Browser: `ERR_CERT_AUTHORITY_INVALID` on `*.do.dev` | Browser doesn't trust the mkcert CA | See *Browser trust setup* below |
| VISIT button invisible | Service has `host: localhost` (default when YAML omits `host:`) | Set `host:` in both targets |
| Service starts, port never responds | App crashed during startup | Check `stderr` log tab; common cause is a missing secret or wrong perl version |

**Port conflict diagnosis:**
```
ss -ltnp | grep :<port>
```
If it's not the expected ubic-managed pid, kill it:
```
sudo fuser -k <port>/tcp
```

**When a YAML edit isn't picked up:**
321 caches the service registry in memory. After editing `services/<name>.yml`, restart the daemon:
```
hypnotoad bin/321.pl       # hot-restart (same command re-run)
```

---

## Browser trust setup (dev, mkcert)

Dev SSL uses mkcert. On the dev box:

```
sudo apt install -y libnss3-tools mkcert
mkcert -install
```

For **Chrome** on Ubuntu, use the deb package, not the snap (snap sandboxing breaks NSS trust):

```
sudo snap remove chromium 2>/dev/null; sudo snap remove google-chrome 2>/dev/null
wget -qO- https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list
sudo apt update && sudo apt install -y google-chrome-stable
mkcert -install
```

On any **other client machine**, copy `/home/nige/.local/share/mkcert/rootCA.pem` from the dev box and import it into the client's OS trust store:

- macOS: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain rootCA.pem`
- Linux: `sudo cp rootCA.pem /usr/local/share/ca-certificates/mkcert-dev.crt && sudo update-ca-certificates`

---

## Conventions

- **Hostnames**: live is `foo.do`; dev is `<live>.dev` (e.g. `foo.do.dev`). A single wildcard `*.dev` DNS record (or `/etc/hosts` entry via `321 hosts`) resolves every dev service.
- **Perl deps**: each service repo installs into its own `./local/` tree via `cpanm -L local`. Add `/local/` to every service repo's `.gitignore`.
- **Secrets**: plaintext `secrets/<name>.env`, gitignored. Never commit.
- **Deploys are idempotent**: re-running `DEPLOY` is safe. `git pull` + `cpanm` are no-ops when nothing changed.

---

## Further reading

- `CLAUDE.md` — architecture, endpoint inventory, coding conventions.
- `docs/superpowers/plans/` — implementation plans (internal; not operator-facing).
