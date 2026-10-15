#!/usr/bin/env bash
# Live drive: two Firstmate homes clone one remote; home A's clone creates the
# Treehouse pool through the REAL treehouse binary; home B then runs the real
# bin/fm-spawn.sh whose pane `treehouse get` is executed by the REAL treehouse
# binary (only the tmux multiplexer is simulated: tmux is not installed here).
# usage: live-two-homes.sh <firstmate-root> <label> [variant]
set -u
ROOT=$1 LABEL=$2 VARIANT=${3:-default}
REAL_TH=$(command -v treehouse)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-pool.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
USERH=$LAB/user-home; mkdir -p "$USERH"
echo "== [$LABEL] lab=$LAB firstmate=$ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo archive)) treehouse=$($REAL_TH --version)"
LABHOME_TOOL=${LABHOME_TOOL:-$ROOT/bin/fm-lab-home.sh}
for h in homeA homeB; do
  mkdir -p "$LAB/$h"; "$LABHOME_TOOL" create "$LAB/$h" >/dev/null || { echo "lab home create failed"; exit 1; }
  mkdir -p "$LAB/$h/data" "$LAB/$h/projects" "$LAB/$h/state" "$LAB/$h/config"
  touch "$LAB/$h/state/.last-watcher-beat"; echo claude > "$LAB/$h/config/crew-harness"
done
echo "lab homes marked: $(cat "$LAB/homeA/.fm-lab-home") / $(cat "$LAB/homeB/.fm-lab-home")"
git init -q -b main "$LAB/seed/wiki-anbindung"
git -C "$LAB/seed/wiki-anbindung" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git clone -q --bare "$LAB/seed/wiki-anbindung" "$LAB/remote/wiki-anbindung.git"
URL="file://$LAB/remote/wiki-anbindung.git"
git clone -q "$URL" "$LAB/homeA/projects/wiki-anbindung"
git clone -q "$URL" "$LAB/homeB/projects/wiki-anbindung"
A=$LAB/homeA/projects/wiki-anbindung B=$LAB/homeB/projects/wiki-anbindung
th() { (cd "$1" && shift && HOME=$USERH TREEHOUSE_NO_UPDATE_CHECK=1 "$REAL_TH" "$@"); }
case "$VARIANT" in
  configured-root)
    mkdir -p "$USERH/.config/treehouse"
    printf '"max_trees" = +4\nroot = "$HOME/worktrees"\n' > "$USERH/.config/treehouse/config.toml"
    echo "-- user config.toml:"; cat "$USERH/.config/treehouse/config.toml" ;;
esac
echo "-- step 1: home A's clone takes and returns a slot with real treehouse (creates the shared pool)"
SA=$(th "$A" get --lease --lease-holder homeA 2>/dev/null); echo "home A got: $SA"
th "$A" return --force "$SA" >/dev/null 2>&1
echo "slot A belongs to: $(cd "$(git -C "$SA" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
echo "-- step 2: unpinned, real treehouse from home B's clone hands out:"
G=$(th "$B" get --lease --lease-holder probe 2>/dev/null); echo "  $G (common-dir $(cd "$(git -C "$G" rev-parse --path-format=absolute --git-common-dir)" && pwd -P))"
th "$B" return --force "$G" >/dev/null 2>&1
STATE_BEFORE=$(cat "$(dirname "$(dirname "$SA")")/treehouse-state.json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([{k:w.get(k) for k in ("name","path")} for w in d.get("worktrees",[])]))')
HEAD_A=$(git -C "$SA" rev-parse HEAD)
case "$VARIANT" in
  own-toml) printf 'max_trees = 4\n' > "$B/treehouse.toml"; echo "-- home B's clone carries its own treehouse.toml";;
esac
# fakebin: tmux stand-in whose pane runs the REAL treehouse get; treehouse wrapper -> real binary.
FB=$LAB/fakebin; mkdir -p "$FB"
cat > "$FB/treehouse" <<SH
#!/usr/bin/env bash
echo "treehouse \$*" >> "$LAB/treehouse-calls.log"
TREEHOUSE_NO_UPDATE_CHECK=1 exec "$REAL_TH" "\$@"
SH
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) if [ -s "$FM_LIVE_PANE_FILE" ]; then cat "$FM_LIVE_PANE_FILE"; else printf '%s\n' "$FM_LIVE_PROJECT"; fi; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    for a in "$@"; do
      if [ "$a" = "treehouse get" ]; then
        p=$(cd "$FM_LIVE_PROJECT" && TREEHOUSE_NO_UPDATE_CHECK=1 treehouse get --lease --lease-holder fm-live 2>>"$FM_LIVE_PANE_FILE.err")
        printf '%s\n' "$p" > "$FM_LIVE_PANE_FILE"
        echo "pane ran real 'treehouse get' -> $p" >> "$FM_LIVE_PANE_FILE.log"
      fi
    done
    exit 0 ;;
