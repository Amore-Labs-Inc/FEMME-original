# Install

Everything starts on your laptop (Linux or macOS), from a checkout of this repo:

```sh
git clone <this repo> femme && cd femme
./install.sh
```

`install.sh` asks a few questions, writes the answers to `.env` (readable only by you; secrets are not shown while you type), prepares the server, installs FEMME on it and runs `./doctor.sh`. At the end it lists what is left for you. Run it again any time to change an answer: it keeps what `.env` already has.

## What it does for you, and what you do

| `install.sh` does | You do |
|---|---|
| checks the tools this laptop needs, makes an SSH key if you have none | have a server: an AWS account, or an Ubuntu 24.04 VPS with an account that can `sudo` |
| writes `.env`, with a random notification topic | sign in on the server once: `claude` then `/login`; `gh auth login && gh auth setup-git` |
| prepares the server: your user, key-only SSH, swap, packages, start at boot | for a public board only: a DNS A record, and a Resend key if you want emailed sign-in links |
| installs herdr, the agents and their toolchains, the board and the services | optional: `./laptop/laptop-setup.sh`, the phone apps |
| adds `Host <alias>` to `~/.ssh/config` and checks everything | |

FEMME never copies your credentials to the server: you sign in there yourself.

## Where it can run

| Option | Status | Limits |
|---|---|---|
| **An Ubuntu 24.04 server you already have**, x86_64 or arm64 (any VPS, a home server, a local VM) | main target | other distributions are not supported |
| **A new AWS instance** (`provision.sh`) | helper, optional | needs the AWS CLI signed in; it costs money (see [costs](costs.md)) |
| **This machine** (Linux with systemd) | works | agents stop when the machine sleeps; forking to "the server" makes no sense here |
| macOS as the server | not supported | needs systemd and apt |
| Docker | not offered | herdr and the agents want a full user environment |

The laptop side (forking agents, the drop box, `laptop-setup.sh`) works on Linux with systemd and on macOS. macOS support is new: please report what does not work. `pc` (building on the laptop) needs a Linux laptop.

### 1. A server you already have

You need an account on it that can `sudo` (often `root` or `ubuntu`) and your SSH key on it. `install.sh` asks for that account as `user@address` and runs [`host-init.sh`](../laptop/host-init.sh), which:

- makes a user with the same name as on your laptop, so synced folders keep their paths;
- gives it your key and passwordless `sudo`;
- installs mosh, git, jq, rsync, curl and build tools, adds 8 GB of swap if there is none, keeps your services running after you log out;
- turns off password and root login over SSH, only after your key works.

### 2. A new AWS instance

`install.sh` runs [`provision.sh`](../laptop/provision.sh): an Ubuntu 24.04 instance (`INSTANCE_TYPE`, `DISK_GB`, `REGION` in `.env`), a security group with SSH and mosh open, an Elastic IP and termination protection. It reuses everything tagged `femme`, so it is safe to rerun. By default the instance gets no AWS access; see [AWS](aws.md) for the optional role and for a spend brake.

### 3. This machine

Choose it on a Linux machine that stays on (a home server or a desktop). FEMME then runs here and is reached over `ssh localhost`, so `ssh localhost` must work with your key.

## The board: private or public

- **Private (default):** the board listens on the server's localhost only. Open it through a tunnel: `ssh -N -L 8787:127.0.0.1:8787 <alias>`, then http://localhost:8787. Without Resend, the sign-in link is in `ssh <alias> journalctl --user -u femme-board -n 20`.
- **Public:** for a bot or agent that calls the API from another machine. `install.sh` asks for an `https://` address; point a DNS A record (DNS only, no proxy) at the server, open ports 80 and 443 if your provider has a firewall (`provision.sh` opens them on AWS), and run `./laptop/sync.sh`. Caddy gets the certificate. Read [SECURITY.md](../SECURITY.md) first.

## Check, update, remove

```sh
./doctor.sh                # every check, each problem with its fix
./install.sh update        # pull this checkout, update the server, check
./uninstall.sh server      # services, board and FEMME's files on the server (asks first)
./uninstall.sh laptop      # this laptop's part (asks first)
./uninstall.sh aws         # lists what provision.sh made, with the commands to delete it; deletes nothing
```

## By hand, without install.sh

```sh
cp .env.example .env && chmod 600 .env       # then edit it: every setting is explained there
./laptop/provision.sh                              # AWS only; or, for any other server:
./laptop/host-init.sh root@203.0.113.7
./laptop/sync.sh                                   # copies agent and herdr config, runs bootstrap.sh on the server
ssh agentbox                                # sign in: claude (/login), gh auth login && gh auth setup-git
./doctor.sh
```

`sync.sh` copies from your laptop: `~/.claude` (instructions, rules, skills, agents, hooks, settings, keybindings, plugins; never credentials or history), herdr's config and plugins, and mise's tool list (`~/.config/mise/config.toml`), which decides what else `bootstrap.sh` installs (Codex, Pi, language toolchains). Claude Code and the GitHub CLI are installed either way. MCP servers are copied only if you name them in `CLAUDE_MCP`.
