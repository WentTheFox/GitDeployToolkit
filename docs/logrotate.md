# Draft: per-repo logrotate definitions

Status: **implemented 2026-09-29** (`share/git-deploy-logrotate`, hook call in
`share/post-receive`, tests in `tests/run.sh`, template
`template/deploy.logrotate.example`); no app has adopted it yet. Two
deliberate differences from the first sketch: the hook pipes the file to
the helper on stdin (a root process never reads a repo-controlled path),
and every stanza must have a non-root `su` (so rotation never runs as
root, which also covers symlink races), not only path checks. `report`
and `adopt`/`remove` subcommands exist; a strict mode was not built.

## Goal

Log retention is a data-retention promise. Today those promises live in
hand-edited files under `/etc/logrotate.d` on each server, so the repo has
no evidence of what it keeps or for how long, and files drift, get shared
between projects, and break unnoticed. Let each repo carry its own
definition (`deploy.logrotate`, next to `deploy.conf`), and have the deploy
install/update it. The file in source control is the evidence; the server
copy is derived from it.

## Shape

- **Opt-in per app.** No `deploy.logrotate` in the repo means the hook does
  nothing about logrotate, ever. Existing hand-made files are untouched.
- **Each project writes its own** — the toolkit ships an example, not
  defaults. No central policy file.
- **Install, don't run.** The hook validates with `logrotate -d` (debug
  mode, changes nothing) and installs the config. Rotation is left to the
  system's `logrotate.timer`. The toolkit never runs `logrotate -f`.
- **Best effort, loudly.** A bad or refused file never fails the deploy
  (same rule as Discord/GitHub recording). It prints a `git-deploy:
  logrotate: ...` line, and `deploy.jsonl`'s `complete` event gets a
  `"logrotate":"installed|unchanged|refused|absent"` field, so a refused
  policy is visible, not silent.

## Why this needs a privileged helper, and why it must be restrictive

`/etc/logrotate.d` is root-owned and logrotate runs as root. The hook runs
as the deploy user, so installing needs a narrow sudo rule (same pattern as
README's "sudo for restarts"): one root-owned script,
`share/git-deploy-logrotate`, allowed via sudoers with no arguments other
than the app name; it reads the definition from the app's bare repo itself
(not from a path the caller supplies).

Because the content comes from a repo and executes as root, the helper is
the security boundary. It must reject:

- any path that isn't under the app's `WORKTREE` (after `realpath`), or the
  deploy user's pm2 logs directory;
- script directives (`prerotate`, `postrotate`, `firstaction`, `lastaction`,
  `preremove`), and `include`;
- a `su` user that isn't the worktree owner or the group-writable dir's
  group (prevents rotating as an arbitrary user);
- stanzas with no retention (`rotate`/`maxage`).

Everything is checked against the parsed file, not by grep-ing lines, and
the helper installs atomically: write temp, `logrotate -d` on that one
file, then `mv` to `/etc/logrotate.d/git-deploy-<app>`. A failing validate
never reaches the directory, so one bad definition can't turn the shared
nightly `logrotate.service` red for everybody.

## Adoption safety

- The helper only writes files it created (first line
  `# managed by git-deploy — edit deploy.logrotate in the repo`). If
  `git-deploy-<app>` doesn't exist it's created; if a hand-made file for
  the same logs exists, that's a manual step: `git-deploy-logrotate --adopt
  <app>` moves the old file to `/root/logrotate.pre-toolkit/` so the same
  log isn't listed in two configs (logrotate errors on duplicates).
- Removing `deploy.logrotate` from the repo does not delete the installed
  file; the hook warns. Removal is explicit (`--remove <app>`).
- Multiple worktrees of one repo (prod + beta) get separate files, named by
  bare repo, and `@WORKTREE@` expands per deploy.

## Evidence for data-retention claims

Implemented: every deploy runs `git-deploy-logrotate report` (no root
needed, so it works even when the install can't) and prints one
`git-deploy: logrotate: retention N days: <path>` line per log. The
`git-deploy` prefix puts them in the public deployment log, where the
webhook masks the worktree like any other path. The same data goes into
`deploy.jsonl` as `"retention":[{"path":..,"days":..}]`. An app with no
`deploy.logrotate` prints a line saying so. Retention is `rotate N` × the
period (daily/weekly/monthly/yearly), capped by `maxage`; size-only
stanzas report "unknown".

Still open: a repo test (or CI step) calling `report` to fail when a
stanza's retention exceeds a stated maximum.

## Implementation plan

1. `share/git-deploy-logrotate`: parse + validate + install (+ `--adopt`,
   `--remove`, `--report`). Unit-tested in `tests/run.sh` with a throwaway
   `/etc/logrotate.d` substitute (`LOGROTATE_D=` override) — including the
   refusals (path escape, postrotate, missing retention) and the
   bad-config-never-installed case.
2. Hook: after the checkout, before `deploy_build`, if the worktree has
   `deploy.logrotate` and the helper is available, call it; never fatal.
3. `install.sh`: install the helper and print the sudoers line (it does not
   edit sudoers itself).
4. README section + CLAUDE.md entry; `template/deploy.logrotate.example`.
5. Rollout, per app, one at a time — see the server inventory for order.
   Start with an app whose current logrotate config is broken or missing
   (the win is visible), then apps with an existing hand-made file
   (`--adopt`), and last apps with nothing.

## pm2 logs (in scope)

Each pm2 app sets its own log paths in its ecosystem file (`out_file`,
`error_file`) or with `--output`/`--error`, pointing inside its worktree
(e.g. `logs/pm2-out.log`, gitignored so `checkout -f` never touches it).
`deploy.logrotate` then rotates them like any other file, with
`copytruncate` (no postrotate needed), and the allowlist stays "under
`@WORKTREE@`". This replaces the shared per-user pm2 logrotate file for
migrated apps.

Caveat: pm2 reads log paths only when a process is *started*. Moving an
app's logs is a one-time `pm2 delete` + start (or `startOrReload` of the
ecosystem file) during that app's adoption, not something a plain
`pm2 restart` picks up. Old logs in `~/.pm2/logs` stay behind for the
shared file to age out. A worked example (pm2.json keys plus the stanza) is
in `template/deploy.logrotate.example`.

## Refused definitions

"Refused" = the helper declined to install a `deploy.logrotate` because it
failed a safety check (path outside the worktree, script directive,
`include`, no retention) or `logrotate -d` rejected it. Default: the deploy
still succeeds, prints `git-deploy: logrotate: refused (<reason>)`, and
records `"logrotate":"refused"` in `deploy.jsonl`. Warn-only is the decided behavior; a strict
mode could be added later if wanted.
