# git-deploy-toolkit

One generic `post-receive` hook, shared by every app on a server, plus a
tiny per-app `deploy.conf` (committed in each app's own repo) for the
build/restart commands that actually vary between apps.

Deploy is: `git push deploy main`. The server checks the branch out
in-place over the previous checkout, then runs the app's own
`deploy_build` / `deploy_restart` shell functions if it defines them.

## How it fits together

```
/usr/local/lib/git-deploy/post-receive   <- one shared hook (this repo)
/srv/git/<app>.git                       <- bare repo per app
  hooks/post-receive -> symlink to the shared hook
  deploy.env                             <- server-side: WORKTREE, BRANCH
/var/www/<app>/                          <- worktree (what's actually served)
  deploy.conf                            <- IN THE APP'S OWN REPO, committed
```

- **`deploy.env`** (server-side, one file per bare repo, not in git) just
  says where to check the app out and which branch deploys. It's
  infrastructure, written once by `git-deploy-new`.
- **`deploy.conf`** (in the app's repo, committed alongside the code) is
  where the per-app variations live — build command, restart command,
  anything else. Because it travels with the app's own history, it's
  versioned, reviewable, and identical across servers automatically.

## Server setup (once per VPS)

```sh
git clone <this repo> /opt/git-deploy-toolkit   # or scp it over
cd /opt/git-deploy-toolkit
sudo ./install.sh
```

This installs the shared hook to `/usr/local/lib/git-deploy/post-receive`
and the `git-deploy-new` helper to `/usr/local/bin`. Re-run `install.sh`
after pulling toolkit updates — every app picks up the change instantly
since hooks are symlinks, no per-app reinstall needed.

## Adding a new app (once per app, per server)

```sh
git-deploy-new myapp                        # worktree defaults to /var/www/myapp, branch main
git-deploy-new myapp /srv/www/myapp staging # override worktree / branch
```

This creates `/srv/git/myapp.git`, a worktree dir, `deploy.env`, and
wires up the hook symlink. It prints the `git remote add` command to run
on your dev machine.

## Adding deploy.conf to an app (once per app, any server)

In the app's own repo:

```sh
cp /path/to/git-deploy-toolkit/template/deploy.conf.example deploy.conf
# edit deploy_build / deploy_restart
git add deploy.conf
git commit -m "Add deploy.conf"
```

See `template/deploy.conf.example` for PHP-FPM and pm2 examples. Both
functions are optional — omit either if the app doesn't need it (e.g. a
static site needs neither).

For a long-lived process with its own graceful-reload mechanism (e.g. a
discord.js bot run via ShardingManager, where a full restart means
minutes of total downtime across many shards), see
`template/deploy.conf.graceful-respawn.example` — it only does a full
restart when the process's own entry-point code changed, and otherwise
signals the running process to reload itself. `deploy_build`/
`deploy_restart` can see `$oldrev`/`$newrev`/`$GIT_DIR` to make that
call.

## Triggering deploys from GitHub Actions (optional)

Deploy is always just `git push deploy main` — this only changes *who*
runs that push, from your own machine to a button in GitHub's Actions
tab, without adopting a third-party CI/deploy subscription (Forge,
Envoyer, etc.) or opening the server to inbound access from GitHub's
hosted runners. It works by installing a GitHub Actions **self-hosted**
runner directly on the server, so the credential/access needed to push
to `deploy` never has to leave it.

**Once per server** (not once per app — every app shares this the same
way they share the post-receive hook):

1. Install a self-hosted runner following GitHub's own instructions
   (repo or organization Settings → Actions → Runners → New self-hosted
   runner gives you a registration token and the exact `config.sh`
   command). Register it under a runner group visible to whichever repos
   will use it, and give it the label `git-deploy`.
2. Install it as a service (`./svc.sh install && ./svc.sh start`) so it
   survives reboots.
3. Make sure the OS user running the runner can push to this server's
   bare repos the same way your own deploy user can — simplest is
   running the runner as that same deploy user.

**Once per app**, in the app's own repo:

1. Copy `template/deploy.yml.example` to `.github/workflows/deploy.yml`
   and commit it.
2. Add a repo secret named `DEPLOY_REMOTE_URL` set to the exact value of
   `git remote add deploy ...` from the "Client side" section above (or
   `git remote get-url deploy` if you already added it locally).

Then: Actions tab → "Deploy" → Run workflow → type `deploy` to confirm.

### Locking this down

A self-hosted runner executes whatever workflow code the repos pointed
at it contain — it's real access to the server, not a sandboxed cloud VM
that disappears after the job. A few things matter more than the rest:

- **If any app using this is a public repo, this is the one that
  matters most.** GitHub's own guidance is blunt: don't point a
  self-hosted runner at a workflow that can be triggered by a stranger,
  e.g. `pull_request`/`pull_request_target` from a fork, or `push` to a
  branch anyone can open a PR against. `workflow_dispatch` (what
  `deploy.yml.example` uses) is safe specifically because triggering it
  requires repo *write* access — a fork/PR alone can't fire it. Keep it
  that way: never add another trigger to a workflow that targets the
  `git-deploy` label, on any app.
- **Register the runner scoped to the repos that actually need it**, not
  "all repositories" in an org-wide runner group — an org-wide group
  quietly hands every current and future repo in the org the same
  server access, not just the apps you meant to wire up.
- **Add an approval gate on top of the confirm input.** The template
  references a `production` GitHub Environment — create one (Settings →
  Environments) and add required reviewers there to require a second
  person's (or your own second-factor/second-session) approval before
  the job actually runs. Free on public repos, no-op until configured.
- **Know what OS user the runner runs as.** If it's the same user that
  already pushes to every app's `deploy` remote on that server (see the
  pitfalls in CLAUDE.md — one deploy user across many apps is this
  toolkit's existing pattern), a compromised runner can reach every app
  on the box, not just the one that triggered it. That's a pre-existing
  tradeoff of this toolkit's simplicity, not something the GitHub
  Actions trigger introduces — just don't assume the runner is sandboxed
  to one app if it isn't.
- Leave the runner's own auto-update on, and keep its scoped sudo rule
  (see "sudo for restarts" below) exactly as narrow as any other deploy
  path already requires — the GitHub Actions trigger doesn't need any
  privilege beyond what `git push deploy main` already needed by hand.

## sudo for restarts

`deploy_restart` often needs to restart a systemd unit as root. Scope
this narrowly rather than giving the deploy user full sudo — e.g. in
`/etc/sudoers.d/git-deploy-myapp`:

```
deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart php-fpm-myapp
```

## Persistent per-server files (.env, uploads, etc.)

`git checkout -f` only touches tracked files — untracked files in the
worktree (`.env`, `storage/`, `node_modules/`, etc.) survive every
deploy. Keep those gitignored and drop them in the worktree once by
hand (or via a first `deploy_build` step that creates them if missing).

## Client side

```sh
git remote add deploy ssh://user@host/srv/git/myapp.git
git push deploy main
```

## Tracking your servers (optional)

Nothing in this repo needs to know your real hostnames — `git-deploy-new`
and the hook operate purely locally on whatever server they're run on.
But which host is which, and what's deployed where, isn't derivable from
the code. Copy `servers.example.yml` to `servers.local.yml` (gitignored)
and jot that down there instead of in any tracked file.

## Notes / deliberate simplifications

- Deploys check the branch out **in-place** (no releases/current
  symlink, no rollback machinery) — matches how these apps are deployed
  today. There's a brief window where the worktree has new code but the
  service hasn't restarted yet; for near-zero-downtime or instant
  rollback, this would need atomic release directories, which is a
  bigger change and can be added later if it becomes worth it.
- Only pushes to the configured `BRANCH` trigger a deploy; anything else
  is accepted (so you can still push tags/other branches for backup) but
  ignored.
- The Raspberry Pi (Raspbian) target isn't covered yet — the scripts
  should work as-is (plain bash + git), but haven't been tried there.
