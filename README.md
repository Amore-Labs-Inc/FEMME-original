# FEMME

Always-on [herdr](https://herdr.dev) on an AWS VPS. Start agents from your laptop or iPhone, close the lid, come back later: they kept running on the VPS's CPU and RAM, and you find them where they ended up.

- `herdr server` runs as a systemd user unit with linger, so it starts at boot and never depends on a client being attached.
- Panes survive SSH drops and lid closes. After a VPS reboot herdr restores the layout, resumes agent conversations and replays screen history.
- ntfy push to your phone when an agent is blocked or done.
- mosh for the phone, so wifi/cellular switches and sleep don't kill the session.
- A herdr plugin that forks a local agent onto the VPS, conversation and folder. The folder then stays in live two-way sync ([Mutagen](https://mutagen.io)), so VPS work shows up on the laptop when it wakes.

## Setup

Needs: AWS CLI logged in, `~/.ssh/id_ed25519` (no passphrase, the Mutagen service has no ssh-agent), herdr, jq, rsync, [mutagen](https://github.com/mutagen-io/mutagen/releases) in `~/.local/bin`.

```sh
./provision.sh                              # VPS + security group + Elastic IP, writes .env and ~/.ssh/config "Host agentbox"
ssh agentbox cloud-init status --wait
./sync.sh                                   # copies agent/herdr config, runs bootstrap.sh on the VPS
ssh agentbox                                # one-time logins, credentials are never copied:
#   claude            -> /login, paste the URL
#   codex login --device-auth
#   gh auth login && gh auth setup-git
```

Defaults live in `.env` (`REGION`, `INSTANCE_TYPE`, `DISK_GB`, `HOST`, `SPAWN_TYPES`). `.env` is gitignored and holds your IP and ntfy topic.

### Laptop

```sh
herdr machine add agentbox --label agentbox --remote-session default
herdr plugin link "$PWD"                    # or: herdr plugin install Darkosxl/FEMME --yes
cp systemd/mutagen.service ~/.config/systemd/user/ && systemctl --user enable --now mutagen
cp systemd/femme-link.service ~/.config/systemd/user/ && systemctl --user enable --now femme-link  # laptop terminals on the board
```

Add to `~/.config/herdr/config.toml`, then `herdr server reload-config`:

```toml
[[keys.command]]
key = "prefix+shift+v"
type = "plugin_action"
command = "femme.fork-remote"
description = "fork agent to VPS"
```

Local and VPS workspaces show side by side. Local ones die when the laptop sleeps; `prefix+shift+v` on a local agent forks it to the VPS and leaves the local one running:

1. The agent's folder (its git root, or its cwd; git not required) is put in two-way sync with the same path on the VPS. The first time, rsync seeds it (never overwriting newer VPS files); after that Mutagen streams changes both ways.
2. The session file is copied, and the agent starts there in its own fork mode. Claude Code, Codex and Pi are supported.

Sync rules:
- `node_modules .venv venv __pycache__ target .cache .next` stay on their own side; reinstall deps on the VPS.
- Mode is two-way-safe. If both sides change the same file, that file pauses with a conflict and neither copy is overwritten. See them with `mutagen sync list`.
- Deletions propagate both ways, like any other change.
- Only folders inside `$HOME` are synced; an agent in `/tmp` gets an empty folder on the VPS.
- `sh sync-dir.sh <dir>` syncs a folder without forking anything. `mutagen sync terminate <name>` stops it, and both copies stay.

### iPhone

1. Install **Moshi** (or Blink Shell) and **ntfy**.
2. In Moshi, generate a key and copy the public key. On the laptop: `ssh agentbox 'cat >> ~/.ssh/authorized_keys'`, paste, Ctrl-D.
3. Add host: `darkwarro@<IP from .env>`, mosh on, command `herdr`.
4. In ntfy, subscribe to the `NTFY_TOPIC` from `.env`. Anyone who knows the topic can read your pushes, so keep it secret.

### The box's own AWS access

`provision.sh` gives the instance the IAM role `femme`: launch, stop and terminate instances of the `SPAWN_TYPES` types in `REGION` only (plus the security groups, key pairs and tags that takes), no IAM. The credentials come from the instance metadata service and rotate themselves, so there is nothing to leak; but anything running on the box can use them, so the policy is the guard.

After rerunning `./provision.sh`, remove whatever is in `~/.aws` on the VPS (a static key or the board's `aws login` session shadows the role): `aws logout`, or delete the files. Then `aws sts get-caller-identity` shows `assumed-role/femme/i-…`, and so does the board's accounts window.

Set a hard spend brake: in Service Quotas, lower "Running On-Demand Standard instances" (vCPUs) for the region to e.g. 16. Add a Budgets email alert too, but alerts lag hours and stop nothing. Credits apply to the bill automatically.

## Issues board

Set `BOARD_EMAIL`, `BOARD_URL`, `RESEND_API_KEY`, `MAIL_FROM` in `.env`, point an A record (DNS only) for `BOARD_URL`'s host at the VPS, rerun `./provision.sh` (opens 80/443) and `./sync.sh`.

- Sign in with a magic link sent to your address, one of those in `BOARD_EMAIL` (comma-separated; everyone on it gets the same full access). The link works once, for 15 minutes (one link a minute per client); the cookie lasts 7 days.
- Add an issue: pick a repo, describe the work. The worker clones it to `~/femme-work`, creates branch `femme/issue-N`, and runs Claude in a herdr workspace named `#N ...`, so you can watch or step in from the phone.
- Finished work arrives as a PR with `FEMME issue #N` in its body. The card moves to **PR ready**; after merging, press **Merged, done** and the workspace closes.
- **Chat** on a card opens that agent's terminal: a real terminal (xterm.js) showing the pane's live screen in colour. Type straight into it (keys, arrows, Ctrl-C, paste); on a phone the key bar has Esc, Tab, arrows, Ctrl-C and Enter. Paste or drop an image or file (or use the upload button): it is saved to `~/.local/state/femme/uploads` (kept 7 days) and its path is typed in, which Claude Code attaches as an image. **End** closes the workspace.
- **Terminals** tab: every VPS workspace. Open a new one (shell, Claude, Codex or Pi) in any folder under `$HOME`, use it the same way, or close it.
- Linked laptops' workspaces are listed there too, tagged with the laptop's hostname, while it is awake. `femme-link.service` forwards the laptop's herdr socket to `~/.config/herdr/remote/<hostname>.sock` on the VPS over SSH. New terminals open on the VPS only, and uploads only reach VPS terminals. Anything running as your user on the VPS, agents included, can then type into the laptop's terminals.
- Merging to `main` deploys itself: every 20 seconds `femme-deploy.timer` checks GitHub, and when `main` moved it checks it out in `~/femme` and reruns `bootstrap.sh` (rebuilds the board, restarts board and worker). The board shows `deploying`, then `deployed <commit>` or why it failed, until you close it; a failed build leaves the old board running. `./sync.sh` still pushes your unmerged laptop copy.
- Budget: at most `PARALLEL` (2) issues at once. When the 5-hour window passes `CAP` (60%), running agents are interrupted and continue after the reset, so the rest of the window is yours. Set both in `.env`.

### Player reports

The game server files players' bug reports on the board:

```
POST /api/reports
Authorization: Bearer <~/.local/state/femme/report.token on the VPS>
Content-Type: application/json
{"title": "≤120 chars, optional", "text": "1-4000 chars", "png": "<base64 PNG, ≤6 MB>", "meta": {"any": "object ≤4 KB"}}
→ 201 {"id": <issue id>}   400 bad field · 401 bad token · 413 body over 9 MB · 429 over the hourly limit
```

- `report.token` is created at the board's first start (mode 0600). It opens this route only; the worker token and a session never do.
- The screenshot and the report go to `~/.local/state/femme/reports/` (kept, never purged). The issue body gives the worker's Claude the screenshot's path, the meta, and the player's text fenced as untrusted data. Signed in, the card's **screenshot** link shows it.
- Reports land as **Player reports** (status `triage`), which the worker never starts. **Queue it** moves one to the queue (`open`); **Delete** drops it.
- `.env`: `FEMME_REPORT_REPO` (default `Darkosxl/mksm-recomp`), `FEMME_REPORT_BASE` (the branch PRs start from and target, default `shaolin-monks-decomp`), `FEMME_REPORT_LIMIT` (reports per hour, all players together, default 30).

### API for other agents

Another agent (Instinct) gets one standing Claude Code session on the box, reused for all its tasks, so the board is not filled with one terminal per task. Make it a key in the accounts window (**API keys**, name it, copy the key: it is shown once) and hand over the key with `$BOARD_URL/api/openapi.json`, an OpenAPI 3 document written for a program to read: auth, each route with an example, errors, what is safe to retry. **revoke** next to a key ends it at once; keys live in `~/.local/state/femme/api-keys.json`.

To push as the other person rather than as the box's GitHub login, put their GitHub account on the key: **connect GitHub** next to it shows a one-time code; they enter it at github.com/login/device signed in as themselves (the usual `gh auth login`, in a config dir of its own, so the box's login is untouched), and the key gets their token, name and GitHub noreply address. Or paste a token when making the key (a fine-grained PAT for the repo, Contents: read and write; the name and address come from GitHub). The repos that key's sessions clone are fetched and pushed with the token (it sits in that clone's `.git/config`, so the session's Claude can read it: it works on their behalf anyway) and commits carry the name. Set again on every open, so connecting again takes over; a key without an account hands the clone back to the box's `gh`.

- `POST /api/agents/<name>` `{"text": "...", "repo": "Amore-Labs-Inc/Exposure"}` sends a task. When nothing runs under that name, the repo is cloned to `~/femme-work/<name>`, Claude starts there in a workspace labelled with the name (its trust question answered yes: the folder was the caller's choice), and a standing brief goes before the text: do each task end to end and check it, but leave the changes uncommitted; no PRs. The session shows on the Terminals tab like any other, tagged `instinct`, so you can watch or step in. These sessions run in a herdr session of their own (`instinct`, kept up by `herdr-instinct.service`): on the laptop, `herdr machine add agentbox --label "Instinct · Onur" --remote-session instinct` lists them as a machine tab of their own next to agentbox.
- `POST /api/agents/<name>/push` is the owner's yes: Claude commits the task's changes as one commit and pushes onto `push` (default `main`, set when the session was opened). `POST /api/agents/<name>/discard` is the no: the changes are thrown away. Both take an optional `{"text": "..."}` note from the owner. So a task is: send it, read the report, relay the owner's answer.
- `GET /api/agents/<name>` returns `status`, the screen as text, and once Claude stopped a `message` read off the clone: `changes created and pushed to Exposure` (with `pushed: true` and the commit) when the tree is clean and HEAD is on the branch and moved since the task was sent; `changes ready, not pushed to main: read the report, then POST /api/agents/<name>/push or /discard` at the normal end of a task; or that it finished with nothing new. `report` is Claude's own account of the task, written to `~/.local/state/femme/report-<name>.md` when it finishes, for a reader who is not a programmer: the brief asks for everything in a form a reader with ADHD takes in at a glance (the point first, short lines, bullets) and the report to be one line on what the change does for them plus up to five bullets on what they will notice, what was checked and what is left open or needs their decision, with no file names or code. `DELETE` closes the session.
- A key also reaches the other terminals: `GET /api/terminals` lists every one (the box's, its own, the laptop's while linked), `GET /api/terminals/<pane>` reads one (status and screen as text), `POST /api/terminals/<pane>/prompt` sends the agent in it a whole message, and `/api/terminals/<pane>/input` types raw keys (answering Claude's own prompts). So Instinct can ask a running session what it did, or hand it a task, and read the answer off its screen; it cannot open or close terminals here, only its own under `/api/agents`. A key sees every screen, the laptop's included while it is linked.
- A key reaches those routes, `/api/ping`, `/api/openapi.json` and `/api/agents/<name>` with its `/push` and `/discard`. Everything else answers 403 to it.

### Accounts

The board's **accounts** window lists every Claude account stored with [cswap](https://pypi.org/project/claude-swap/), with each account's 5-hour and 7-day usage.

- **+ add**: open the sign-in link, log in on claude.ai with the new account, paste the code it shows into the board. The board signs in a separate config dir, runs `cswap add` from there, and leaves the VPS's live login alone. Never run `/logout`: it drops the stored accounts.
- Click an account to switch the VPS to it (`cswap switch`).
- `femme-cswap.service` runs `cswap auto --threshold $CAP`: when the active account passes `CAP` it switches to the account with the most left, so agents only pause once every account is past `CAP` (keep it 50-99).
- `bootstrap.sh` installs cswap and saves the VPS's current login as account 1.
- **AWS**: the window also shows who the VPS's AWS CLI is signed in as. **sign in** opens the AWS sign-in page; paste the code it shows into the board, which finishes `aws login --remote` for you. `bootstrap.sh` installs the AWS CLI.

## Files

| File | Runs on | Does |
|---|---|---|
| `provision.sh` | laptop | Creates the instance. Safe to rerun; reuses everything tagged `femme`. |
| `cloud-init.yaml` | VPS, first boot | Your user (same name as on the laptop, so paths match), key-only SSH, mosh, 8 GB swap, linger. |
| `sync.sh` | laptop | Copies config: `~/.claude` minus credentials and history, herdr, mise. Merges onboarding, trust and portable MCP servers into the VPS `~/.claude.json`. |
| `sync-dir.sh` | laptop | Puts one folder in live two-way sync with the VPS. |
| `bootstrap.sh` | VPS | Installs mise toolchains, agents, herdr and the systemd units; builds the board. |
| `deploy.sh` | VPS | On a timer: deploys `main` after a merge. |
| `notify.sh` | VPS | Polls `herdr api snapshot`, pushes to ntfy on `blocked` and `done`. |
| `fork-remote.sh` | laptop | The herdr plugin action. |
| `board/` | VPS | The issues board server (Rust). |
| `worker.sh` | VPS | Runs board issues as herdr Claude agents within the budget. |
| `systemd/femme-cswap.service` | VPS | Auto-rotates Claude accounts at `CAP`. |
| `systemd/herdr-instinct.service` | VPS | The herdr session Instinct's terminals run in. |
| `systemd/mutagen.service` | laptop | Keeps sync sessions running across reboots. |
| `systemd/femme-link.service` | laptop | Puts the laptop's herdr terminals on the board. |

## Cost

m7i-flex.xlarge (4 vCPU, 16 GB) in eu-west-2 plus 250 GB gp3 and a public IPv4 comes to about $180/month on-demand. Termination protection is on.
