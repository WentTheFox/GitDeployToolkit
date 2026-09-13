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
- **One of the two VPSes is migrated and has three real apps on the
  toolkit:** `fantastick` (a pm2 app, two processes: App +
  QueueWorker), `pennycurve` (a single pm2 process), and `when` (a
  php-fpm-served Laravel app with a Horizon queue-worker systemd unit
  that needs restarting on deploy). All three verified with a real
  `git push deploy main` that ran `deploy_build`/`deploy_restart` and
  left the app running/serving correctly afterward. See
  `servers.local.yml` (gitignored) for exactly which host, its
  worktree/bare-repo paths, deploy user, and local clone paths for every
  app on it — not repeated here since this file is tracked.
- A handful of other apps on that same VPS are intentionally **not**
  being migrated (abandoned or otherwise a no-op, per the user) — see
  `servers.local.yml` for which ones; don't propose migrating them
  without being asked again.
- The toolkit itself is installed on that VPS as a real git clone (not a
  tarball copy), tracking this repo's GitHub remote via a dedicated
  **read-only deploy key** generated on that server (not the user's
  personal/org SSH key) — see the pitfalls section below before
  repeating this on another server. Exact clone path is in
  `servers.local.yml`.
- The second VPS: not migrated yet. The Raspberry Pi target: not
  attempted — per `servers.local.yml`, no app there obviously matches
  the `/var/www` or `/var/node` convention, needs investigation before
  migrating anything.
- Next steps whenever the user wants to proceed: same recipe as the apps
  above, applied one app at a time to the still-unmigrated VPS.

## Pitfalls hit during the first real migration (fantastick)

- **Bare repo ownership.** `git-deploy-new` needs root (it writes under
  `/srv/git` and `/usr/local`), so it's natural to run it via `sudo` —
  but that used to leave the bare repo root-owned. If deploys then run
  as root, `git checkout -f` writes root-owned files into an app
  worktree that's normally owned by the app's actual deploy user, AND
  `pm2 restart <name>` run as root targets *root's own pm2 daemon*, not
  the one actually running the app — so the restart silently does
  nothing to the real process. **Fixed in `git-deploy-new`**: it now
  chowns the bare repo and worktree to `$SUDO_USER` when run via sudo.
  Still push as that user
  (`ssh://<deploy-user>@host/srv/git/<app>.git`), not root.
- **Migrating an app that's already deployed some other way.** The bare
  repo starts empty; the first push needs to seed it from whatever
  commit is already live, e.g. from inside the existing checkout:
  `git push /srv/git/<app>.git HEAD:main`. This is safe as a genuine
  no-op *only* if the worktree is already at that exact commit and
  `deploy.conf` isn't present in it yet (so the hook does the checkout
  but skips build/restart) — don't assume that in general, check both
  conditions before treating a seed push as harmless.
- **Auto-mode production-safety classifier.** Running `install.sh`
  and pushing to a real app's `deploy` remote both got flagged as
  "production deploy" and blocked pending user confirmation — expect
  this every time on a real server, it's not a bug, just plan for the
  confirmation round-trip.
- **Stale GitHub host key.** `root`'s `~/.ssh/known_hosts` on the server
  still had GitHub's pre-2023-rotation RSA key, which made the *new*
  (legitimate) key look like a MITM warning. Verified the offered
  fingerprint against GitHub's published one before trusting it — if
  this comes up again, check
  https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
  rather than assuming either "definitely fine" or "definitely a MITM".
- **Wrong SSH identity for a push.** This machine has multiple GitHub SSH
  identities behind different host aliases in `~/.ssh/config` (personal
  vs. org accounts). A plain `git@github.com:...` remote picked the
  wrong one and got denied; the working alias for WentTheFox-owned repos
  on this machine is `went.github.com`. Not a toolkit issue, just a
  local-environment gotcha worth remembering before assuming a push
  failure means something's wrong server-side.
- **A server checkout with unrelated git history isn't necessarily
  broken — check for a prior intentional rewrite first.** Migrating
  `pennycurve` hit the same "no merge-base with origin" situation as a
  red flag, but this time it was a *known* intentional history
  rewrite from an earlier session (a squashed-history restoration,
  force-pushed to GitHub) that the server's checkout had just never
  picked up. Before assuming corruption or reconciling by hand: check
  whether tracked-file content actually differs
  (`git diff --stat HEAD origin/<branch>` — empty output means it's
  history-only), and check other Claude sessions on the machine for
  context (`grep -rl <keyword> ~/.claude/projects/`) before asking the
  user to explain from scratch. If content matches, a plain
  `git fetch && git reset --hard origin/<branch>` is safe.
- **A broken CI workflow surfacing after a toolkit-only commit is
  probably pre-existing, not caused by that commit.** `pennycurve`'s
  first push after adding `deploy.conf` showed a failed CI run — but
  `gh run list` showed every run back to March had failed the same way,
  in ~5-8s, before any real build step (GitHub had blocked
  `actions/cache@v2`/`checkout@v2`/`setup-node@v2` as deprecated). Check
  run history before assuming a deploy-toolkit change broke something.
- **Check for an existing bespoke deploy script before writing
  `deploy.conf` from scratch.** `when` already had its own
  `setup/post-receive.sh` (a hand-rolled hook on a separate non-bare
  `production` remote with `receive.denyCurrentBranch=updateInstead`) —
  exactly the per-app-hook duplication this toolkit exists to replace,
  and its own app-level `CLAUDE.md` even documented it under a "Deploy"
  heading. It already encoded real, non-obvious decisions (conditional
  composer/pnpm/build based on which files changed, respecting a
  pre-existing manual maintenance window, not letting a build failure
  leave the site stuck down) — porting it into `deploy_build`/
  `deploy_restart` using `$oldrev`/`$newrev` diffing preserved all of
  that instead of reinventing a thinner version. Always check the app's
  own repo (`CLAUDE.md`, `setup/`, `.github/workflows/`, an old
  non-bare `production`-style remote) for this before writing a new
  `deploy.conf`.
- **A build-failure path that must still leave the site running can't
  just `set -e` its way through `deploy_build`.** The shared hook's
  subshell inherits `set -euo pipefail`, so a raw failing command
  inside `deploy_build` aborts immediately — fine for most apps, but
  not for one that brackets `artisan down`/`up` around the build and
  wants a failed build to still restart/come back up. Capture failure
  in an `if cmd; then ok; else FAILED=1; fi` (never bare `set -e`-sensitive)
  and defer the actual `return 1` to the very end of `deploy_restart`,
  using a plain (non-`local`) variable so it survives from `deploy_build`
  into `deploy_restart` — they run in the same sourced shell.

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
