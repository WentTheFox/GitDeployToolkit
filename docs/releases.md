# Release directories (RELEASES=1)

Status: **implemented 2026-10-22** (`share/post-receive`, `bin/git-deploy-rollback`, `bin/git-deploy-releases-init`, helper changes, tests in `tests/run.sh`); no app has adopted it yet. Below is the design as built; where it differs from the first draft the code wins. Supersedes the
"simple in-place checkout" decision *for apps that opt in*; apps that don't
keep today's behaviour byte for byte. The user has said they will accept
whatever it takes for true zero downtime, which is what authorises this
design; the implementation still gets reviewed before it lands.

## Goal

A deploy must never change what is being served until the new version is
built and ready, and the switch itself must be atomic. Today `git checkout
-f` rewrites the live tree first and `deploy_build` runs on top of it, so
there is a window (a half-written `vendor/`, a stale `public/build`) that apps
cover with `artisan down`.

## Shape

- **Opt-in per bare repo**: `RELEASES=1` in `deploy.env`. No key = in-place
  checkout, unchanged.
- **Layout.** `WORKTREE` keeps meaning "the path the web server and pm2 use"
  but becomes a symlink:

  ```
  <base>/releases/<id>/      one checkout per deploy; id = UTC timestamp (to the millisecond) + 12 chars of the sha
  <base>/shared/             .env, storage/, uploads — survive releases
  WORKTREE -> <base>/releases/<id>      (the symlink, swapped atomically)
  ```

  Keeping `WORKTREE` as the stable path means nginx `root`, pm2 `cwd`,
  logrotate/cron paths and every `deploy.conf` that mentions `$WORKTREE`
  keep working. `<base>` defaults to `<WORKTREE>.d` (override `RELEASES_DIR=`).
- **Shared state is declared in the app's own `deploy.conf`**, not in
  server config (same rule as build/restart commands): a `SHARED=(.env
  storage)` array; the hook links each into the new release before
  `deploy_build`. Untracked files today survive because `checkout -f` never
  touches them; here they must be linked explicitly.
