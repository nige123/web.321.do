# Dedicated "Add Subsystem" Page — Design Spec

## Goal

Move the inline "Add Subsystem" form off the dashboard onto its own page (`/ui/add`). The new page has room for a worked example, helpful tips, and post-registration instructions so operators know exactly what to do next.

## Audience

Developers who know the 321.do conventions but need a quick reference — with enough context that someone new won't be lost.

## What changes

### New: `/ui/add` page

A two-column layout (single column on narrow screens).

**Left column — Registration form**

Fields:

| Field | Default / auto-fill | Notes |
|-------|-------------------|-------|
| NAME | — | `group.service` format, validated inline |
| REPO | Auto-fills `/home/s3/<group>` when name is entered | Operator can override |
| BRANCH | `master` | Pre-filled, editable |
| DEV HOST | Auto-fills `<group>.do.dev` from name | |
| DEV PORT | — | Required |
| LIVE HOST | Auto-fills `<group>.do` from name | |
| LIVE PORT | Same as dev port when entered | Operator can override |

The form no longer asks for `bin` or `runner` — these come from the `.321.yml` manifest in the service repo.

CREATE button at the bottom. On success: redirect to `/ui/service/<name>` with a toast confirming creation.

Validation rules:
- Name must match `^[a-z0-9]+\.[a-z0-9]+$`
- Name must not already exist (check against `/services` on submit)
- At least one port required

**Right column — Guidance**

Three sections:

**1. Example**

A filled-in version of the form showing a realistic registration, e.g.:

```
NAME:       pizza.web
REPO:       /home/s3/web.pizza.do
BRANCH:     master
DEV HOST:   pizza.do.dev     DEV PORT: 9500
LIVE HOST:  pizza.do         LIVE PORT: 9500
```

One-liner per field explaining the convention:
- Name is `group.service` — the group drives the ubic tree and repo path
- Repo is where the code lives (or will live after clone)
- Dev host gets a `.dev` suffix; mkcert handles SSL locally
- Pick an unused port — check the dashboard for what's taken

**2. What's next?**

Numbered steps after registration:

1. **Prepare the repo** — make sure it exists and contains a `.321.yml` manifest at the root. Minimum manifest:
   ```yaml
   name: pizza.web
   entry: bin/app.pl
   runner: hypnotoad
   ```
   See the [Service Repo Contract](../../CLAUDE.md#service-repo-contract) for the full schema.

2. **Install the service** — from the 321.do machine:
   ```
   321 install pizza.web
   ```
   This clones the repo (if needed), installs Perl deps, sets up ubic + nginx + SSL, and starts the service.

3. **Set secrets** — if the manifest declares `env_required`, set them from the service detail page before deploying.

4. **Check the dashboard** — the service should appear with a green status LED.

**3. Tips**

- Port allocation: check the dashboard for ports already in use before picking one.
- Naming: the group name (`pizza`) is reused for the ubic service tree, repo directory, and nginx config. Keep it short and lowercase.
- Dev parity: dev targets get the same nginx + SSL setup as live via mkcert. The `.dev` host suffix is just a convention — the important thing is that it resolves via `/etc/hosts` (run `321 hosts` after install).
- Branch: most services use `master`. Use `main` if that's what the repo uses — 321 doesn't care which, it just needs to match.

### Modified: Dashboard

Replace the inline "ADD SUBSYSTEM" form card (the `<div class="add-subsystem-form">` block in `loadServices()`) with a simple link card:

```
+ ADD SUBSYSTEM
```

Clicking it navigates to `/ui/add`. Same visual weight as a service card but just the title and a subtle arrow or border treatment — no form fields.

### Unchanged

- `POST /services/create` endpoint — identical behaviour, identical JSON body
- `Deploy::Config::save_service` — unchanged
- CLI `321 install` — unchanged
- No new backend routes beyond `GET /ui/add` (which just renders the template)

## Data flow

```
/ui/add page
    |
    |  operator fills form, clicks CREATE
    v
POST /services/create  (JSON body: name, repo, branch, targets)
    |
    |  saves services/<name>.yml, generates ubic, git commits
    v
redirect to /ui/service/<name>  (toast: "pizza.web created")
    |
    |  operator follows "What's next?" steps manually
    v
CLI: 321 install pizza.web  (clone, cpanm, ubic, nginx, SSL, start)
```

## Files affected

- `bin/321.pl` — new `GET /ui/add` route + `add_subsystem` template, modify dashboard template (replace inline form with link card), add page CSS
- No new Perl modules
- No new test files needed (the `/services/create` endpoint is already tested; the new page is template-only)
