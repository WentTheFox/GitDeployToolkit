# Per-repo scheduled jobs (deploy.cron)

Status: **implemented 2026-10-02** (`share/git-deploy-cron`, hook call in
`share/post-receive`, tests in `tests/run.sh`, template
`template/deploy.cron.example`); no app has adopted it yet. It follows
`docs/logrotate.md` closely — read that for the shared reasoning.

## Goal

Scheduled jobs are part of what an app does (and sometimes of its data
retention: a job that deletes old IP addresses *is* the retention policy),
but today they live in per-user crontabs on each server, where the repo has
no record of them and a rebuilt server silently loses them. A repo can carry
`deploy.cron`; the deploy installs it, and prints and records what is
scheduled.

## Shape

- **Opt-in per app.** No `deploy.cron` = the hook does nothing about cron
  (and says so in its output). Existing crontabs are untouched.
- **cron.d syntax** (minute hour dom mon dow **user** command), because it
  names the user, which is the thing worth reviewing. Installed as
  `/etc/cron.d/git-deploy-<app>`, root-owned, mode 0644. cron re-reads
  `/etc/cron.d` by itself; the toolkit never runs a job or reloads cron.
  (Debian cron ignores a `cron.d` file whose name has a dot, so an app name
  with a dot can't use this.)
- **Best effort, loudly.** A refused or uninstallable file warns and the
  deploy carries on. Every deploy prints `git-deploy: cron: <schedule> as
  <user>: <command>` per job (public summary log, worktree masked), and
  `deploy.jsonl`'s `complete` event gets `"cron":"installed|unchanged|
  refused|unavailable|stale|absent"` and `"cron_jobs":[{schedule,user}]`.
- **Stale warning.** If `deploy.cron` is later deleted from the repo the
  installed file stays (a job silently disappearing is its own hazard), but
  every deploy warns (`"cron":"stale"`) until `git-deploy-cron remove <app>`.

## The privileged helper is the security boundary

Same sudoers pattern as logrotate (`git-deploy-cron install *`). A repo
supplies lines that cron executes, so the helper:

- **never runs a job as root**, and only as users on an allow list —
  `/etc/git-deploy/cron.users` (one per line), default the deploy user who
  invoked sudo plus `www-data`. Those are the identities `deploy.conf`
  already acts as, so this grants nothing new;
- allows only `SHELL`, `PATH` and an **empty** `MAILTO` as environment
  lines, so job output can't be mailed to a repo-chosen address;
- parses and range-checks every schedule field itself (there is no
  `cron -d`), and caps line length and job count;
- refuses a worktree outside `/var/www` / `/var/node` (`cron.roots` to
  change);
- only overwrites files it created, and installs atomically (temp name
  with a dot, which cron ignores, then rename).

## Not running every job twice

Two schedulers for one worktree means every job fires twice — worse than
logrotate's "error on duplicate". So `install` refuses while the worktree
is mentioned in root's or an allowed user's crontab, `/etc/crontab`,
another `/etc/cron.d` file or an `/etc/cron.<period>/` script, and says
which (file and line count, never the line: the hook's output can end up
public). `git-deploy-cron adopt <app> <worktree>` (root, by hand — not in
the sudoers rule) backs those crontabs up to `/root/cron.pre-toolkit/`,
removes the matching lines and moves matching `cron.<period>` scripts
aside, printing what it took out so it can be put in `deploy.cron`. Run it
right before the deploy that installs the file; the jobs are unscheduled
in between. Host-level jobs (certbot, backups) that don't mention a
worktree are never touched.

## Out of scope

- systemd timers and pm2's `cron_restart` (the latter is already in the
  repo's `pm2.json`).
- `at` jobs.
