# Costs

FEMME itself is free. What you pay for, and what is optional:

| What | Needed? | Roughly |
|---|---|---|
| A server: Ubuntu 24.04 x86_64, 8–16 GB RAM is comfortable for a few agents | yes | a small VPS from many providers: well under $50/month. On AWS, `provision.sh`'s default (m7i-flex.xlarge: 4 vCPU, 16 GB, plus a 100 GB disk and a public IPv4) is roughly $150–180/month on demand. A home server: your electricity. |
| Claude Code: a Claude subscription or API account | yes | your plan's price; agents use your plan's limits |
| GitHub account (the worker opens PRs, the API pushes) | yes | free |
| Codex or Pi | optional | their own plans |
| A domain, for the public board only | optional | about $10–15/year |
| Resend, for emailed sign-in links | optional | free tier is enough; without it, links appear in the server log |
| ntfy.sh notifications, Moshi or Blink on the phone | optional | free, or the apps' own prices |

Prices change; check your provider's. On AWS, set a spend brake (see [AWS](aws.md)): agents with `AWS_ROLE=spawn` can launch instances that cost money too.
