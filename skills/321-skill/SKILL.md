---
name: 321-skill
description: Use when creating a new 321-family skill or editing an existing 321-* skill - the content repo and the visible path differ (web.321.do vs ~/.claude/skills symlinks), so new skills land in the wrong repo and edits dirty a repo nobody is watching.
---

# 321-family skills: one home, two repos

## Overview

All `321-*` skills live in the **321 project repo** -
`/home/s3/web.321.do/skills/<name>/` - and become visible to Claude via a
**tracked symlink** at `~/.claude/skills/<name>`. The symlink farm is its own
local git repo. Content changes therefore always belong to web.321.do, no
matter which path you edited through.

## Creating a new 321 skill

Author the skill itself with superpowers:writing-skills (RED-GREEN doctrine).
Place it like this:

```bash
NAME=321-my-topic       # always the 321- prefix, kebab-case
# 1. Content lives in the 321 project
mkdir -p /home/s3/web.321.do/skills/$NAME
# ... write SKILL.md (+ references/, templates/ when heavy) there ...
git -C /home/s3/web.321.do add skills/$NAME
git -C /home/s3/web.321.do commit               # commit 1: the content

# 2. A symlink makes it visible to Claude
ln -s /home/s3/web.321.do/skills/$NAME /home/nige/.claude/skills/$NAME
git -C /home/nige/.claude/skills add $NAME
git -C /home/nige/.claude/skills commit -m "Add $NAME symlink into web.321.do skills"
```

Verify: `test -f ~/.claude/skills/$NAME/SKILL.md` and the skill appears in the
available-skills list.

## Editing an existing 321 skill

Edit through either path - they are the same files. **The dirty repo is always
web.321.do:**

```bash
git -C /home/s3/web.321.do status --short      # your edits are HERE
git -C /home/s3/web.321.do add skills/<name>
git -C /home/s3/web.321.do commit
```

If you edited any `321-*` skill this session, run that status check before
finishing - symlinked edits never show in `~/.claude/skills` status.

## Quick reference

| Thing | Where |
|---|---|
| Skill content (SKILL.md, references/, templates/) | `/home/s3/web.321.do/skills/<name>/` |
| Visibility symlink (tracked, mode 120000) | `~/.claude/skills/<name>` |
| Content commits | web.321.do (has a GitHub origin; push on the session's ship cadence) |
| Symlink commit | `~/.claude/skills` repo (local-only, no remote) |
| House layout for heavy skills | `SKILL.md` + `references/gotchas.md` + `templates/` (see 321-favicon-brand-colours, 321-sql-template) |

## Common mistakes

Both have happened:

- **Creating the skill as a real directory under `~/.claude/skills/`.** It
  works - Claude sees it - so nothing warns you; but the content is now
  committed to the wrong repo and must later be moved, its commit dropped, and
  a symlink retrofitted. Real directories there are for non-321 skills (e.g.
  `raku`); never for `321-*`.
- **Editing a 321 skill and committing nothing.** The edits travel through the
  symlink into web.321.do, whose dirty state nobody is watching; they sit
  uncommitted indefinitely. The `git -C /home/s3/web.321.do status --short`
  check is the fix.
