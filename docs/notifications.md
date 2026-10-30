# Notifications

FEMME pushes a notification to your phone when an agent needs you (it is waiting for an answer) or is done. It uses [ntfy.sh](https://ntfy.sh), free and with no account.

1. Install the **ntfy** app (iOS or Android).
2. Subscribe to the `NTFY_TOPIC` from your `.env`. `install.sh` made a random one.

Anyone who knows the topic can read your notifications, so keep it secret. To use your own ntfy server instead, change the URL in `server/notify.sh`.
