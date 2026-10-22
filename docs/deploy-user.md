# A dedicated deploy user

Until now the "deploy user" on a server was the admin's own login: full
`NOPASSWD:ALL` sudo, owner of the pm2 daemon, the bare repos and the
worktrees, and the account every `git push deploy` and the webhook listener
ran as. Anyone who could push to an app, or steal the SSH key / GitHub token
that deploys, was effectively root.

This splits the roles. A server gets one unprivileged account (call it
`deploy`) that owns everything the toolkit touches and may run **only** the
root commands deploys need. The admin login stays an admin login.

## What the deploy user can do as root

`install.sh --deploy-user deploy` writes `/etc/sudoers.d/git-deploy`
(validated with `visudo -cf`, regenerated on every run, so edit
`/etc/git-deploy/*`, not that file):

```
deploy ALL=(root) NOPASSWD: \
    /usr/local/lib/git-deploy/git-deploy-service *, \
    /usr/local/lib/git-deploy/git-deploy-fixperms *, \
    /usr/local/lib/git-deploy/git-deploy-logrotate install *, \
    /usr/local/lib/git-deploy/git-deploy-cron install *
deploy ALL=(www-data) NOPASSWD: ALL
```

Nothing else: no `systemctl`, `chmod`, `chgrp`, `find`, shell or editor. Each
helper takes arguments a pushed repo controls, so each validates its own:

| Helper | Replaces in `deploy.conf` | Allowed |
|---|---|---|
| `git-deploy-service <action> <unit>.service` | `sudo systemctl restart/reload …` | only actions and unit patterns listed in `/etc/git-deploy/services` (root-owned) |
| `git-deploy-fixperms <worktree> <path>...` | `sudo chgrp -R`, `chmod -R ug+rw`, `find … -exec chmod g+s` | group := web group, `ug+rw`, dirs setgid, under a worktree inside `/etc/git-deploy/fixperms.roots` (default `/var/www`, `/var/node`); never follows symlinks, except a release's link into its own `shared/` |
| `git-deploy-logrotate`, `git-deploy-cron` | (already helpers) | unchanged |

Why helpers rather than sudoers lines: a sudoers `*` matches spaces, so
`chmod -R * storage` is `chmod -R 4777 /etc/shadow` away from root, and
`find -exec` and `systemctl edit` are root shells by design. A static rule per
literal command works but cannot express "recursive, but only below this
worktree". Fixed behavior in a validated, tested script can.

**The `www-data` rule is code execution as `www-data`, on purpose.**
`artisan`, `composer`, `pnpm`, `nice` and `find` can each run arbitrary
commands, so listing them would only look like a restriction. A deploy ships
code that `www-data` runs anyway. It is not root, and `www-data` has no sudo.

What this does **not** protect against: someone who can push to an app can
still run code as the deploy user and as `www-data` (that is what a deploy is).
It limits the blast radius to those two accounts, away from root, the admin's
files and other users.

## `pm2` for everyone else

pm2 keeps one daemon per OS user and silently starts one on any command. With the
apps in `deploy`'s daemon, a bare `pm2 list` as the admin login would start a
second, empty daemon (and a `~/.pm2`) and show nothing; this happened once while
migrating. `install.sh --deploy-user` therefore installs `/usr/local/bin/pm2`, a
wrapper that runs the real pm2 as the deploy user for everyone else
(`sudo -n -u deploy -H /usr/bin/pm2 ...`) and straight through when already
running as `deploy`. It is a wrapper rather than an alias because an alias
applies only to interactive shells, not to `ssh host pm2 ...` or scripts. If
your current directory is not readable by `deploy` (an admin's 0750 home), it
runs from `/` and says so. It never replaces a `/usr/local/bin/pm2` it did not
write. The real binary stays reachable by its own path.

## Rejecting pushes from anyone else

`/etc/git-deploy/user` holds the deploy user's name. The shared `pre-receive`
hook (symlinked into every bare repo by `install.sh` and `git-deploy-new`)
refuses any push made as another user *before any ref moves*, naming the
correct remote:

```
git-deploy: push REJECTED — you pushed as 'admin', but this server deploys as 'deploy'.
  Fix your remote:  git remote set-url deploy ssh://deploy@<this-host>/srv/git/myapp.git
```

So a forgotten clone still pointing at the old admin login fails loudly. The
bare repos are also owned by `deploy`, so git itself usually stops the old
login first, with `fatal: detected dubious ownership in repository at
'/srv/git/<app>.git'` and no hint about the right URL. Either way the push
fails and nothing deploys; the hook's message only appears where the old user
can still open the repo (a shared group, or a repo migrated without the
chown). The GitHub webhook path does not push and is unaffected.

## Migrating a server (runbook)

Do one server at a time, in a maintenance window you are happy with: every
pm2 process restarts once, and each app is briefly owned by someone mid-move.
`OLD` is the current admin/deploy login, `deploy` the new user.

1. **Create the user** (no password, no sudo, in `www-data` so it can read what
   the web server writes):
   `adduser --disabled-password --gecos '' deploy && usermod -aG www-data deploy`.
   Node, pnpm, composer and php are system-wide on these servers; check
   `sudo -u deploy bash -lc 'command -v node pnpm composer php pm2'`.
   Copy the `authorized_keys` that push today to `~deploy/.ssh/`.
2. **Install**, as root: `./install.sh --deploy-user deploy` (via
   `git-deploy-update` afterwards). Fill `/etc/git-deploy/services` from the
   units the apps' `deploy.conf` restart (`reload php*-fpm.service`,
   `restart <app>-horizon.service`). Nothing is enforced yet: `OLD` still has
   full sudo and still owns everything.
