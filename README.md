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
