# shellcheck shell=bash
# Per-business facts for ship and scout briefs.
# docs/configuration.md "Business facts in briefs" owns setup, the registry
# token and facts-file schema, missing-data behavior, and inheritance.
# This helper owns parsing and the rendered worker instruction.
#
# fm_facts_registry_name <registry> <project>
#   Prints the project's facts name, or nothing. Returns 2 and prints the
#   reason to stderr when the row's facts token is malformed.
# fm_facts_section <config-dir> <project> <registry>
#   Prints the brief's "# Business facts" section, or nothing. Returns 2 on a
#   malformed token.

fm_facts_registry_name() {
  local reg=$1 name=$2 out
  [ -f "$reg" ] || return 0
  out=$(awk -v n="$name" '
    $1 == "-" && $2 == n {
      rest = $0
      sub(/^[ \t]*-[ \t]+/, "", rest)
      rest = substr(rest, length(n) + 1)
      count = 0
      for (k = 0; k < 6; k++) {
        sub(/^[ \t]+/, "", rest)
        if (substr(rest, 1, 1) != "[") break
        close_at = index(rest, "]")
        if (close_at == 0) break
        body = substr(rest, 2, close_at - 2)
        rest = substr(rest, close_at + 1)
        if (body ~ /^facts:/) {
          sub(/^facts:[ \t]*/, "", body)
          gsub(/[ \t]+$/, "", body)
          value = body
          count++
        }
      }
      if (count > 1) print "MALFORMED"
      else if (count == 1) print "NAME " value
      exit
    }
  ' "$reg")
  case "$out" in
    '') return 0 ;;
    MALFORMED)
      echo "error: $reg row for $name carries more than one [facts: ...] token" >&2
      return 2
      ;;
    "NAME "*) out=${out#NAME } ;;
  esac
  case "$out" in
    '' | [!a-z0-9]* | *[!a-z0-9._-]*)
      echo "error: $reg row for $name has a malformed [facts: $out] token; want [facts: <business>] with <business> matching ^[a-z0-9][a-z0-9._-]*\$" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$out"
}

fm_facts_section() {
  local config=$1 project=$2 reg=$3 business file body
  business=$(fm_facts_registry_name "$reg" "$project") || return 2
  [ -n "$business" ] || return 0
  file=$config/business-facts.md
  [ -f "$file" ] && [ -r "$file" ] || return 0
  body=$(awk -v b="$business" '
    /^##[ \t]+/ {
      h = $0
      sub(/^##[ \t]+/, "", h)
      gsub(/[ \t]+$/, "", h)
      on = (h == b)
      next
    }
    on { print }
  ' "$file")
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || return 0
  printf '# Business facts\n'
  printf 'These are the recorded facts of the business behind this project (%s).\n' "$business"
  printf 'Read them before any form, signup, directory entry, or legal or tax step, and never claim or request anything they contradict (for example a registration the business does not have).\n\n'
  printf '%s\n' "$body"
}