esac
exit 0
SH
chmod +x "$FB/tmux" "$FB/treehouse"
mkdir -p "$LAB/homeB/data/live-b"; printf '# Task\n## Captain'"'"'s intent\nwiki-anbindung work from home B.\n\n## Firstmate spec\nSpawn.\n' > "$LAB/homeB/data/live-b/brief.md"
echo "-- step 3: home B runs bin/fm-spawn.sh for projects/wiki-anbindung"
OUT=$(cd "$LAB/homeB" && env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB/homeB" HOME="$USERH" CLAUDE_CONFIG_DIR="$LAB/homeB/claude-config" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_LIVE_PROJECT="$B" FM_LIVE_PANE_FILE="$LAB/pane" \
  PATH="$FB:$PATH" "$ROOT/bin/fm-spawn.sh" live-b projects/wiki-anbindung --mode no-mistakes --yolo off 2>&1); RC=$?
echo "$OUT" | sed 's/^/  | /' | grep -v '^  | *$' | tail -25
echo "fm-spawn exit=$RC"
[ -f "$LAB/pane.log" ] && cat "$LAB/pane.log"
echo "-- results"
if [ -f "$LAB/homeB/state/live-b.meta" ]; then grep '^worktree=' "$LAB/homeB/state/live-b.meta"; W=$(sed -n 's/^worktree=//p' "$LAB/homeB/state/live-b.meta");
  echo "worktree belongs to: $(cd "$(git -C "$W" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"; else echo "no meta for live-b"; fi
echo "home B clone common-dir: $(cd "$(git -C "$B" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
[ -f "$B/treehouse.toml" ] && { echo "home B treehouse.toml:"; sed 's/^/    /' "$B/treehouse.toml"; } || echo "home B has no treehouse.toml"
echo "home B git status: [$(git -C "$B" status --porcelain | tr '\n' ' ')]"
[ -e "$A/treehouse.toml" ] && echo "home A pinned: YES (bad)" || echo "home A pinned: no"
[ "$(git -C "$SA" rev-parse HEAD)" = "$HEAD_A" ] && echo "slot A HEAD unchanged" || echo "slot A HEAD MOVED"
[ -e "$(dirname "$SA")/.fm-slot-owner" ] && echo "slot A claimed by B: YES (bad)" || echo "slot A claimed by B: no"
STATE_AFTER=$(cat "$(dirname "$(dirname "$SA")")/treehouse-state.json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([{k:w.get(k) for k in ("name","path")} for w in d.get("worktrees",[])]))')
[ "$STATE_BEFORE" = "$STATE_AFTER" ] && echo "shared pool slots unchanged: $STATE_AFTER" || echo "shared pool slots CHANGED: $STATE_BEFORE -> $STATE_AFTER"
if [ "$RC" -eq 0 ]; then
  echo "-- step 4: home A spawns again from its own clone (pool must still be A's)"
  mkdir -p "$LAB/homeA/data/live-a"; cp "$LAB/homeB/data/live-b/brief.md" "$LAB/homeA/data/live-a/brief.md"; rm -f "$LAB/pane"
  OUTA=$(cd "$LAB/homeA" && env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB/homeA" HOME="$USERH" CLAUDE_CONFIG_DIR="$LAB/homeA/claude-config" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_LIVE_PROJECT="$A" FM_LIVE_PANE_FILE="$LAB/pane" \
    PATH="$FB:$PATH" "$ROOT/bin/fm-spawn.sh" live-a projects/wiki-anbindung --mode no-mistakes --yolo off 2>&1); RCA=$?
  echo "home A fm-spawn exit=$RCA"; grep '^worktree=' "$LAB/homeA/state/live-a.meta" 2>/dev/null; echo "$OUTA" | grep -E 'error|pinned' | sed 's/^/  | /'
  [ -e "$A/treehouse.toml" ] && echo "home A pinned: YES (bad)" || echo "home A pinned: no"
fi
chmod -R u+w "$LAB"; rm -rf "$LAB"; echo "== [$LABEL] lab removed"
