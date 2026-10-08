# Slack bot for a firstmate home

This guide gives one person's firstmate home its own Slack bot, such as "Yelen's Firstmate".
With the bot, firstmate posts reports and decisions as the bot instead of as your own Slack account.
You reach firstmate by DMing the bot, by tagging it (`@Yelen's Firstmate ...`) in the report or decisions channel, or by replying in the thread of one of its posts.
Firstmate's answers come back in the same DM or thread.
Each person runs their own bot against their own home, so a second person repeats these steps with their own name, ids, and Mac.

[Slack bridge](configuration.md#slack-bridge-configslack-bridge) owns the config schema and the delivery rules; this guide is the setup path and the daily use.

## Speedrun: let your firstmate run it

Tell your own firstmate: "Follow docs/slack-bot.md and set up my Slack bot."
The setup steps below are written as agent instructions: each one says who acts, what to run, how to check it, and where to stop.
Your firstmate runs every step it can, asks Jev for the closed-set picks, and stops at each step marked as yours until you say it is done.
The whole run takes about ten minutes, most of it your three Slack clicks.

Every step carries one owner tag:

- **[you]** - only the person can do it (a Slack consent click, the token paste, or the channel invite), so the agent stops, tells the person exactly what to do, and waits.
- **[agent]** - the person's firstmate (or any agent in that home) runs it and checks the result.
- **[Jev]** - a closed-set pick the agent puts through one typed Jev call (`bin/fm-jev.sh`); when Jev escalates or does not answer, the agent asks the person instead.

Rules for the agent running this guide:

- Run every command from the firstmate home the bot will serve.
- Never ask for, print, store, or log the bot token; the person pastes it straight into the Keychain prompt.
- After each step, run its check; on a failed check, use [Troubleshooting](#troubleshooting) before moving on.
- At a stop point, send the person the exact instruction from that step and wait for their "done".

## Before you start

| Input | Who | Where it comes from |
| --- | --- | --- |
| A Mac with the home and `node` on `PATH` | [agent] | `command -v node` prints a path. |
| A Slack workspace where you may install an app | [you] | Some workspaces need an admin to approve the install. |
| The bot's name, at most 35 characters | [Jev] | Step 1. |
| Your Slack member id (`U...`) | [agent] or [you] | Step 5. |
| The report and decisions channel ids (`C...`, or `G...` for private) | [agent] or [you] | Step 5. |

## Setup

### 1. Pick the name and channel type - [Jev]

Two closed-set picks, batched into one Jev call:

- Bot name: `"<First name>'s Firstmate"` is the default; another name only if the person asked for one.
- Channel type: whether the report or decisions channel is private (`yes` adds `--private-channels` and the `groups:history` scope; `no` keeps the minimal public scopes).

Check: both answers are known before step 2.

### 2. Create the app from the prefilled link - [agent], then [you]

[agent] Print the link:

```sh
bin/fm-slack-bridge.sh manifest --name "Marco's Firstmate" --link
```

Add `--private-channels` when step 1 said a channel is private.
The link opens `https://api.slack.com/apps?new_app=1&manifest_json=...` with the whole app manifest filled in.
It asks only for these bot scopes: `chat:write` to post, `channels:history` (and `groups:history` for private channels) to read its channels, `im:history` to read your DM with it, and `im:write` to open that DM.
`bin/fm-slack-bridge.sh manifest --name "..."` without `--link` prints the same manifest as YAML, for pasting into "Create New App -> From a manifest" by hand.

**Stop point [you]:** open the link, pick the workspace, review the manifest, and choose "Create".

Check: the person reports the app's settings page is open.

### 3. Install the app - [you]

**Stop point [you]:** in the app's settings, open "Install App", choose "Install to Workspace", and allow the requested access.
Then copy the "Bot User OAuth Token" (it starts with `xoxb-`) for step 4 only; never paste it into a chat or a file.

Check: the person reports the token is copied.

### 4. Store the token in the Keychain - [you], then [agent]

The token lives only in the person's macOS login Keychain.

**Stop point [you]:** open a normal terminal window (Terminal, iTerm, Ghostty), not an agent session, and run:

```sh
security add-generic-password -a "$USER" -s firstmate-slack-bot -U -w
```

`-w` at the end makes `security` prompt for the token, so it never lands in shell history; paste the token at the prompt, twice when asked.
Do not run this through Claude Code's `!` prefix or any other agent shell: those have no interactive prompt, so `security` stores an empty item.
`firstmate-slack-bot` is the Keychain service name the config points at; a different name of letters, digits, dots, dashes, and underscores also works, for example when two people share one Mac.

[agent] Check, without ever printing the token:

```sh
security find-generic-password -s firstmate-slack-bot -w | grep -q '^xoxb-' && echo token-ok
```

It must print `token-ok`.
Nothing printed means the item is empty or missing: go back to the stop point.

### 5. Find the member and channel ids - [agent], or [you] as fallback

[agent] When `slack-axi` is logged in to the same workspace:

```sh
slack-axi channels --match "reports"
slack-axi members C0123REPORT
```

Replace `reports` with a distinctive part of the channel name and use the matching channel id in the `members` command.
The first column of `channels` is the channel id; `members` shows member ids (`U...`) so the agent can identify the person's exact id.

[you] Fallback when no `slack-axi` login exists:

- Member id: in Slack, open your profile, choose the three-dot menu, and pick "Copy member ID".
- Channel id: open the channel name; the id is at the bottom of the About tab.

A bot has no scope to look up channels by `#name`, so a bot setup needs channel ids.
Check: one `U...` id and two `C...` or `G...` ids are known (the two may be the same channel).

### 6. Write the config - [agent]

Write `config/slack-bridge` in the home:

```sh
report-channel=C0123REPORT
decisions-channel=C0123DECIDE
captain-user=U0123YOURID
bot-keychain-service=firstmate-slack-bot
poll-seconds=60
```

`captain-user` is the person's own member id: only their messages reach this home, matched by exact id, never by display name.
Check: `bin/fm-slack-bridge.sh check` prints nothing about the config (an invalid value prints one `slack:` line naming it).

### 7. Invite the bot - [you]

**Stop point [you]:** in each configured channel, send `/invite @Marco's Firstmate`, using the bot's name.
The bot reads and posts only in channels it is a member of, plus its DM with you.

Check: step 8's `verify` posts to both channels without `not_in_channel`.

### 8. Arm and verify - [agent], then [you]

[agent] Run:

```sh
bin/fm-slack-bridge.sh arm
bin/fm-slack-bridge.sh verify
```

`arm` registers the standing poll and starts the DM and channel mentions at "now", so older history is never replayed.
`verify` is a manual setup command, never run by automation; its effects are documented in [Slack bridge](configuration.md#slack-bridge-configslack-bridge).
It must print `bot: <bot id> in team <team id>`, one `posted test` line per channel, and one `posted dm` line.

**Stop point [you]:** reply `ping` to the bot's setup DM, and post `@Marco's Firstmate ping` as a new message in the report channel.

[agent] Check the round trip:

1. Run `bin/fm-slack-bridge.sh check`, or wait one poll interval; a poll that delivers prints `slack: delivered ... captain reply(s) ...`.
2. `bin/fm-inbox.sh list` shows both messages as captain notes.
3. Answer each with `bin/fm-inbox.sh reply <note-id> pong`; the answers appear in the DM and in a thread under the tagged message.

Setup is done when both answers arrive in Slack.

## Daily flows

| You want to | Do this in Slack | Where firstmate answers |
| --- | --- | --- |
| Ask or tell firstmate anything privately | DM the bot | In the DM |
| Talk to firstmate in the report or decisions channel | Start a message with `@<bot name>` | In a thread under your message |
| Answer a report, merge ask, or decision | Reply in the thread of the bot's post; no tag needed | In that thread |
| Follow up in a thread that is not under a bot post | Tag the bot again in your reply | In that thread |

What counts:

- Only your own account counts, matched by your exact member id; anyone else's message, and every bot message, is ignored.
- In the channels, a top-level message reaches firstmate only when it tags this home's bot; untagged channel chat is never read as input.
- The tag itself is removed, so `@Marco's Firstmate merge PR 7` arrives as `merge PR 7`.
- Each message is delivered once, even when it is reachable as both a thread reply and a tag.
- Messages arrive within one poll interval (`poll-seconds`) while firstmate's supervision runs.

What the bot posts where:

| Post | Channel |
| --- | --- |
| Finished PRs, merge asks, and merge results | Report channel, top-level |
| Decisions with a recommendation | Decisions channel, top-level |
| Answers to your DM | The DM |
| Answers to a thread reply or a tag | That thread |

## Two people, two bots

Each person creates their own app, stores their own token in their own Keychain, and sets `captain-user` to their own member id.
Both bots may share a channel safely: each home delivers only its own person's messages, reacts only to a tag of its own bot, and ignores every bot message, so the bots never answer each other.

## Changing or removing the bot

- To rotate the token, reinstall the app or regenerate the token, then repeat step 4; `-U` replaces the stored item.
- After changing scopes in the app, reinstall it so the token carries them.
- To go back to posting as your own account through `slack-axi`, delete the `bot-keychain-service` line and use `#name` or id channels as before.
- To remove the token: `security delete-generic-password -s firstmate-slack-bot`.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `no Keychain item with service ...` | The token is not stored under that service name, or the Keychain is locked; repeat step 4 or unlock the login Keychain. |
| `does not hold a Slack bot token (xoxb-...)`, or step 4's check prints nothing | The item is empty, usually because it was stored through an agent shell such as the `!` prefix; delete it with `security delete-generic-password -s <service>` and repeat step 4 in a normal terminal. |
| `invalid_auth` or `token_revoked` | The stored token is wrong or revoked; reinstall the app and repeat step 4. |
| `missing_scope` | The app was installed before its scopes changed; reinstall it. |
| `not_in_channel` or `channel_not_found` | Invite the bot to the channel (step 7); for a private channel, recreate the link with `--private-channels` and reinstall. |
| `needs every channel as a channel id` | Replace each `#name` in `config/slack-bridge` with the channel id (step 5). |
| A top-level channel message got no answer | It did not tag the bot; untagged channel chat is ignored by design, so start the message with `@<bot name>`. |
| A tagged message got no answer | It was sent by another account, tags a different bot, or was posted before `arm`; send it again from your own account. |
