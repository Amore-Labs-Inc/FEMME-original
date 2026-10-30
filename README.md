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
herdr plugin link "$PWD"                    # or: herdr plugin install Amore-Labs-Inc/FEMME-original --yes
cp systemd/mutagen.service ~/.config/systemd/user/ && systemctl --user enable --now mutagen
cp systemd/femme-link.service ~/.config/systemd/user/ && systemctl --user enable --now femme-link  # laptop terminals on the board
```

Add to `~/.config/herdr/config.toml`, then `./sync.sh`. A `[[keys.command]]` binding belongs to the machine selected in herdr, not to the client: the fork key is used on Local panes, so the laptop's own copy serves it (`herdr server reload-config` is enough), but the drop box key is pressed on agentbox panes, so it must be in the VPS's `config.toml` too, which `sync.sh` copies over and reloads (herdr issue #5183). `prefix+?` lists the selected machine's keys.

```toml
[[keys.command]]
key = "prefix+shift+v"
type = "plugin_action"
command = "femme.fork-remote"
description = "fork agent to VPS"

[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "femme.files"
description = "drop box: files into the agent's folder"
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

`prefix+u` (the prefix is `ctrl+b` unless `keys.prefix` says otherwise) on a VPS agent opens **Files · drop box** beside it: the agent's folder, newest first. Drag a file from the laptop's file manager onto the box and it is uploaded into that folder: a spinner while it runs, ✓ once it is listed. The copy goes through the laptop's linked herdr (an `upload: …` workspace flashes there), so `femme-link` must be running; the box says `laptop not linked` otherwise. A drop lands in the focused pane, so the box must be it (herdr's blue border): unfocused, it dims and shows a yellow *click here first* bar. A dropped image takes herdr's own image bridge, and a file from a synced folder is copied on the VPS side. `q` closes the box.

### Work on PC files from the VPS

Agents run on the VPS (its RAM, its account rotation) while the heavy files and the toolchain stay on the laptop: the folder's text syncs as above, and the agent builds on the laptop with `pc <command>`.

```sh
./pc-setup.sh                               # once, on the laptop: sshd on 127.0.0.1 only, the VPS's key, the link forwards it
```

Then per folder, on the laptop: put what must not leave it in `<dir>/.femme-ignore`, one Mutagen pattern per line, and sync it (`sh sync-dir.sh <dir>`, or `prefix+shift+v` on an agent there):

```
# decomp: the disc image, the build and the Ghidra project stay here
*.iso
baserom*
/build
/expected
*.gpr
*.rep
```

Open a terminal on the board in that folder (Claude or Codex; both get the rule from `rules/pc.md`). The agent edits on the VPS and runs `pc make` (or `pc 'make && ./check.sh'`, or just `pc` for a shell): `pc` flushes the sync, runs the line on the laptop in the same folder through its login shell, and flushes again, so the build sees the edits and the results come back. Asleep or away laptop: edits go on, only `pc` says `laptop not linked`. Ignores are fixed when the session is made: `mutagen sync terminate <name>`, edit `.femme-ignore`, sync again. `PC_HOST` in `.env` picks the laptop when several are linked.

Trust: the VPS's key logs in to your laptop as you, so anything running as your user on the VPS can run commands there (as it can already type into the laptop's terminals, above). The laptop's sshd is reachable only through the link the laptop itself opens.

### iPhone

1. Install **Moshi** (or Blink Shell) and **ntfy**.
2. In Moshi, generate a key and copy the public key. On the laptop: `ssh agentbox 'cat >> ~/.ssh/authorized_keys'`, paste, Ctrl-D.
3. Add host: `darkwarro@<IP from .env>`, mosh on, command `herdr`.
4. In ntfy, subscribe to the `NTFY_TOPIC` from `.env`. Anyone who knows the topic can read your pushes, so keep it secret.

### The box's own AWS access

The instance has an IAM role (`provision.sh` makes `femme`; the current box carries `agentbox-s3`, made by hand) with AWS's `PowerUserAccess`: everything in the account except IAM, so agents can spin instances and services up and down but cannot make users, keys or roles. The credentials come from the instance metadata service and rotate themselves, so there is no key on disk to leak; but anything running on the box can use them, so IAM being off limits is the guard. No token to hand the box: a stored key would only be worse than the role.

