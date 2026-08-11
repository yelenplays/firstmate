#!/usr/bin/env bash
# tests/megamind-fixture.sh - the mandatory worker Megamind binding, as a fixture.
#
# Every ordinary ship/scout spawn clears the owning home's Megamind binding
# before any endpoint exists (bin/fm-worker-preflight.sh), so a fixture that
# spawns a worker needs both halves: the home's binding and the task's own
# separately authored routing request. These helpers install one deterministic
# no-match binding so unrelated suites stay focused on their own behavior;
# tests/fm-worker-preflight.test.sh owns the outcome matrix itself.
#
# tests/lib.sh sources this, so suites built on that library get it for free.
# The real-runtime E2E suites that roll their own reporters source this file
# directly rather than re-rolling the stub.
#
# The stub lives inside the config directory it binds and is named by an
# absolute path in config/megamind-executable, so no fixture has to shim PATH.

if [ -n "${FM_TEST_MEGAMIND_FIXTURE_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_MEGAMIND_FIXTURE_SOURCED=1

# fm_test_megamind_config <config-dir> [estate-dir]: bind one home's RESOLVED
# config directory. Use this directly when a fixture drives fm-spawn.sh through
# FM_CONFIG_OVERRIDE rather than a <home>/config layout.
fm_test_megamind_config() {
  local config=$1 estate=${2:-$1/estate} stub="$1/megamind-axi-stub"
  mkdir -p "$config" "$estate"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf 'megamind-axi 0.3.0\n'
  exit 0
fi
printf '%s\n' '{"schema_version":"megamind/preflight-result/v2","request_hash":"fm-test-request","model_class":"cloud","status":"no-match","confidence":null,"thresholds":{"reliance_floor":0.75,"offer_floor":0.25,"ambiguity_band":0.05},"preflight_id":"fm-test-preflight","catalog_hash":"fm-test-catalog","matches":[],"offers":[],"filtered":[],"redacted_count":0}'
SH
  chmod +x "$stub"
  printf '%s\n' "$stub" > "$config/megamind-executable"
  printf '%s\n' "$estate" > "$config/megamind-estate"
}

# fm_test_megamind_binding <home> [estate-dir]: the same binding for a home laid
# out as <home>/config.
fm_test_megamind_binding() {
  fm_test_megamind_config "$1/config" "${2:-$1/megamind-estate}"
}

# fm_test_megamind_request <data-dir> <task-id>: author the task's routing
# request beside its brief, the way bin/fm-brief.sh scaffolds it and firstmate
# fills it in.
fm_test_megamind_request() {
  local data=$1 id=$2
  mkdir -p "$data/$id"
  printf 'fixture routing summary for %s\n' "$id" > "$data/$id/megamind-request.md"
}

# fm_test_megamind_task <home> <task-id> [data-dir]: both halves for one worker
# spawn out of <home>. data-dir defaults to <home>/data.
fm_test_megamind_task() {
  local home=$1 id=$2 data=${3:-$1/data}
  fm_test_megamind_binding "$home"
  fm_test_megamind_request "$data" "$id"
}
