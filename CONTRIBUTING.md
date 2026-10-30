# Contributing

Thanks for helping. One rule shapes everything here: **FEMME stays small.** It is a thin layer that keeps herdr and coding agents running on your own server. Fixes, clearer docs, easier installs and support for more setups are welcome. New features are a hard sell: open an issue first and say what problem they solve.

## Before you open a PR

- **Board (Rust):** `cargo test --manifest-path board/Cargo.toml`. The board has five dependencies; adding one needs a good reason.
- **Shell scripts:** `bash -n <file>` and `shellcheck <file>`. CI fails on shellcheck errors.
- **Laptop-side scripts** (`install.sh`, `lib.sh`, `doctor.sh`, `uninstall.sh`, `laptop-setup.sh`, `provision.sh`, `host-init.sh`, `sync.sh`) must run under **bash 3.2** (what macOS ships) and with **BSD tools**: no `sed -i` without a suffix, no `readarray`, no `${var,,}`. Server-side scripts can assume Ubuntu 24.04.
- **Anything that changes the install:** run it on a fresh Ubuntu 24.04 server (`./install.sh`, then `./doctor.sh` all green, then `./uninstall.sh server`), and say so in the PR.
- **No secrets, no personal data:** no keys, tokens, IPs, email addresses, hostnames or private repo names, in code, tests, docs or examples. Use `example-org/example-repo`, `203.0.113.7`, `hello@example.com`. CI runs gitleaks.
- **Safe defaults:** anything that widens what the server or its agents can do (network exposure, cloud permissions, running code from elsewhere) is off by default and explained in `.env.example` and [SECURITY.md](SECURITY.md).

## Visuals

The README images are HTML pages in `assets/src/`, in the Exposure brand: Geist, Academy Cream, Exposure Blue as the one accent, and the parent brand's blue-violet-ember glow on dark. Each renders in a light and a dark version; GitHub shows the one that matches the reader's theme. Every card says something true about FEMME. To change one, edit its page and run `assets/src/render.sh` (needs Google Chrome). Keep text in images short, and put the same meaning in the image's `alt`.

## How the pieces fit

| File | Runs on | Does |
|---|---|---|
| `install.sh` | laptop | The one entry point: questions, `.env`, server, check. `update` pulls and updates. |
| `host-init.sh` | laptop | Prepares an existing Ubuntu 24.04 server over ssh, as `cloud-init.yaml` does on AWS. |
| `doctor.sh` | laptop | Checks the installation; each problem comes with the fix. |
| `uninstall.sh` | laptop | Takes FEMME off the server or the laptop; lists AWS resources without deleting them. |
| `laptop-setup.sh` | laptop | herdr machine, plugin, keys and the background services (Linux or macOS). |
| `lib.sh` | laptop | Helpers the laptop scripts share. |
| `provision.sh` | laptop | Creates the instance. Safe to rerun; reuses everything tagged `femme`. |
| `cloud-init.yaml` | VPS, first boot | Your user (same name as on the laptop, so paths match), key-only SSH, mosh, 8 GB swap, linger. |
| `sync.sh` | laptop | Copies config: `~/.claude` minus credentials and history, herdr, mise. Merges onboarding, trust and portable MCP servers into the VPS `~/.claude.json`. |
| `sync-dir.sh` | laptop | Puts one folder in live two-way sync with the VPS, minus its `.femme-ignore`. |
| `pc-setup.sh` | laptop | Lets `pc` on the VPS run commands here. |
| `pc.sh` | VPS | `pc <command>`: runs it on the laptop in the same folder, sync flushed around it. |
| `rules/pc.md` | VPS | Tells Claude and Codex when to use `pc`. |
| `bootstrap.sh` | VPS | Installs mise toolchains, agents, herdr and the systemd units; builds the board. |
| `deploy.sh` | VPS | Optional (`AUTODEPLOY=1`), on a timer: deploys `main` after a merge. |
| `notify.sh` | VPS | Polls `herdr api snapshot`, pushes to ntfy on `blocked` and `done`. |
| `fork-remote.sh` | laptop | The herdr plugin action: fork to the VPS. |
| `files.sh`, `files-pane.sh` | VPS | The plugin's drop box: action and pane. Files dragged from the laptop land in the agent's folder. |
| `board/` | VPS | The issues board server (Rust). |
| `worker.sh` | VPS | Runs board issues as herdr Claude agents within the budget. |
| `systemd/femme-cswap.service` | VPS | Optional: auto-rotates Claude accounts at `CAP`. |
| `fable-cap.sh`, `systemd/femme-fable-cap.service` | VPS | Optional: auto-rotates Claude accounts at `FABLE_CAP` of the Fable weekly limit. |
| `systemd/herdr-instinct.service` | VPS | The herdr session the API's standing sessions run in. |
| `systemd/mutagen.service` | laptop | Keeps sync sessions running across reboots. |
| `systemd/femme-link.service` | laptop | Puts the laptop's herdr terminals on the board and its sshd within reach of `pc`. |

## Security issues

Not in a public issue: see [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE).