3. **Port every `deploy.conf`** (in each app's repo) to the helpers:
   `sudo -n /usr/local/lib/git-deploy/git-deploy-fixperms "$WORKTREE" storage bootstrap/cache`
   (and `vendor`), `sudo -n …/git-deploy-service restart X.service`. Push those
   as `OLD` while that still works. A `deploy.conf` that still calls
   `sudo systemctl` or `sudo chmod` fails under `deploy` with a sudo error.
   Update `deploy.cron` entries that run as `OLD` to run as `deploy`, **and
   every `su OLD OLD` line in `deploy.logrotate`** (pm2 log stanzas) to
   `su deploy deploy`. A stale `su` is not a deploy failure: the helper accepts
   it, and logrotate only fails at night, when the old login can no longer
   write the now `deploy`-owned log directories. Check with
   `sudo -u OLD test -w <log dir>` for every stanza after the ownership move.
4. **Move ownership** (per app, then the server-wide pieces):
   - `pm2 save` and `pm2 kill` as `OLD`; `systemctl disable pm2-OLD`; as
     `deploy` start the apps from their `pm2.json`/ecosystem files, `pm2 save`,
     then `pm2 startup systemd -u deploy --hp /home/deploy` and run what it
     prints. Processes that were started by hand need their start command.
   - `chown -R deploy:deploy /srv/git/*.git` and each worktree. Where a worktree
     has `www-data`-owned `storage/` etc., chown only what `OLD` owned
     (`find <wt> -user OLD -exec chown deploy {} +` with `-xdev`), then run
     `git-deploy-fixperms` once per Laravel app.
   - **Release directories (`RELEASES=1`):** also re-own `<worktree>.d/` (releases
     and `shared/`) and the worktree symlink itself (`chown -h`), and make the
     directory that *contains* the worktree symlink (`/var/www`, `/var/node`)
     writable by `deploy`: the swap creates its temporary link there, and a
     parent still owned by the old login fails the deploy at `swap_release`
     (safely: the old release keeps serving).
   - `chown root:deploy /etc/git-deploy/webhook.env` (mode 640);
     `systemctl disable --now git-deploy-webhook@OLD && systemctl enable --now git-deploy-webhook@deploy`.
   - Move `OLD`'s deploy-related home files the deploy needs (pm2 dump is
     regenerated; the GitHub deploy-key clone of the toolkit is root's).
5. **Verify**: for each app, `sudo -u deploy` runs a
   same-commit redeploy (`echo "$sha $sha refs/heads/main" | …/post-receive`
   from the bare repo) and the app still serves. Run that as
   `ssh deploy@host` (or `sudo -iu deploy`), not `sudo -u deploy` from the old
   login: that leaks `SUDO_USER=<old login>` into the hook, and the cron
   helper then reports the old login as the deploy user; one real `git push deploy`;
   one webhook button deploy.
6. **Point your clones at the new user** (every local copy, every machine):
   `git remote set-url deploy ssh://deploy@<host>/srv/git/<app>.git`.
   Any clone you miss is rejected by `pre-receive` with the line above.
7. **Retire the old deploy role.** The old login stays your admin account and
   keeps its own sudo: with a key-only login and no password, taking its
   `NOPASSWD:ALL` away would lock you out of sudo. What changed is that nothing
   deploys as it any more. Remove its now-redundant `git-deploy-cron` and
   `git-deploy-logrotate` sudoers files, the `pm2-OLD` logrotate file, and its
   old pm2 home (keep `dump.pm2` until the next reboot has proven
   `pm2-deploy.service`).

Rollback: until step 7, re-point `/etc/git-deploy/user` and the units at `OLD`.

## Where each piece lives

| | |
|---|---|
| `/etc/git-deploy/user` | the deploy user's name; read by `pre-receive`, `git-deploy-new` and `install.sh` |
| `/etc/git-deploy/services` | `git-deploy-service` allow-list |
| `/etc/git-deploy/fixperms.{roots,group}` | optional overrides for `git-deploy-fixperms` |
| `/etc/sudoers.d/git-deploy` | generated by `install.sh` |
