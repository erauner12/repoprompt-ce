#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CORE_ROOT="Sources/RepoPromptCore"
MACOS_ROOT="Sources/RepoPromptCoreMacOS"
SYNTAX_BRIDGE_ROOT="Sources/RepoPromptSyntaxCBridge"
failures=0
temporary_file=""

cleanup() {
  if [[ -n "$temporary_file" ]]; then
    rm -f "$temporary_file"
  fi
}
trap cleanup EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  failures=$((failures + 1))
}

report_matches() {
  local label="$1"
  local pattern="$2"
  shift 2
  local output status

  set +e
  output="$(grep -n -E -- "$pattern" "$@" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    fail "$label"
    printf '%s\n' "$output" >&2
  elif [[ "$status" -ne 1 ]]; then
    printf 'ERROR: core boundary grep failed while checking: %s\n' "$label" >&2
    printf '%s\n' "$output" >&2
    exit "$status"
  fi
}

for required_root in "$CORE_ROOT" "$MACOS_ROOT" "$SYNTAX_BRIDGE_ROOT"; do
  if [[ ! -d "$required_root" ]]; then
    fail "required Item 5 source root missing: $required_root"
  fi
done

if [[ -d "$CORE_ROOT" ]]; then
  core_swift_files=()
  temporary_file="$(mktemp "${TMPDIR:-/tmp}/repoprompt-core-boundary.XXXXXX")"
  find "$CORE_ROOT" -type f -name '*.swift' -print0 > "$temporary_file"
  while IFS= read -r -d '' file; do
    core_swift_files+=("$file")
  done < "$temporary_file"

  if [[ "${#core_swift_files[@]}" -eq 0 ]]; then
    fail "$CORE_ROOT contains no Swift files"
  else
    report_matches \
      "forbidden Apple UI/platform import found under $CORE_ROOT" \
      '^[[:space:]]*(@[[:alnum:]_]+[[:space:]]+)*import([[:space:]]+(class|struct|enum|protocol|func|var|let|typealias))?[[:space:]]+(AppKit|SwiftUI|Cocoa|Sparkle|KeyboardShortcuts|CoreServices|Security|Darwin|OSLog|os)([.]|[[:space:]]|$)' \
      "${core_swift_files[@]}"
    report_matches \
      "app-owned runtime or embedded-policy reference found under $CORE_ROOT" \
      '(^|[^[:alnum:]_])(WindowState|WindowStatesManager|NSApplication|NSWorkspace|SecureKeyValueStorageFactory|MacOSFSEventsWatcherFactory)([^[:alnum:]_]|$)|Bundle[.]main|UserDefaults[.]standard|applicationSupportDirectory' \
      "${core_swift_files[@]}"
  fi
fi

report_matches \
  "app packaging mentions a standalone headless command; keep Items 6-7 independently packaged" \
  'repoprompt-headless|rpce-headless' \
  Scripts/package_app.sh

if [[ "$failures" -ne 0 ]]; then
  printf 'Core boundary guardrails failed (%s issue%s).\n' "$failures" "$([[ "$failures" == 1 ]] && printf '' || printf 's')" >&2
  exit 1
fi

printf 'OK: enforced core boundary guardrails passed.\n'