- **Hook flow** (`share/post-receive`, when `RELEASES=1`):
  1. Check the commit out into a fresh `releases/<id>` (a throwaway index,
     so the bare repo's HEAD stays put).
  2. Link `SHARED` entries, write `.git-deploy-commit`.
  3. `deploy_build` with `cwd` = the new release, `$RELEASE` set to it.
     `$WORKTREE` still points at the *old* release, which keeps serving.
     A failure here aborts: the symlink was never touched, so the old
     release is live and nothing needs undoing.
  4. Swap: `ln -s` to a temp name, then `mv -T` over `WORKTREE` (a rename,
     atomic).
  5. `deploy_restart` (php-fpm reload, `pm2 reload`, Horizon terminate).
     Failure here leaves the new release live and is reported failed, like
     today. Rolling back is one command, below.
  6. Prune to the newest `KEEP_RELEASES` (default 5), never the live one or
     the previous one.
- **Rollback**: `git-deploy-rollback <app> [release-id]` re-points the
  symlink to the previous (or named) release and runs the **`deploy_rollback()`**
  from that release's `deploy.conf`. It deliberately never runs `deploy_restart()`:
  that usually migrates, and a rollback must not change the schema (fail
  closed: no `deploy_rollback()` = swap only, with a message). Records a
  `rollback` event in `deploy.jsonl`. Takes the webhook's per-app lock, so it
  can't race a button deploy. It does not undo migrations.
- **Contract for `deploy.conf`**: `$WORKTREE`, `$BRANCH`, `$GIT_DIR`,
  `$oldrev`, `$newrev` still exist with the same meaning; `$RELEASE` is new.
  `$oldrev..$newrev` diffing (graceful-respawn example) keeps working. Code
  that assumed `cwd == $WORKTREE` during build is the one thing that changes:
  during `deploy_build` `cwd` is `$RELEASE`.
- **Concurrency**: button deploys are serialized per app by the webhook's
  `flock`, and `git-deploy-rollback` takes the same lock. A manual push has
  never taken it (true in-place too); two overlapping pushes each build their
  own release, and the last swap wins.

## Worked example: Laravel with a read-only migration window

Agreed with the first app that wants this (2026-10-22). It is app-side
`deploy.conf` only, on top of the flow above; `SHARED=(.env storage)`.

- `deploy_build` (cwd = `$RELEASE`, old release still serving): composer,
  `optimize`, frontend build, and **last** `touch storage/framework/readonly`.
  Plain `touch`, no PHP, so it works even if code and vendor mismatch.
  `storage` is shared, so both releases see the flag; the old release ignores
  it and the new one honours it right after the swap.
- swap (toolkit).
- `deploy_restart`: `migrate --force` first, then php-fpm reload, queue
  workers, SSR, a GET health check, and only then remove the flag. A failed
  migrate or health check leaves the flag **on** and the deploy failed.
  Nothing before the swap can fail with the flag set, so no cleanup trap.
- Per-release (built in `$RELEASE`, which is the point): `public/build`,
  `bootstrap/ssr`. Shared: `.env`, `storage`.

## What this does not fix (still the app's job)

- **php-fpm opcache.** After the swap, either `opcache.revalidate_path=1` or a
  graceful `systemctl reload php*-fpm` is needed. The deploy user has no
  sudoers rule for that today; `install.sh` prints a suggested one.
- **Migrations.** They run against one database shared by the old and new
  release. They must be expand-only relative to the previous release (add
  nullable/defaulted columns, drop in a later release). A read-only window
  around `migrate` is app-level (see the SledgeHammerTime plan), not toolkit.
- **Workers draining.** Horizon/queue workers on the old code finish jobs
  against the new schema; same expand-only rule.
- **pm2 restarts.** `pm2 reload` is graceful only for cluster mode / apps that
  send `ready`; a fork-mode process still has a gap. See "Containers" for
  the blue/green option.

## Files and features that assume a fixed worktree

Each needs a deliberate decision before implementing:

| Thing | Today | With releases |
| --- | --- | --- |
| `.git-deploy-commit` | written into the worktree | written into each release; reading it through `WORKTREE` just works |
| `deploy.logrotate` helper | refuses paths outside the worktree | policy names the symlink; logs may be in the release or in `<base>/shared`, which the helper derives from where the symlink points (never from the caller). A symlink out of both is still refused. Done |
| pm2 `out_file`/`error_file` | inside the worktree | same: point them at `shared/` |
| `deploy.cron` uniqueness check ("worktree already scheduled elsewhere") | compares worktree paths | compares `WORKTREE` (the stable symlink), not the release dir. Done |
| Leftover-`.git` warning/cleanup | checks `$WORKTREE/.git` | checks the new release; `git-deploy-releases-init` carries a leftover `.git` into the first release |
| Discord/GitHub notices | mask `$WORKTREE` | the default `<base>` is `$WORKTREE.d`, so the existing prefix masking covers it; a custom `RELEASES_DIR` is masked explicitly. **Not covered by a test through the webhook**: check a public deployment log once before opting in an app with a public repo |

## Migrating an existing app

`WORKTREE` is a real directory today and a rename cannot replace a non-empty
directory, so the **one-time conversion has a sub-second gap** (move the
directory into `releases/`, create the symlink). That is a `git-deploy-releases-init
<app>` command run by hand, with the user's confirmation per app, ideally at a
quiet moment. After that, every deploy is atomic. Alternative with no gap: point
the web server and pm2 at a new path (`<base>/current`) and leave `WORKTREE`
alone; costs a config change on the server per app.

## Containers (evaluated, not proposed for phase 1)

Asked about 2026-10-22: mild containerization is acceptable if it helps.
It doesn't buy the file swap (release directories already do) or php-fpm
(graceful reload is lossless). It costs a daemon per VPS, memory, shared-volume
ownership problems, and rewriting `deploy.conf`s built around systemd + pm2.

Where it would help, in order of value:

1. **SSR (or any fork-mode pm2 process) without a gap**: start the new process
   on a second port, health-check it, switch the upstream/app config, stop the
   old one. This is blue/green for one component and needs no container; a
   systemd template unit or a second pm2 name does it. A container is only
   worth it if that process needs its own runtime version.
2. **Per-release runtime versions** (a release needing a different PHP/Node).
3. **Old and new code serving in parallel behind a proxy** for a risky
   migration. The read-only window covers this adequately for now.

Revisit if phase 1 ships and the SSR gap or a runtime-version need is a real
problem. The "not Docker" decision in `CLAUDE.md` stays until then.

## Phasing

1. `RELEASES=1` flow, `git-deploy-rollback`, pruning, `git-deploy-releases-init`,
   tests in `tests/run.sh` (swap is atomic, failed build leaves the old release
   live, rollback, pruning keeps live + previous, in-place apps unaffected).
   Break each behaviour on purpose once to prove its test fails.
2. Optional blue/green helper for SSR if still needed.
3. Update README and `CLAUDE.md` (architecture and the in-place decision) in
   the same change as phase 1.
