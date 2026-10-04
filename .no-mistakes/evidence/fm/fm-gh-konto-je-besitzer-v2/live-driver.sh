#!/usr/bin/env bash
set -eu
ROOT=$PWD
W="$ROOT/.test-phase-tmp/live"
mkdir -p "$W/user" "$W/gh" "$W/home/config" "$W/home/data" "$W/home/state" "$W/home/projects"
export HOME="$W/user" GH_CONFIG_DIR="$W/gh" XDG_CONFIG_HOME="$W/user/.config"
export FM_HOME="$W/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$W/home/state" FM_DATA_OVERRIDE="$W/home/data" FM_CONFIG_OVERRIDE="$W/home/config" FM_PROJECTS_OVERRIDE="$W/home/projects"
export TMPDIR="$ROOT/.test-phase-tmp" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
printf '=== Real CLI: reject missing mapped credentials even with ambient token ===\n'
printf 'SlashpipeCoding Slashpipe\nMarcoGC3 MarcoGC3\n' > "$FM_HOME/config/gh-account-by-owner"
export GH_TOKEN=disposable-not-a-credential
for owner in SlashpipeCoding MarcoGC3; do
  rc=0
  "$ROOT/bin/fm-pr-state.sh" "https://github.com/$owner/disposable/pull/1" > "$W/out" 2>&1 || rc=$?
  cat "$W/out"
  printf 'exit=%s\n' "$rc"
  [ "$rc" -ne 0 ] && grep -q 'has no token' "$W/out"
done
printf '=== Real CLI: reject malformed and conflicting account mapping ===\n'
for mapping in 'SlashpipeCoding Slashpipe extra' $'SlashpipeCoding Slashpipe\nslashpipecoding MarcoGC3'; do
  printf '%s\n' "$mapping" > "$FM_HOME/config/gh-account-by-owner"
  rc=0
  "$ROOT/bin/fm-pr-state.sh" https://github.com/SlashpipeCoding/disposable/pull/1 > "$W/out" 2>&1 || rc=$?
  cat "$W/out"; printf 'exit=%s\n' "$rc"; [ "$rc" -ne 0 ]
done
printf '=== Real observer: repeated missing-account observations remain visibly unavailable ===\n'
printf 'SlashpipeCoding Slashpipe\nMarcoGC3 MarcoGC3\n' > "$FM_HOME/config/gh-account-by-owner"
printf '# Backlog\n\n## Queued\n- [ ] company - Observe https://github.com/SlashpipeCoding/disposable/pull/1 (repo: sample) (kind: ship)\n' > "$FM_HOME/data/backlog.md"
for i in 1 2; do
  printf 'poll=%s\n' "$i"
  "$ROOT/bin/fm-contributions.sh" poll
  jq '{schema,task,records:[.records[]|{url,error,observation}]}' "$FM_HOME/data/company/contributions.json"
  jq -e '.records[0].error | contains("mapped to account Slashpipe")' "$FM_HOME/data/company/contributions.json" >/dev/null
done
printf 'Isolated GitHub configuration files: %s\n' "$(find "$W/gh" -type f | wc -l | tr -d ' ')"
unset GH_TOKEN
printf '=== Real local update: authenticated merge watches survive template upgrade ===\n'
mkdir -p "$W/seed/bin"
cp -R "$ROOT/bin/." "$W/seed/bin/"
git show 756c9fb3aea7caa92c86698bb3182fb50ae21c48:bin/fm-pr-poll.sh > "$W/seed/bin/fm-pr-poll.sh"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git -C "$W/seed" init -q -b main
git -C "$W/seed" add bin
git -C "$W/seed" commit -qm old-poll
git -C "$W/seed" remote add origin "$W/origin.git"
git -C "$W/seed" push -q origin main
git clone -q "$W/origin.git" "$W/code"
. "$ROOT/bin/fm-pr-lib.sh"
for url in https://github.com/SlashpipeCoding/disposable/pull/1 https://gitlab.example/org/repo/-/merge_requests/2 https://review.example/c/repo/+/3; do
  fm_pr_url_parse "$url"
  id=$FM_PR_PROVIDER
  printf 'kind=ship\npr=%s\n' "$url" > "$FM_HOME/state/$id.meta"
  chmod 600 "$FM_HOME/state/$id.meta"
  fm_pr_poll_prepare "$FM_HOME/state" "$id" "$FM_PR_PROVIDER" "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$W/code/bin/fm-pr-poll.sh"
  fm_pr_poll_publish_prepared
  if fm_pr_poll_artifacts_valid "$FM_HOME/state" "$id" "$ROOT/bin/fm-pr-poll.sh"; then exit 1; fi
  printf '%s: old registration rejected against new template before update\n' "$id"
done
cp "$ROOT/bin/fm-pr-poll.sh" "$W/seed/bin/fm-pr-poll.sh"
git -C "$W/seed" add bin/fm-pr-poll.sh
git -C "$W/seed" commit -qm new-poll
git -C "$W/seed" push -q origin main
FM_ROOT_OVERRIDE="$W/code" "$W/code/bin/fm-update.sh"
for id in github gitlab gerrit; do
  fm_pr_poll_artifacts_valid "$FM_HOME/state" "$id" "$ROOT/bin/fm-pr-poll.sh"
  printf '%s: registration accepted after update\n' "$id"
done
before=$(fm_pr_file_identity "$FM_HOME/state/github.check.sh")
FM_ROOT_OVERRIDE="$W/code" "$W/code/bin/fm-update.sh"
[ "$before" = "$(fm_pr_file_identity "$FM_HOME/state/github.check.sh")" ]
printf 'Already-current update preserved the valid check identity\n'
printf '\n' >> "$FM_HOME/state/github.check.sh"
rc=0
FM_ROOT_OVERRIDE="$W/code" "$W/code/bin/fm-update.sh" || rc=$?
printf 'Tampered check: update exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
if fm_pr_poll_artifacts_valid "$FM_HOME/state" github "$ROOT/bin/fm-pr-poll.sh"; then exit 1; fi
printf 'Tampered check remains unauthenticated; registration boundary was not weakened\n'
