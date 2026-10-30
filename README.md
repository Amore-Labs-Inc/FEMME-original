# FEMME

Always-on [herdr](https://herdr.dev) on your own Linux server. Start coding agents (Claude Code, Codex, Pi) from your laptop, your phone or a chat bot, close the lid, come back later: they kept running on the server, and you find them where they ended up.

```
  laptop ──── ssh, two-way folder sync ────┐
  phone (optional) ──── mosh, ntfy ────────┤        your server (Ubuntu 24.04)
  chat bot (Instinct) ── HTTPS API ────────┼──────▶  herdr ── Claude Code / Codex / Pi
  browser ──── board ──────────────────────┘         board · worker · notifications
```

- **Agents keep running.** herdr runs as a service that starts at boot. Terminals survive SSH drops and lid closes; after a reboot herdr restores the layout and resumes the agents' conversations.
- **Move an agent to the server.** One key in herdr forks a local agent, with its conversation and folder, onto the server. The folder then stays in two-way sync, so the server's work shows up on the laptop when it wakes.
- **Board and API.** A small web panel: an issue queue that agents turn into pull requests, live terminals, sessions. Its API lets a chat bot (like [Instinct](https://instinct.com/) on WhatsApp) or another agent hand tasks to a standing Claude Code session, read a short report and push or discard the changes.
- **Notifications** on your phone when an agent needs you or is done.

## Example: Instinct on WhatsApp

We run FEMME this way. We write to [Instinct](https://instinct.com/) on WhatsApp: "fix the signup form in our repo". Instinct hands the task to FEMME through its API. Claude Code does the work on the server, checks it and writes a short report in plain words. Instinct sends us the report, and nothing is pushed until we answer "yes". No laptop and no terminal needed. See [API](docs/api.md).

## Quick start

On your laptop (Linux or macOS):

```sh
git clone <this repo> femme && cd femme
./install.sh
```

It asks where FEMME should run (an Ubuntu 24.04 server you have, a new AWS instance, or this machine) and which optional parts you want. Then it prepares the server, installs everything and checks it. It does most of the work; **you** bring the server and sign in on it once (`claude` → `/login`, `gh auth login`). The [install guide](docs/install.md) lists exactly what is automatic and what is not.

Afterwards: `./doctor.sh` checks everything, `./install.sh update` updates, `./uninstall.sh` takes it off.

## Docs

| | |
|---|---|
| [Install](docs/install.md) | where it can run, what `install.sh` does, the board private or public, by hand |
| [Laptop](docs/laptop.md) | forking agents, folder sync, drop box, building on the laptop with `pc` |
| [API](docs/api.md) | use FEMME from a chat bot or another agent; a [minimal client](examples/api-client.sh) |
| [Board](docs/board.md) | issues, terminals and sessions in the browser |
| [Phone](docs/phone.md) | optional: a terminal and notifications on the phone |
| [Claude accounts](docs/accounts.md) | the accounts window, optional rotation between accounts |
| [AWS](docs/aws.md) | the optional instance role, a spend brake |
| [Troubleshooting](docs/troubleshooting.md) | common errors and their fixes |
| [Costs](docs/costs.md) | what you pay for, what is optional |
| [Contributing](CONTRIBUTING.md) | how the pieces fit, how to change them |

## Requirements

- Laptop: Linux or macOS with `ssh`, `rsync`, `jq`, `git`, `curl`. herdr and [Mutagen](https://mutagen.io) only for forking agents and folder sync.
- Server: Ubuntu 24.04 on x86_64, reachable over SSH, with a user that can `sudo`; or an AWS account, and `provision.sh` makes one.
- Accounts: Claude (for Claude Code) and GitHub. Optional: Codex or Pi, a domain and Resend for a public board.

## Security

Agents on the server run without permission prompts, and anything running as your user there can use what the server can reach. The parts that widen that (public board, AWS role, auto-deploy, account rotation) are off until you turn them on. Read [SECURITY.md](SECURITY.md) before you do.

## License

Apache-2.0, see [LICENSE](LICENSE). FEMME builds on [herdr](https://herdr.dev) and other tools it installs but does not include; see [NOTICE](NOTICE).