The role is shadowed by anything in `~/.aws` (a static key, or an `aws login` session, which also runs every agent as that user). To get back to the role: `aws logout`, then delete the `login_session` line it leaves in `~/.aws/config`. Then `aws sts get-caller-identity` shows `assumed-role/<role>/i-…`, and so does the board's accounts window.

Set a hard spend brake: in Service Quotas, lower "Running On-Demand Standard instances" (vCPUs) for the region to e.g. 16. Add a Budgets email alert too, but alerts lag hours and stop nothing. Credits apply to the bill automatically.

### Moving the box to another region

Latency is distance: every keystroke to a VPS pane makes one round trip, so a region closer to you is the only real speed-up (London is ~58 ms from Istanbul, Frankfurt ~42; Milan and Zurich are opt-in regions, and Milan lacks the instance type). `migrate-region.sh` moves the box by copying its disk rather than rebuilding: an image of the root volume, copied to the new region, launched there with the same instance profile; user, paths, herdr state, Claude sessions, accounts, board state and the Caddy certificate all travel as they are. The laptop keeps reaching the box through the `agentbox` alias, so one `HostName` change carries Mutagen, `femme-link`, the herdr machines and `pc`.

From the laptop checkout, logged in (`aws login`), `TO=eu-central-1` by default:

1. `./migrate-region.sh prewarm`: no downtime. A first image and its copy (the slow part: the first snapshot of 235 GB takes hours, the cutover one is then incremental), the security group and the Elastic IP in the new region.
2. `./migrate-region.sh cutover`, at a quiet moment: stops the box (agents, board and API are down from here, tell whoever uses the API), images it, copies, launches, checks the new box over ssh by IP (same host key, hostname, every service, the board, the role, the accounts, swap) and then asks you to point the A record at the new IP in Cloudflare. About 20 minutes.
3. `./migrate-region.sh laptop`: `~/.ssh/config`, `known_hosts`, `.env` and the security groups of your other servers that allowlist the box's IP. Then set the new IP in Moshi.
4. A week later, `./migrate-region.sh cleanup`: terminates the old box, releases its IP, deletes the old images; the new region's cutover image stays a while as a backup. `./migrate-region.sh rollback` before that puts everything back on the old box.

Every step finds what it already made by tag and skips it, so a rerun continues where it stopped. The new disk fills from the snapshot lazily: the first hour on the new box reads slower. What a move does not carry: the S3 bucket (stays, works cross-region), docker containers and quick tunnels started by hand (as after any reboot), and the Elastic IP (regions keep theirs).

### When a turn takes forever

The wire is not it: from the box, api.anthropic.com answers in 5 ms with no loss, and no session here has ever retried a request. A long silence is, in order of likelihood: the model thinking (`effortLevel: xhigh` thinks for minutes with nothing on screen), an auto-compaction (about 2 minutes, at 310k tokens), a prompt queued behind a running turn (Esc stops the turn first), or a usage cap (the accounts window shows it). Every session writes `~/.claude/debug/<session>.txt` (`bootstrap.sh` sets `DEBUG_SDK=1`), so the next long wait has a timestamped record. What the last hour's requests waited for, by session and time:

```sh
find ~/.claude/debug -name '*.txt' -mmin -60 -exec awk '/API REQUEST|first byte|engine\] turn .* end|autocompact|api_error|[Rr]etry|watchdog/ {
  print substr(FILENAME, length(FILENAME) - 11, 8), substr($0, 12, 8), substr($0, index($0, "] ") + 2, 110) }' {} + | sort -k2
```

A stream with no bytes for 60 s (`CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS`) is retried once, instead of after the default 180 s; the API pings every few seconds while the model thinks, so a minute of silence is a real stall.

## Issues board

Set `BOARD_EMAIL`, `BOARD_URL`, `RESEND_API_KEY`, `MAIL_FROM` in `.env`, point an A record (DNS only) for `BOARD_URL`'s host at the VPS, rerun `./provision.sh` (opens 80/443) and `./sync.sh`.

