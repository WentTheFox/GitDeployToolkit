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
  deploy.jsonl                           <- server-side: JSON-lines deploy history
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
  If several bare repos deploy the same `deploy.conf` (prod + a beta
  copy), gate risky per-target steps like DB migrations on `$GIT_DIR`
  with an explicit allowlist in `deploy.conf` itself, failing closed —
  not on a flag in an untracked file whose absence means "do it". See
  `template/deploy.conf.example`.

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

### Leftover `.git` in the worktree (migrating an app that was deployed by a clone)

If the app used to be deployed by `git pull`/a bespoke hook, its worktree
contains a real `.git` directory. The toolkit updates the files but never
touches it, so `git log -1` in the web root (footers, "about"/version
endpoints, Sentry release detection) keeps answering with the last
pre-toolkit commit. The hook prints a warning while one exists. Check and
clean up once, after the first toolkit deploy is verified:

```sh
[ -d /var/www/myapp/.git ] && echo "real .git present"   # a gitfile (plain file) is fine
sudo mv /var/www/myapp/.git /srv/git/myapp.git.pre-toolkit-$(date +%F)   # outside the web root, restorable
```

Show what will be moved and confirm before doing this on a production
tree; delete the backup once you're sure nothing needs it.

Before removing it, grep the app for code that runs `git log`/`rev-parse` in
its web root (switch it to `.git-deploy-commit` and deploy that first), and
make sure `deploy.conf` runs composer/npm as the user that owns `vendor/` and
`node_modules/`: without a `.git`, composer rewrites
`vendor/composer/installed.php` on the next run.

Apps that need the deployed commit should read `.git-deploy-commit` in the
worktree root instead (written by the hook on every deploy, before
`deploy_build`): line 1 is the full sha, line 2 the committer date in ISO
8601. It is untracked; make sure it isn't served publicly if that matters.

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

## Triggering deploys from GitHub (optional, recommended)

A "Deploy" button in each app's GitHub Actions tab that ends in exactly
the same post-receive hook + `deploy.conf` as `git push deploy main` —
without self-hosted runners (GitHub discourages those on public repos)
and without any server credential stored in GitHub:

```
Actions "Deploy" button (GitHub-hosted runner, only holds GITHUB_TOKEN)
  -> creates a GitHub Deployment (task "git-deploy") for that commit
  -> GitHub POSTs a signed `deployment` webhook to https://webhook.example.com/hooks/git-deploy
  -> nginx -> webhook daemon (checks HMAC signature, event, task)
  -> git-deploy-webhook: picks the app by deploy.env, fetches the commit from
     GitHub, refuses it unless it's on the deploy branch, moves the bare
     repo's branch and runs the same post-receive hook
  -> reports in_progress/success/failure back as deployment statuses; the
     Actions run tails the linked log and goes red if the deploy failed
```

One listener per server serves every app on it. It uses
[adnanh/webhook](https://github.com/adnanh/webhook) (packaged in Debian
as `webhook`) plus `share/git-deploy-webhook`.

### Once per server

1. `sudo apt install webhook`, then update the toolkit (`git pull &&
   sudo ./install.sh`) — this installs `git-deploy-webhook`, its
   `hooks.json`, and the `git-deploy-webhook@.service` template unit.
   (Debian's own `webhook.service` stays inactive without an
   `/etc/webhook.conf`; leave it that way.)
2. Log directory, writable by the deploy user and readable by nginx:
   `sudo install -d -o <deploy-user> -g www-data -m 2750 /var/lib/git-deploy/logs`
3. Config: `sudo install -d /etc/git-deploy`, copy
   `template/webhook.env.example` to `/etc/git-deploy/webhook.env`,
   `sudo chown root:<deploy-user>` and `chmod 640` it, and fill in:
   - `GIT_DEPLOY_WEBHOOK_SECRET` — `openssl rand -hex 32`. One per
     server, pasted into every app's repo webhook below.
   - `GIT_DEPLOY_GITHUB_TOKEN` — a fine-grained personal access token,
     repository access limited to the apps deployed from this server,
     permission **Deployments: Read and write** and nothing else. Without
     it deploys still run, but GitHub never hears the result. Note its
     expiry date somewhere; an expired token looks like "the server never
     acknowledged" in the Actions run. A fine-grained token covers one
     owner only, so for apps under an organization add another one as
     `GIT_DEPLOY_GITHUB_TOKEN_<OWNER>` (owner name uppercased, `-`/`.` as
     `_`, e.g. `GIT_DEPLOY_GITHUB_TOKEN_MLP_VECTORCLUB`); it takes
     precedence for that owner's repos.
   - `GIT_DEPLOY_LOG_BASE_URL` — `https://webhook.example.com/logs`.
     Like the token, it can be overridden per owner with
     `GIT_DEPLOY_LOG_BASE_URL_<OWNER>`, for an owner whose repos point
     their webhook at an alias host of their own (a second nginx
     `server_name` in front of the same listener) and shouldn't link the
     main host from their public deployment statuses.
