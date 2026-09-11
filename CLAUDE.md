# GitDeployToolkit

## What this is

A generalized push-to-deploy system for the user's own projects, replacing
a pattern where nearly every project has its own hand-copied
`post-receive` hook with minor per-app tweaks. Goal: write the deploy
mechanism once, reuse it everywhere.

Deploy targets: two Debian VPSes (headless) are the primary focus. A
Raspberry Pi running Raspbian is a target too but has not been set up or
tested yet — the toolkit is plain bash + git so it should work there
as-is, but this is unverified.

## Design decisions (and why), for context if resuming

These came from a clarifying round with the user, don't re-litigate them
without a reason:

- **Runtime**: apps run as systemd services (mainly php-fpm) and via pm2
  (Node). Not Docker. `deploy.conf` examples in `template/` reflect this.
- **Per-app variation location**: the user explicitly chose to keep
  build/restart commands **inside each app's own repo** (`deploy.conf`,
  committed), not in server-side config. Rationale: versioned with the
  code, reviewable, identical across servers automatically. Don't move
  this logic server-side.
- **Deploy style**: the user explicitly chose **simple in-place
  checkout** (`git checkout -f` straight into the worktree) over
  atomic release directories + symlink swap. Rollback and
  zero-downtime were traded away deliberately for simplicity — if this
  changes, it's a real architecture change, not a tweak, and should be
  confirmed with the user first.

## Architecture

```
/usr/local/lib/git-deploy/post-receive   one shared hook, installed once per VPS
/srv/git/<app>.git                       bare repo per app
  hooks/post-receive -> symlink to the shared hook (so toolkit updates propagate instantly)
  deploy.env                             server-side only, NOT in git: WORKTREE=, BRANCH=
/var/www/<app>/                          worktree = what's actually served
  deploy.conf                            IN THE APP'S OWN REPO, committed there
```

Hook flow on push (`share/post-receive`): reads `deploy.env` from
`$GIT_DIR` for `WORKTREE`/`BRANCH` → ignores pushes to any other branch →
`git checkout -f` the branch straight into `WORKTREE` (untracked files
like `.env` survive since `checkout -f` doesn't touch them) → if
`$WORKTREE/deploy.conf` exists, sources it and calls `deploy_build()` /
`deploy_restart()` if defined (both optional). Both functions also see
`$WORKTREE`/`$BRANCH`/`$GIT_DIR` and the pushed commit range
(`$oldrev`/`$newrev`) — this is relied on by
`template/deploy.conf.graceful-respawn.example`, which diffs the range
to decide whether to fully restart or send a graceful-reload signal
(discord.js ShardingManager use case). Treat these as part of the
deploy.conf contract, not incidental — don't rename/remove them from
the hook without checking that example.

`bin/git-deploy-new <app> [worktree] [branch]`: one-time per-app,
per-server setup — creates the bare repo, worktree dir, `deploy.env`,
and the hook symlink. Prints the `git remote add` command for the client.

`install.sh`: one-time per-VPS setup (needs root) — installs the shared
hook and `git-deploy-new` under `/usr/local/{lib,bin}`. Re-running it
after a toolkit update is how every app picks up hook changes (they're
symlinks, so this is instant, no per-app reinstall).

Full usage/setup walkthrough is in `README.md` — read that before making
changes, it's the source of truth for the intended UX.

## Current state

- Toolkit is written and passed a local end-to-end smoke test (simulated
  bare repo + push in `/tmp`, verified checkout + `deploy_build` +
  `deploy_restart` all ran). See git log for that commit.
- **Nothing is installed on the real VPSes yet.** No app has been
  migrated to this. That's the natural next step whenever the user wants
  to proceed: `sudo ./install.sh` on a VPS, then `git-deploy-new` per app,
  then add `deploy.conf` to that app's repo and switch its git remote.
- Raspberry Pi / Raspbian target: not attempted.

## Working conventions for this repo

- Git identity is set locally in this repo (`user.email`/`user.name`),
  not globally — the user has no global git identity configured
  machine-wide, don't add one without asking.
- Keep `README.md` and this file in sync with any architecture change —
  README is user-facing usage docs, this file is session-resumption
  context. Update both, not just one.
- Test hook changes the way the existing commit did: a throwaway bare
  repo + worktree under `/tmp`, real `git push`, inspect the resulting
  worktree — rather than trusting `bash -n` alone or guessing.
- Real hostnames/IPs/paths for the user's actual servers never go in
  tracked files. `servers.local.yml` (gitignored; see
  `servers.example.yml`)
  is where that inventory lives — when discussing "which server", check
  that file if it exists rather than asking the user to repeat it, but
  don't put its contents into anything committed.