- Sign in with a magic link sent to your address, one of those in `BOARD_EMAIL` (comma-separated; everyone on it gets the same full access). The link works once, for 15 minutes (one link a minute per client); the cookie lasts 7 days.
- Add an issue: on the **Issues** tab, pick the repo on the composer's chip and describe the work (the first line is the title, the rest the details; attached files are listed by their path on the box). The worker clones it to `~/femme-work`, creates branch `femme/issue-N`, and runs Claude in a herdr workspace named `#N ...`, so you can watch or step in from the phone.
- Finished work arrives as a PR with `FEMME issue #N` in its body. The card moves to **PR ready**; after merging, press **Merged, done** and the workspace closes.
- **Chat** on a card opens that agent's terminal: a real terminal (xterm.js) showing the pane's live screen in colour, with a composer under it as in the Claude app. Write the message (the mic dictates it where the browser has one), **+** adds a photo from the camera or the library or any file, the arrow hands it to the agent as one prompt (a shell gets a command line). You can also type straight into the terminal (keys, arrows, Ctrl-C, paste; on a phone the key bar has Esc, Tab, arrows, Ctrl-C and Enter). Files go to `~/.local/state/femme/uploads` (kept 7 days) and their paths go in front of the message, which Claude Code attaches as images. **End** closes the workspace.
- **Sessions** tab: every VPS workspace. The composer at the bottom opens a new one: pick the folder (any under `$HOME`) and the agent (Claude, Codex, Pi or a shell) on its chips, describe the task, send; the session opens with the task as its first message (Claude's trust question on a folder's first visit is answered yes: the folder was yours to pick). **+** names the session or attaches photos and files. Open one from the list to use it the same way, or close it.
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

Another agent (Instinct) gets one standing Claude Code session on the box, reused for all its tasks, so the board is not filled with one terminal per task. Make it a key on the accounts page (**API keys**, name it, copy the key: it is shown once) and hand over the key with `$BOARD_URL/api/openapi.json`, an OpenAPI 3 document written for a program to read: auth, each route with an example, errors, what is safe to retry. **revoke** next to a key ends it at once; keys live in `~/.local/state/femme/api-keys.json`.

To push as the other person rather than as the box's GitHub login, put their GitHub account on the key: **connect GitHub** next to it shows a one-time code; they enter it at github.com/login/device signed in as themselves (the usual `gh auth login`, in a config dir of its own, so the box's login is untouched), and the key gets their token, name and GitHub noreply address. Or paste a token when making the key (a fine-grained PAT for the repo, Contents: read and write; the name and address come from GitHub). The repos that key's sessions clone are fetched and pushed with the token (it sits in that clone's `.git/config`, so the session's Claude can read it: it works on their behalf anyway) and commits carry the name. Set again on every open, so connecting again takes over; a key without an account hands the clone back to the box's `gh`.