4. nginx: adapt `template/nginx-webhook.conf.example` (server name, the
   server's usual TLS setup — Cloudflare origin cert snippet or
   `certbot --expand`), enable it, `nginx -t && systemctl reload nginx`.
5. `sudo systemctl enable --now git-deploy-webhook@<deploy-user>` — the
   instance name is the user that owns the bare repos (the one you `git
   push deploy` as). Sanity check:
   `curl -s -XPOST https://webhook.example.com/hooks/git-deploy` should
   answer "Hook rules were not satisfied."

### Once per app

1. On the server, add to the app's `/srv/git/<app>.git/deploy.env`:
   ```sh
   GITHUB_REPO=Owner/repo
   #GITHUB_ENVIRONMENT=beta   # only for a second worktree of the same repo; default production
   #GITHUB_URL=git@...        # only for a private repo (defaults to https://github.com/$GITHUB_REPO.git)
   ```
2. In the app's GitHub repo, Settings -> Webhooks -> Add webhook:
   payload URL `https://webhook.example.com/hooks/git-deploy`, content
   type **application/json**, the server's secret, "Let me select
   individual events" -> **Deployments** only.
3. Copy `template/deploy-webhook.yml.example` to
   `.github/workflows/deploy.yml` and commit it.
4. Add the repo to the server's token's repository list.
5. On the repo's main page, click the gear next to "About" and tick
   **Deployments** under "Include in the home page". Deploys work without
   it, but that's what puts the environments (with each one's latest
   status and log link) in the repo's sidebar; otherwise they're only
   reachable through the Actions run.

Then: Actions tab -> "Deploy" -> Run workflow.

### Several environments of one repo (e.g. production + beta)

When one repo deploys to more than one worktree (each its own bare repo
via `git-deploy-new`), give each bare repo's `deploy.env` the same
`GITHUB_REPO` and a distinct `GITHUB_ENVIRONMENT` (leaving it out means
`production`). In that app's `deploy.yml`, add a checkbox input per extra
environment (the template has a commented-out `beta` one) and list every
environment in the plan step's `ENVIRONMENTS`, in the order they should
deploy. Run workflow then shows one checkbox each; the ticked ones deploy
one at a time in that order, each as its own job and GitHub Deployment,
and a failure stops the rest. The environments can even live on
different servers — each server only acts on the repos it has.

### Manual pushes show up too

