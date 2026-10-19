# FEMME

Always-on [herdr](https://herdr.dev) on an AWS VPS. Start agents from your laptop or iPhone, close the lid, come back later: they kept running on the VPS's CPU and RAM, and you find them where they ended up.

- `herdr server` runs as a systemd user unit with linger, so it starts at boot and never depends on a client being attached.
- Panes survive SSH drops and lid closes. After a VPS reboot herdr restores the layout, resumes agent conversations and replays screen history.
- ntfy push to your phone when an agent is blocked or done.
- mosh for the phone, so wifi/cellular switches and sleep don't kill the session.
- A herdr plugin that forks a local agent (conversation + working tree) onto the VPS.

## Setup

Needs: AWS CLI logged in, `~/.ssh/id_ed25519`, herdr, jq, rsync.

```sh
./provision.sh                              # VPS + security group + Elastic IP, writes .env and ~/.ssh/config "Host agentbox"
ssh agentbox cloud-init status --wait
./sync.sh                                   # copies agent/herdr config, runs bootstrap.sh on the VPS
ssh agentbox                                # one-time logins, credentials are never copied:
#   claude            -> /login, paste the URL
#   codex login --device-auth
#   gh auth login && gh auth setup-git
./sync.sh                                   # again: now clones your repos and copies their .env files
```

Defaults live in `.env` (`REGION`, `INSTANCE_TYPE`, `DISK_GB`, `HOST`). `.env` is gitignored and holds your IP and ntfy topic.

### Laptop

```sh
herdr machine add agentbox --label agentbox --remote-session default
herdr plugin link "$PWD"                    # or: herdr plugin install Darkosxl/FEMME --yes
```

Add to `~/.config/herdr/config.toml`, then `herdr server reload-config`:

```toml
[[keys.command]]
key = "prefix+shift+v"
type = "plugin_action"
command = "femme.fork-remote"
description = "fork agent to VPS"
```

Local and VPS workspaces show side by side. Local ones die when the laptop sleeps; `prefix+shift+v` on a local agent forks it to the VPS and leaves the local one running. It copies the repo (uncommitted changes and `.env*` included, other gitignored files not) and the session file. Works for Claude Code, Codex and Pi.

### iPhone

1. Install **Moshi** (or Blink Shell) and **ntfy**.
2. In Moshi, generate a key and copy the public key. On the laptop: `ssh agentbox 'cat >> ~/.ssh/authorized_keys'`, paste, Ctrl-D.
3. Add host: `darkwarro@<IP from .env>`, mosh on, command `herdr`.
4. In ntfy, subscribe to the `NTFY_TOPIC` from `.env`. Anyone who knows the topic can read your pushes, so keep it secret.

## Files

| File | Runs on | Does |
|---|---|---|
| `provision.sh` | laptop | Creates the instance. Safe to rerun; reuses everything tagged `femme`. |
| `cloud-init.yaml` | VPS, first boot | Your user (same name as on the laptop, so paths match), key-only SSH, mosh, 8 GB swap, linger. |
| `sync.sh` | laptop | Copies config (`~/.claude` minus credentials and history, herdr, mise), repos, and `.env` files. |
| `bootstrap.sh` | VPS | Installs mise toolchains, agents, herdr and the systemd units. |
| `notify.sh` | VPS | Polls `herdr api snapshot`, pushes to ntfy on `blocked` and `done`. |
| `fork-remote.sh` | laptop | The herdr plugin action. |

## Cost

m7i-flex.xlarge (4 vCPU, 16 GB) in eu-west-2 plus 100 GB gp3 and a public IPv4 comes to about $165/month on-demand. Termination protection is on.