- `POST /api/agents/<name>` `{"text": "...", "repo": "Amore-Labs-Inc/Exposure"}` sends a task. When nothing runs under that name, the repo is cloned to `~/femme-work/<name>`, Claude starts there in a workspace labelled with the name (its trust question answered yes: the folder was the caller's choice), and a standing brief goes before the text: do each task end to end and check it, but leave the changes uncommitted; no PRs. The session shows on the Terminals tab like any other, tagged `instinct`, so you can watch or step in. These sessions run in a herdr session of their own (`instinct`, kept up by `herdr-instinct.service`): on the laptop, `herdr machine add agentbox --label "Instinct" --remote-session instinct` lists them as a machine tab of their own next to agentbox.
- `POST /api/agents/<name>/push` is the owner's yes: Claude commits the task's changes as one commit and pushes onto `push` (default `main`, set when the session was opened). `POST /api/agents/<name>/discard` is the no: the changes are thrown away. Both take an optional `{"text": "..."}` note from the owner. So a task is: send it, read the report, relay the owner's answer.
- `GET /api/agents/<name>` returns `status`, the screen as text, and once Claude stopped a `message` read off the clone: `changes created and pushed to Exposure` (with `pushed: true` and the commit) when the tree is clean and HEAD is on the branch and moved since the task was sent; `changes ready, not pushed to main: read the report, then POST /api/agents/<name>/push or /discard` at the normal end of a task; or that it finished with nothing new. `report` is Claude's own account of the task, written to `~/.local/state/femme/report-<name>.md` when it finishes, for a reader who is not a programmer: the brief asks for everything in a form a reader with ADHD takes in at a glance (the point first, short lines, bullets) and the report to be one line on what the change does for them plus up to five bullets on what they will notice, what was checked and what is left open or needs their decision, with no file names or code. `DELETE` closes the session.
- A key also reaches the other terminals: `GET /api/terminals` lists every one (the box's, its own, the laptop's while linked), `GET /api/terminals/<pane>` reads one (status and screen as text), `POST /api/terminals/<pane>/prompt` sends the agent in it a whole message, and `/api/terminals/<pane>/input` types raw keys (answering Claude's own prompts). So Instinct can ask a running session what it did, or hand it a task, and read the answer off its screen; it cannot open or close terminals here, only its own under `/api/agents`. A key sees every screen, the laptop's included while it is linked.
- A key reaches those routes, `/api/ping`, `/api/openapi.json` and `/api/agents/<name>` with its `/push` and `/discard`. Everything else answers 403 to it.

### Accounts

The board's **accounts** page (the ⋯ button) lists every Claude account stored with [cswap](https://pypi.org/project/claude-swap/), with each account's 5-hour and 7-day usage.

- **+ add**: open the sign-in link, log in on claude.ai with the new account, paste the code it shows into the board. The board signs in a separate config dir, runs `cswap add` from there, and leaves the VPS's live login alone. Never run `/logout`: it drops the stored accounts.
- Click an account to switch the VPS to it (`cswap switch`).
- `femme-cswap.service` runs `cswap auto --threshold $CAP`: when the active account passes `CAP` it switches to the account with the most left, so agents only pause once every account is past `CAP` (keep it 50-99). `femme-fable-cap.service` does the same for the Fable weekly limit at `FABLE_CAP` (96%): an account past it is held out of rotation (`cswap disable`) until its week resets, and the box moves to the account with the most left.
- `bootstrap.sh` installs cswap and saves the VPS's current login as account 1.
- **AWS**: the page also shows who the VPS's AWS CLI runs as: the instance role (see *The box's own AWS access*). `bootstrap.sh` installs the AWS CLI.

## Files

| File | Runs on | Does |
|---|---|---|
| `provision.sh` | laptop | Creates the instance. Safe to rerun; reuses everything tagged `femme`. |
| `migrate-region.sh` | laptop | Moves the box to another region by copying its disk; see above. |
| `cloud-init.yaml` | VPS, first boot | Your user (same name as on the laptop, so paths match), key-only SSH, mosh, 8 GB swap, linger. |
| `sync.sh` | laptop | Copies config: `~/.claude` minus credentials and history, herdr, mise. Merges onboarding, trust and portable MCP servers into the VPS `~/.claude.json`. |
| `sync-dir.sh` | laptop | Puts one folder in live two-way sync with the VPS, minus its `.femme-ignore`. |
| `pc-setup.sh` | laptop | Lets `pc` on the VPS run commands here. |
| `pc.sh` | VPS | `pc <command>`: runs it on the laptop in the same folder, sync flushed around it. |
| `rules/pc.md` | VPS | Tells Claude and Codex when to use `pc`. |
| `bootstrap.sh` | VPS | Installs mise toolchains, agents, herdr and the systemd units; builds the board. |
| `deploy.sh` | VPS | On a timer: deploys `main` after a merge. |
| `notify.sh` | VPS | Polls `herdr api snapshot`, pushes to ntfy on `blocked` and `done`. |
| `fork-remote.sh` | laptop | The herdr plugin action: fork to the VPS. |
| `files.sh`, `files-pane.sh` | VPS | The plugin's drop box: action and pane. Files dragged from the laptop land in the agent's folder. |
| `hooks/subagent-model.sh` | VPS | Claude hook: subagents run on Opus or Sonnet, never Fable. A Fable request becomes Opus; a fork from a Fable session is refused with the fix in the reason. |
| `skills/write-in-turkish/` | VPS | Claude skill: anything that must be written in Turkish is drafted in English and put into Turkish by the `codex` CLI (OpenAI model), then checked. |
| `board/` | VPS | The issues board server (Rust). |
| `worker.sh` | VPS | Runs board issues as herdr Claude agents within the budget. |
| `systemd/femme-cswap.service` | VPS | Auto-rotates Claude accounts at `CAP`. |
| `fable-cap.sh`, `systemd/femme-fable-cap.service` | VPS | Auto-rotates Claude accounts at `FABLE_CAP` of the Fable weekly limit. |
| `systemd/herdr-instinct.service` | VPS | The herdr session Instinct's terminals run in. |
| `systemd/mutagen.service` | laptop | Keeps sync sessions running across reboots. |
| `systemd/femme-link.service` | laptop | Puts the laptop's herdr terminals on the board and its sshd within reach of `pc`. |

## Cost

m7i-flex.xlarge (4 vCPU, 16 GB) in eu-west-2 plus 250 GB gp3 and a public IPv4 comes to about $180/month on-demand. Termination protection is on.