Once an app's `deploy.env` has `GITHUB_REPO`, a plain `git push deploy
main` is recorded on GitHub as well: the shared hook hands the push to
`git-deploy-webhook --push`, which creates a Deployment for the pushed
commit (task `git-deploy-push`, which the webhook ignores, so nothing
deploys twice), then reports status and writes the same public log as a
button deploy. Your terminal still shows the full output. If GitHub
can't take it — no token for that repo's owner, the API unreachable, or
a commit you haven't pushed to GitHub yet — the push says why in one
line and deploys exactly as before, just unrecorded.

### What ends up public

On a public repo, deployment statuses and Actions logs are visible to
anyone, and so is the log they link to (unguessable URL, but published in
the status). By default that log only contains the toolkit's own
`git-deploy...` progress lines, each timestamped — which step ran, and for a failure the
failing command's source text and exit code (the shared hook prints that
line on any failure, from its unexpanded text as committed in
`deploy.conf`) — never command output, and with the server's paths masked.
Full output always goes to the server's journal:
`journalctl -t git-deploy-webhook`. `GIT_DEPLOY_LOG_PUBLIC=full` in
`webhook.env` publishes everything instead. A guarded, tolerated failure
(`if ! cmd; then ...`) prints nothing publicly; a `deploy.conf` that wants
a message in the public log can prefix it with `git-deploy:`.

### Why this is safe to expose

- The webhook secret is the only credential involved, and it only lets
  someone *trigger* a deploy. `git-deploy-webhook` independently fetches
  the deploy branch from GitHub and refuses any commit not on it, so even
  a leaked secret can't deploy code from a fork, PR, or other branch —
  at worst a commit already on `main` (possibly an older one).
- Deployment ids only increase; each app remembers the last one handled
  and ignores anything not newer, so a captured delivery can't be
  replayed to roll the app back.
- Deploys of one app are serialized (`flock`), so double clicks or a
  GitHub redelivery queue up instead of racing `checkout -f`.
- Anyone with write access to the repo can create a deployment and so
  deploy — the same trust boundary as the button itself.
- The listener runs as the deploy user, with the same (narrow) sudo a
  manual push already needs, and binds to 127.0.0.1 only.
- If Cloudflare sits in front and ever starts challenging GitHub's
  requests (Bot Fight Mode, WAF), Recent Deliveries shows non-2xx
  responses; add a skip rule for `/hooks/git-deploy`.

## Deploy log

Every push appends a `start` and a `complete` JSON-line to
`<bare-repo>/deploy.jsonl` (e.g. `/srv/git/myapp.git/deploy.jsonl`) — never
tracked, server-side only, the bare-repo equivalent of a worktree's
`.git/deploy.jsonl`. This is the source of truth for "when was this last
deployed" and "did it succeed" — handy for an LLM agent debugging on the
server to check without asking:

```json
{"event":"start","time":"2026-09-18T09:59:15Z","branch":"main","commit":"a621a11...","prev_commit":"06909ea..."}
{"event":"complete","time":"2026-09-18T09:59:15Z","branch":"main","commit":"a621a11...","prev_commit":"06909ea...","status":"success","duration_s":4,"logrotate":"absent","retention":[]}
```

`status` is `success` or `failed` (`deploy_build`/`deploy_restart`
returned non-zero). If a `start` line has no matching `complete` line,
the hook itself crashed (e.g. during checkout) before finishing.

## Discord notifications (optional)

Add a Discord channel webhook URL (channel settings → Integrations →
Webhooks) to an app's `deploy.env`:

```sh
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/<id>/<token>
```

and every deploy of it posts two messages there: one when it starts (the
commit range and the new commits' subjects) and one with the outcome and
duration. Each title leads with its outcome in words — "Deploy started",
"Deploy succeeded", "Deploy failed" — not just the embed's color. Both say how it was started ("git push" or
"Deploy button"). There's no log link; GitHub's Deployments page and the
Actions run have that. Button deploys,
manual pushes and plain pushes of apps without GitHub all notify exactly
once — the shared hook sends them (via `git-deploy-notify`), and a button
deploy that fails before the hook even runs (commit not on the branch)
gets a "failed" message from `git-deploy-webhook` instead. No command
output is ever posted, and `@mentions` in commit subjects don't ping.

It's strictly best-effort: Discord being slow (5s cap per message) or
failing costs one `git-deploy: discord notification failed (...)` line,
never the deploy. Use the plain webhook URL, not its `/github` variant —
that one silently accepts deployment events without posting anything.

Anyone with the URL can post to the channel, so it's never printed or put
on a command line, and `deploy.env` should be readable by the deploy user
only: `git-deploy-new` creates it `600`; for an older app,
`chmod 600 /srv/git/<app>.git/deploy.env`.

## Log retention (optional)

An app can carry its own logrotate definition in its repo, so its
retention policy is versioned with the code. Copy
`template/deploy.logrotate.example` to `deploy.logrotate` in the repo root
and edit it. On each deploy the hook validates it (`logrotate -d`, which
changes nothing) and installs it as `/etc/logrotate.d/git-deploy-<app>`;
the system's logrotate timer does the rotating — the toolkit never runs
logrotate itself. An app without the file is not touched at all.

Because logrotate runs as root, installing goes through a restricted
helper (`git-deploy-logrotate`, installed by `install.sh`) that refuses
anything unsafe: paths outside the worktree, scripts (`postrotate` etc.),
`include`, a stanza without `rotate N` or without a non-root `su user
group`. Placeholders: `@WORKTREE@`, `@APP@`. Every deploy states the outcome. With a `deploy.logrotate` it prints one
line per log file, e.g. `git-deploy: logrotate: retention 14 days:
<path>` (daily × `rotate 14`; `maxage` caps it), and these lines are part
of the public deployment log, with the worktree path masked like any other
server path. That check needs no root, so it is reported even when the
install isn't possible. Without the file the deploy says so, which is
itself the evidence that the repo doesn't manage its log retention. A
refused or uninstallable file only warns — the deploy carries on — and
`deploy.jsonl`'s `complete` line gets
`"logrotate":"installed|unchanged|refused|unavailable|absent"` plus
`"retention":[{"path":"logs/x.log","days":14}]` (paths relative to the
worktree; empty when absent or refused).

Once per server, allow the helper (the deploy user is usually not root):

```
# /etc/sudoers.d/git-deploy-logrotate  (mode 0440)
deploy ALL=(root) NOPASSWD: /usr/local/lib/git-deploy/git-deploy-logrotate install *
```

Worktrees must be under `/var/www` or `/var/node` (one path per line in
`/etc/git-deploy/logrotate.roots` overrides that). For pm2 apps, point
pm2's `out_file`/`error_file` at a file inside the worktree (gitignored)
so the same definition covers it; pm2 only reads those paths when the
process is started, so moving an existing app's logs needs one `pm2
delete` + start. Adopting an app that already has a hand-made file in
`/etc/logrotate.d` for the same logs: `sudo git-deploy-logrotate adopt
<file>` moves it to `/root/logrotate.pre-toolkit/` (otherwise the helper
refuses, since logrotate errors on a log listed twice). `git-deploy-logrotate
report <app> <worktree> < deploy.logrotate` prints each log's retention in
days without installing anything. Design notes: `docs/logrotate.md`.

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

## Tests

`tests/run.sh` runs end-to-end tests entirely locally — a throwaway
"GitHub" origin, a bare repo made by `git-deploy-new`, real pushes
through the shared hook, signed deliveries through the real `webhook`
daemon against a stub statuses API, and `deploy-webhook.yml`'s own
log-tailing step. CI (`.github/workflows/test.yml`) runs it on every push
and PR. Locally it needs `webhook`, `jq` and PyYAML (`apt install webhook jq
python3-yaml`), or point `WEBHOOK_BIN=`/`PYTHON=` at your own copies.

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
