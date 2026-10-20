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

Defaults live in `.env` (`REGION`, `INSTANCE_TYPE`, `DISK_GB`, `HOST`). `.env` is gitignored and holds your IP and ntfy topic.

### Laptop

```sh
herdr machine add agentbox --label agentbox --remote-session default
herdr plugin link "$PWD"                    # or: herdr plugin install Darkosxl/FEMME --yes
cp systemd/mutagen.service ~/.config/systemd/user/ && systemctl --user enable --now mutagen
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

## Issues board

Set `BOARD_EMAIL`, `BOARD_URL`, `RESEND_API_KEY`, `MAIL_FROM` in `.env`, point an A record (DNS only) for `BOARD_URL`'s host at the VPS, rerun `./provision.sh` (opens 80/443) and `./sync.sh`.

- Sign in with a magic link sent to `BOARD_EMAIL` (once, 15 minutes); the cookie lasts 7 days.
- Add an issue: pick a repo, describe the work. The worker clones it to `~/femme-work`, creates branch `femme/issue-N`, and runs Claude in a herdr workspace named `#N ...`, so you can watch or step in from the phone.
- Finished work arrives as a PR with `FEMME issue #N` in its body. The card moves to **PR ready**; after merging, press **Merged, done** and the workspace closes.
- **Chat** on a card opens that agent's live screen: reply, press 1/2/3/Enter/Esc, or end it.
- **Terminals** tab: every VPS workspace. Open a new one (shell, Claude, Codex or Pi) in any folder under `$HOME`, chat with it the same way, or close it.
- Merging to `main` deploys itself: every 20 seconds `femme-deploy.timer` checks GitHub, and when `main` moved it checks it out in `~/femme` and reruns `bootstrap.sh` (rebuilds the board, restarts board and worker). The board shows `deploying`, then `deployed <commit>` or why it failed, until you close it; a failed build leaves the old board running. `./sync.sh` still pushes your unmerged laptop copy.
- Budget: at most `PARALLEL` (2) issues at once. When the 5-hour window passes `CAP` (60%), running agents are interrupted and continue after the reset, so the rest of the window is yours. Set both in `.env`.

### Accounts

The board's **accounts** window lists every Claude account stored with [cswap](https://pypi.org/project/claude-swap/), with each account's 5-hour and 7-day usage.

- **+ add**: open the sign-in link, log in on claude.ai with the new account, paste the code it shows into the board. The board signs in a separate config dir, runs `cswap add` from there, and leaves the VPS's live login alone. Never run `/logout`: it drops the stored accounts.
- Click an account to switch the VPS to it (`cswap switch`).
- `femme-cswap.service` runs `cswap auto --threshold $CAP`: when the active account passes `CAP` it switches to the account with the most left, so agents only pause once every account is past `CAP` (keep it 50-99).
- `bootstrap.sh` installs cswap and saves the VPS's current login as account 1.

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
| `systemd/mutagen.service` | laptop | Keeps sync sessions running across reboots. |

## Cost

m7i-flex.xlarge (4 vCPU, 16 GB) in eu-west-2 plus 250 GB gp3 and a public IPv4 comes to about $180/month on-demand. Termination protection is on.
