# Slack bot for a firstmate home

This guide gives one person's firstmate home its own Slack bot, such as "Yelen's Firstmate".
With the bot, firstmate posts reports and decisions as the bot instead of as your own Slack account.
You can DM the bot or reply in its threads, and firstmate's answers come back in the same DM or thread.
Each person runs their own bot against their own home, so a second person repeats these steps with their own name, ids, and Mac.

[Slack bridge](configuration.md#slack-bridge-configslack-bridge) owns the config schema and the delivery rules; this guide is the setup path.
Setup takes about ten minutes.

## Before you start

- A Mac with the firstmate home you want the bot to serve, and `node` on `PATH`.
- A Slack workspace where you may create and install an app; some workspaces need an admin to approve the install.
- Your own Slack member id: open your profile, choose the three-dot menu, and pick "Copy member ID" (it starts with `U`).
- The id of each channel the bot posts to: open the channel name, and the id (starting with `C`) is at the bottom of the About tab.
  A bot has no scope to look up channels by `#name`, so a bot setup needs channel ids.

## 1. Create the Slack app

Print the manifest with your bot's name, run from the home:

```sh
bin/fm-slack-bridge.sh manifest --name "Yelen's Firstmate"
```

Add `--private-channels` if a report or decisions channel is private.
The manifest asks only for these bot scopes: `chat:write` to post, `channels:history` (and `groups:history` for private channels) to read replies in its channels, `im:history` to read your DM with it, and `im:write` to open that DM.

1. Open https://api.slack.com/apps and choose "Create New App", then "From a manifest".
2. Pick the workspace, paste the printed YAML, and create the app.
3. Open "Install App", install it to the workspace, and allow the requested access.
4. Copy the "Bot User OAuth Token" (it starts with `xoxb-`) for the next step only.

## 2. Store the token in the Keychain

The token lives only in your macOS login Keychain.
Never put it in a file, an environment variable, a chat, or the firstmate config.

```sh
security add-generic-password -a "$USER" -s firstmate-slack-bot -U -w
```

`-w` at the end makes `security` prompt for the token, so it never lands in shell history; paste the token at the prompt.
`firstmate-slack-bot` is the Keychain service name the config points at; any name of letters, digits, dots, dashes, and underscores works.

## 3. Configure the home

Write `config/slack-bridge` in the home:

```sh
report-channel=C0123REPORT
decisions-channel=C0123DECIDE
captain-user=U0123YOURID
bot-keychain-service=firstmate-slack-bot
poll-seconds=60
```

`captain-user` is your own member id: only your messages reach this home, matched by exact id, never by display name.

## 4. Invite the bot

In each configured channel, send `/invite @Yelen's Firstmate`, using your bot's name.
The bot reads and posts only in channels it is a member of, plus its DM with you.

## 5. Verify end to end

```sh
bin/fm-slack-bridge.sh arm
bin/fm-slack-bridge.sh verify
```

`verify` is a manual setup command: only run it when a person explicitly chooses to test the setup. `arm`, `check`, the watcher, and other automation never invoke it.
It checks the token and sends one clearly labeled one-time setup test to each channel and to you by DM; these messages can be ignored or deleted. Reply to the DM to confirm the round trip.
It prints `bot: <bot id> in team <team id>`, one `posted test` line per channel, and one `posted dm` line.
A `not_in_channel` failure means the bot still needs an invite to that channel.

Then prove the round trip:

1. Reply to the bot's DM, for example `ping`.
2. Within one poll interval, or at once with `bin/fm-slack-bridge.sh check`, firstmate receives it as a captain inbox note (`bin/fm-inbox.sh list` shows it).
3. Firstmate answers with `bin/fm-inbox.sh reply <note-id> <text>`, and the answer appears in the DM.

## Two people, two bots

Each person creates their own app, stores their own token in their own Keychain, and sets `captain-user` to their own member id.
Both bots may share a channel safely: each home delivers only its own person's messages and ignores every bot message, so the bots never answer each other.

## Changing or removing the bot

- To rotate the token, reinstall the app or regenerate the token, then run the `security add-generic-password` command again; `-U` replaces the stored item.
- After changing scopes in the app, reinstall it so the token carries them.
- To go back to posting as your own account through `slack-axi`, delete the `bot-keychain-service` line and use `#name` or id channels as before.
- To remove the token: `security delete-generic-password -s firstmate-slack-bot`.

## Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `no Keychain item with service ...` | The token is not stored under that service name, or the Keychain is locked; store it again or unlock the login Keychain. |
| `invalid_auth` or `token_revoked` | The stored token is wrong or revoked; reinstall the app and store the new token. |
| `missing_scope` | The app was installed before its scopes changed; reinstall it. |
| `not_in_channel` or `channel_not_found` | Invite the bot to the channel; for a private channel, regenerate the manifest with `--private-channels` and reinstall. |
| `needs every channel as a channel id` | Replace each `#name` in `config/slack-bridge` with the channel id. |
