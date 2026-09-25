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
without a self-hosted runner (GitHub discourages those on public repos)
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
     acknowledged" in the Actions run.
   - `GIT_DEPLOY_LOG_BASE_URL` — `https://webhook.example.com/logs`.
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
   `.github/workflows/deploy.yml` and commit it. (If the app had the
   self-hosted-runner workflow below, this replaces it — remove that
   runner and its `DEPLOY_REMOTE_URL` secret.)
4. Add the repo to the server's token's repository list.

Then: Actions tab -> "Deploy" -> Run workflow.

### What ends up public

On a public repo, deployment statuses and Actions logs are visible to
anyone, and so is the log they link to (unguessable URL, but published in
the status). By default that log only contains the toolkit's own
`git-deploy...` progress lines — which step ran, and for a failure the
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

## Triggering deploys from GitHub Actions via a self-hosted runner (alternative)

Superseded by the webhook approach above for public repos; kept for
reference and for any app already set up this way.


Deploy is always just `git push deploy main` — this only changes *who*
runs that push, from your own machine to a button in GitHub's Actions
tab, without adopting a third-party CI/deploy subscription (Forge,
Envoyer, etc.) or opening the server to inbound access from GitHub's
hosted runners. It works by installing a GitHub Actions **self-hosted**
runner directly on the server, so the credential/access needed to push
to `deploy` never has to leave it.

Unlike the post-receive hook, a runner registration can't actually be
shared across repos unless those repos belong to a GitHub
**Organization** (org-level runner groups are what makes that possible).
Under a personal account, each repo gets **its own** runner registration
— there's no personal-account-wide equivalent. That still doesn't mean
copy-pasting a bespoke setup per app: run one lightweight runner
*instance* per app, all on the same physical server if that's where they
all deploy, all labeled `git-deploy` so every app's `deploy.yml` looks
identical and this template never has to change per app — the sharing is
at the label/template/convention level, not the registration itself.
(If these apps ever move under an Organization, an org-level runner
group would let one actual runner process serve all of them — a bigger
change, not required for any of this to work today.)

**Once per app**, on the server:

1. Install a self-hosted runner following GitHub's own instructions for
   that specific repo (that repo's Settings → Actions → Runners → New
   self-hosted runner gives you a registration token and the exact
   `config.sh` command — the token is single-use and tied to that repo,
   so this step repeats per app). Give it the label `git-deploy`, and a
   `--name` that identifies which app it's for (the label is what the
   workflow targets; the name is just so `runner status` output is
   readable with several installed).
2. Install it as its own service (`./svc.sh install && ./svc.sh start`,
   run from that runner's own directory) so it survives reboots — each
   app's runner is a separate directory/service, even side by side on
   one server.
3. Make sure the OS user running it can push to this app's bare repo the
   same way your own deploy user can — simplest is running it as that
   same deploy user.

**Also once per app**, in the app's own repo:

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
- **Per-repo runner registration (the personal-account default above)
  already gives you this for free** — each runner only ever runs jobs
  for the one repo it was registered to, nothing wider to accidentally
  loosen. The thing to watch is the mirror image: if these repos ever
  move under a GitHub Organization and you switch to one shared
  org-level runner (see above), don't register it into a runner group
  scoped to "all repositories" — scope the group explicitly to the apps
  that need it, or an unrelated future repo in the org inherits the same
  server access with zero extra steps on your part.
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

## Deploy log

Every push appends a `start` and a `complete` JSON-line to
`<bare-repo>/deploy.jsonl` (e.g. `/srv/git/myapp.git/deploy.jsonl`) — never
tracked, server-side only, the bare-repo equivalent of a worktree's
`.git/deploy.jsonl`. This is the source of truth for "when was this last
deployed" and "did it succeed" — handy for an LLM agent debugging on the
server to check without asking:

```json
{"event":"start","time":"2026-09-18T09:59:15Z","branch":"main","commit":"a621a11...","prev_commit":"06909ea..."}
{"event":"complete","time":"2026-09-18T09:59:15Z","branch":"main","commit":"a621a11...","prev_commit":"06909ea...","status":"success","duration_s":4}
```

`status` is `success` or `failed` (`deploy_build`/`deploy_restart`
returned non-zero). If a `start` line has no matching `complete` line,
the hook itself crashed (e.g. during checkout) before finishing.

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
and PR. Locally it needs `webhook` and PyYAML (`apt install webhook
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
