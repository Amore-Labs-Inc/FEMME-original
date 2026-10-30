# Security

FEMME gives AI agents a server of their own and runs them without anyone at the keyboard. Know what that means before you install it.

## What to know

- **Agents run without permission prompts.** Every Claude Code session on the server runs in `bypassPermissions` mode, because nobody is there to answer prompts. An agent can do anything your server user can. Treat text the agents read (issues, cloned repos, web pages) as a way in for prompt injection.
- **Your server user is the trust boundary.** Anything running as that user, agents included, can read the other terminals, use the server's GitHub login, and use whatever cloud credentials the server has.
- **Linking your laptop extends that boundary.** While `femme-link.service` runs, the server can type into the laptop's herdr terminals. After `pc-setup.sh`, it can also run commands on the laptop over SSH, as you. Both only work while the laptop holds the link open.
- **API keys see every terminal.** A key made on the board can read every terminal's screen and type into it, including the laptop's while it is linked. Give keys only to agents you trust as much as yourself, and revoke them on the board when you no longer need them.
- **ntfy topics are public.** Anyone who knows your `NTFY_TOPIC` can read your notifications. Keep it secret, or run your own ntfy server.

## Safe defaults

These parts are off unless you turn them on in `.env`:

| Setting | When on |
|---|---|
| `BOARD_PUBLIC=1` | The board is served on the internet (HTTPS, magic-link sign-in). Off: it listens on the server's localhost only, and you reach it through an SSH tunnel. |
| `AWS_ROLE=spawn` | The server may launch the instance types in `SPAWN_TYPES` in its region. Off: it has no AWS access. |
| `AUTODEPLOY=1` | The server deploys `main` from GitHub on its own. Anyone who can merge can then run code on it. |
| `ACCOUNT_ROTATION=1` | The server switches between stored Claude accounts by usage. |

SSH is key-only (`cloud-init.yaml`). SSH and mosh are open to the internet so the phone can connect. If you use a VPN such as Tailscale, you can close them to everything else.

## Reporting a vulnerability

Please report it privately through GitHub: **Security → Report a vulnerability** on this repository. Don't open a public issue. We aim to answer within a week.
