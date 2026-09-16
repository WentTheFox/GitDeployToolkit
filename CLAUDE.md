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

## Optional: GitHub Actions deploy trigger

`template/deploy.yml.example` (copied per-app into that app's own
`.github/workflows/deploy.yml`, same relationship `deploy.conf.example`
has to `deploy.conf` — a workflow file can't live centrally, GitHub only
looks inside the repo it belongs to) gives a `workflow_dispatch`-only
"Deploy" button that just runs `git push deploy main` from a
**self-hosted** runner living on the server itself. Deliberately not:
GitHub-hosted runners + an SSH secret (would need inbound network access
to the server and a credential leaving it), or push-to-main auto-deploy
(deploying briefly takes the app down, so it should always be a
deliberate in-the-moment click, never automatic off a merge — matches
`when`'s own CLAUDE.md rule about never pushing to `deploy` without
explicit go-ahead). One runner, labeled `git-deploy`, per **server** —
not per app — registered once and shared by every app's workflow on that
box, mirroring the toolkit's own "one hook shared by every app" design.
See README.md's "Triggering deploys from GitHub Actions" for the actual
setup steps (this is server-side runner registration, so — like
`install.sh` — it can't be done from within this repo, only documented).

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
- **Two more apps on that first VPS are now migrated:** `Celestia` (a
  pnpm/turbo monorepo, Next.js served via a single fork-mode pm2
  process, `pm2 reload` on deploy) and `Luna` (a php-fpm-served Laravel
  API with no queue worker or SSR process). Both verified with a real
  `git push deploy main`. See `servers.local.yml` for exact paths and
  the pitfalls this migration surfaced (Luna's `storage/logs/
  laravel.log` permission gap and a new artisan down/up bracket).
- **`when`'s deploy.conf got a follow-up fix weeks after its own
  migration was verified clean**: a peer session found a queue-worker
  log-permission gap (same bug class as SledgeHammerTime/Luna, just on
  a file the original migration check never exercised) that had been
  silently failing a background job for ~2 weeks. Fixed live and made
  durable in `deploy.conf`. See the dedicated pitfalls section below —
  this bug class isn't a one-time migration check.
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
- **The second VPS is now migrated too, with one app on it so far:** a
  Laravel app with a Horizon queue worker and a pm2-managed SSR process
  (same install-a-dedicated-deploy-key-and-clone approach as the first
  VPS). Verified with a real `git push deploy main`. A sibling app on
  that same VPS sharing the same codebase but deployed to a separate
  worktree is **not** migrated — left untouched. See `servers.local.yml`
  for exactly which apps and paths.
- The Raspberry Pi target: not attempted — per `servers.local.yml`, no
  app there obviously matches the `/var/www` or `/var/node` convention,
  needs investigation before migrating anything.
- Next steps whenever the user wants to proceed: same recipe as the apps
  above, applied to whatever's next.

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
- **`deploy_build`/`deploy_restart` run as the deploy user (e.g. the git
  user pushing over SSH), not the web server user — files they create
  or regenerate (Laravel's `storage/`, `bootstrap/cache/`, framework
  caches, log files) can end up owned/moded so the web server user
  can't write to them, and a web-server-triggered exception then fails
  to even log itself: Laravel's generic "Server Error" response comes
  back with **nothing in `storage/logs/laravel.log`**, because writing
  that log entry is exactly what failed. This looks like a mysterious
  unrelated bug (a real API endpoint 500ing for no visible reason) when
  it's actually just a permissions gap. Caught on `sledgehammertime`
  right after migrating it — a CI job hit a real 500 on a live route —
  but the root cause **predated the migration**: `storage/logs/
  laravel.log` was owned `<deploy-user>:<deploy-user>` mode `644` since
  months before the toolkit ever touched this app (verified via the
  file's birth time), the web server user wasn't even in that group,
  and the old hand-rolled post-receive script ran as the same deploy
  user and would have hit the identical gap. The toolkit didn't cause
  it — it's a latent bug in *any* deploy mechanism where a different
  user than the web server regenerates these directories, that this
  migration's redeploy happened to surface. Diagnose with
  `sudo -u <web-user> test -w <file>` directly (don't trust `ls -la`
  group names alone — verify actual write access). Fix: `chgrp -R
  <web-user-group> storage bootstrap/cache`, `chmod -R ug+rw` on both,
  and `chmod g+s` on their directories so new files inherit the right
  group going forward; consider adding this as a `deploy_build` step
  (after `artisan optimize`) for any Laravel app on this toolkit, not
  just a one-time manual fix, so a deleted/regenerated log file doesn't
  silently regress it. When a live app starts 500ing on a route right
  after a migration with no obvious code cause, check this class of
  issue before assuming it's an application bug — and check whether it
  predates the migration (as this one did) before blaming the toolkit.
- **Every app migrated so far had the same leftover old-deploy pattern**
  — not just `when` (see above): a stale `production` git remote in the
  local clone pointing straight at the worktree, `receive.
  denyCurrentBranch=updateInstead` still set in the worktree's own
  `.git/config` on the server, a dangling `.git/hooks/post-receive`
  symlink to a now-superseded bespoke script, and that script still
  sitting in the app's repo. None of this breaks anything by staying
  (nothing pushes to that non-bare repo directly once `production` is
  removed from the local clone), but it's confusing dead weight. Treat
  checking for and cleaning this up as **part of the migration**, not an
  optional follow-up — see the checklist below.

## Post-migration cleanup checklist (do this for every app, not just when asked)

After `deploy.conf` is written and the first real deploy through the
toolkit is verified working, check for and clean up the app's old
deploy mechanism if one existed:

1. In the app's local clone: `git remote -v` — remove any `production`
   (or similarly named) remote pointing straight at a worktree path.
2. On the server, in that worktree's own `.git`: check
   `git config --get receive.denyCurrentBranch` and
   `ls -la .git/hooks/post-receive` — unset the config and remove the
   hook symlink if they're relics of the old push-directly-to-worktree
   setup (this is a *different* `.git` from the toolkit's bare repo
   under `/srv/git`, easy to forget it's even there).
3. In the app's repo: delete the old hand-rolled deploy script the
   symlink pointed to (e.g. `setup/post-receive.sh`), and update
   `CLAUDE.md`/`README.md` if either documents the old flow — don't
   leave docs describing a mechanism that no longer exists.
4. Commit and push that removal to `origin`, then deploy it through
   `deploy` too, so the server's checkout matches — confirm with the
   user first, same as any other push to `deploy` for that app.
5. Note in `servers.local.yml` that this cleanup is done (or still
   pending) for that app, so it isn't silently re-discovered later.

As of this note: `when`, `fantastick`, `pennycurve`, `Celestia`, and
`Luna` have all been fully cleaned up this way — see `servers.local.yml`
for exactly what was removed on each. Run this checklist on every
future migration.

## Pitfalls hit giving a second worktree of the same app its own deploy target

`sledgehammertime`'s beta/staging copy (same repo, same `deploy.conf`,
separate worktree on the same server) needed its own pm2 SSR process and
its own Horizon queue worker so it wouldn't collide with production's —
this class of setup (one app, two independently-pushable environments on
one host) surfaced two real bugs, neither obvious in advance:

- **`pm2 start ecosystem.json --name X` does not rename the process.**
  PM2 silently ignores `--name` when the target file has its own `apps`
  array with a `name` already baked in — it just matches (and
  restarts!) whatever process already has that baked-in name, or starts
  a new one under the FILE's name, not your override. Confirmed the
  hard way: beta's first deploy under a distinct `PM2_SSR_NAME`
  silently restarted **production's** already-running process instead
  of starting its own. Fix: for the first-start path only, build the
  `pm2 start` invocation from plain CLI flags mirroring the ecosystem
  file's fields (`--interpreter`, `--cron-restart`, `--wait-ready`,
  `--time`, the script + args) instead of passing the file. Restarting
  an already-uniquely-named existing process by name is unaffected and
  was never the problem.
- **A framework's own "SSR URL" config often only controls the
  client-side call-out, not what port the SSR server itself binds.**
  Laravel Inertia's `INERTIA_SSR_URL` config (and likely equivalents in
  other frameworks with a similar split HTTP-render-server pattern) is
  read by the PHP side to know where to send render requests — it is
  **not** passed down to the actual Node process that binds a port.
  `@inertiajs/vue3/server`'s `createServer()` defaults to a fixed port
  (13714) unless the app's own SSR entry file explicitly forwards a
  `port` option, typically from a *build-time* env var (Vite inlines
  `import.meta.env.VITE_*` at build time, so this must be set in each
  worktree's own `.env` **before** that worktree's build runs — an
  after-the-fact `.env` edit does nothing until the next `artisan
  optimize`/build re-reads it). Getting this wrong looks exactly like
  the pm2 naming bug from the outside (both processes fighting, endless
  restarts) but needs a real source change, not just deploy.conf/env
  config — check both the framework's docs AND its actual server
  package source (`grep` for the default port literal) before assuming
  a config var alone controls it. Both apps briefly crash-looped
  (`EADDRINUSE`) fighting over the same port before this was traced;
  `pm2 describe <name>` showing `unstable restarts` climbing with a
  fresh pid each check is the signal to look for.
- **When two worktrees share one `deploy.conf`, default every
  override to production's exact existing behavior, and verify that
  by actually deploying to production first**, before touching the
  second worktree at all — every naming/port change here was designed
  so an unset override falls back to production's pre-existing literal
  values, and each was confirmed as a true no-op on production (same
  process name, same restart behavior, zero content diff) before beta
  was touched.

## Pitfalls hit migrating an app with no prior maintenance-mode bracket at all

`Luna`'s old hand-rolled `post-receive.sh` never wrapped its deploy in
anything like `artisan down`/`up` — it just ran composer/artisan
commands directly against the live, still-serving site. This had
apparently been fine for years, but the very first real deploy through
the toolkit produced a handful of transient live 500s: a request landed
mid-`artisan optimize`/`migrate` and saw a half-regenerated
`bootstrap/cache`. Not a toolkit bug, just a pre-existing race that
happened to get hit. Fix: add the same `artisan down --retry=N` /
`artisan up` bracket already used by `when`/SledgeHammerTime, with `up`
always running even if a build step failed (same `FAILED` idiom as the
build-failure-handling pitfall above) — don't assume an app without a
bracket in its old script doesn't need one; check whether the old
script predates the app's queue-worker/heavier-build era.

Separately, the **storage/bootstrap-cache permission fix from the
SledgeHammerTime pitfall is a directory-level check and can still miss
individual files.** Luna's `storage/` and `bootstrap/cache/`
directories themselves were already `www-data`-group and
group-writable (the initial per-app pitfall check passed), but one
specific pre-existing file inside — `storage/logs/laravel.log`, dating
back to 2021 — was still owned by the deploy user and not writable by
`www-data`, because `chgrp -R`/`chmod -R` had never actually been run
against it before (it predates any of this tooling). A live request hit
a real exception (an unrelated Redis-extension-resolution issue,
itself pre-existing) and couldn't log it, looking identical to the
SledgeHammerTime case from the outside. Check individual long-lived log
files with `sudo -u <web-user> test -w <file>` specifically, not just
the containing directory's group/mode — and don't assume a Laravel
app is safe just because `storage/`/`bootstrap/cache/` pass the
directory-level check.

## This permission-gap bug class can resurface even after an app's own migration was verified clean

`when` was migrated first (see above) and its first real deploy through
the toolkit checked out clean — but weeks later, a peer Claude session
working in `when`'s own repo (name `when-81`) found `when-horizon.service`
(runs as `www-data`) silently failing every
`App\Jobs\RecomputeShareLinkAvailability` job for about two weeks:
`storage/logs/availability.log` was owned by the deploy user and
unwritable by `www-data`, so the job's own `Log::channel(...)->info()`
call threw and killed it before it could do anything else. Root cause:
`when`'s old `post-receive.sh` (faithfully ported into its `deploy.conf`,
see the entry above) also ran entirely as the deploy user and never
touched this particular log channel's file, so the original migration's spot-check
never exercised it — the gap was real from day one, just not on a file
anyone happened to check. Fixed live (`chgrp -R www-data` +
`chmod -R ug+rw` + `chmod g+s` on `storage`/`bootstrap/cache`, same as
SledgeHammerTime/Luna), retried all 21 queued failed jobs (all
succeeded), and added the same reassertion as a permanent `deploy_build`
step in `when`'s `deploy.conf` so it can't regress again — verified
writable after a real subsequent deploy, not just the manual fix.
Lesson: this bug class isn't a one-time migration check, it's a standing
risk for **every** app on this toolkit where the deploy user differs
from the web/queue user, especially for log channels/files that are only
written on a specific, infrequent code path (a failing background job
here vs. a routed HTTP exception on SledgeHammerTime/Luna) — a clean
first deploy doesn't rule it out for files that deploy never happened to
touch. Consider auditing every already-migrated Laravel app's `storage/`
tree for individually-owned files rather than waiting for another job to
fail first.

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
- Real hostnames/IPs/paths for the user's actual servers are **always**
  sensitive — never go in tracked files, unconditionally, whether or not
  any app on that server is flagged `sensitive`. `servers.local.yml`
  (gitignored; see `servers.example.yml`) is where that inventory lives
  — when discussing "which server", check that file if it exists rather
  than asking the user to repeat it, but don't put its contents into
  anything committed.
- An app entry in `servers.local.yml` can additionally be marked
  `sensitive: true`. This is about the **app itself**, on top of the
  always-sensitive server names above: its name must never appear in
  any tracked or committed file, anywhere — not just this toolkit's own
  CLAUDE.md/README, but commit messages, PR descriptions, code
  comments, anything that ends up in source control (this repo's or the
  app's own). Don't launder this into an oblique-but-still-identifying
  reference either — naming which server it's on (itself already
  forbidden) or any other detail that narrows it to one of a handful of
  candidates still identifies it. If a tracked file needs to mention
  that work touched a sensitive app at all, say so with no identifying
  detail whatsoever, or better, don't mention it. The real name is fine
  in `servers.local.yml` itself (gitignored) and in conversation with
  the user.
- `servers.local.yml`'s freeform notes will eventually contain a colon
  (a URL, a ratio, a label) — as a bare `- text` list item, `: ` is a
  mapping-key indicator, not prose, and silently produces invalid YAML
  (this actually happened — several notes broke the file this way and
  went unnoticed until asked to validate). Write any note that spans
  multiple lines, or contains a colon at all, as a block scalar instead
  (`- >-` on its own line, text indented underneath). After editing this
  file, validate it: `python3 -c "import yaml;
  yaml.safe_load(open('servers.local.yml'))"` (needs `pyyaml` — a
  throwaway venv is fine, don't install it into any project
  environment).
