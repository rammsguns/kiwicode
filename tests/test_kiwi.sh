#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

assert_eq() {
  local expected="$1" actual="$2" description="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' \
      "$description" "$expected" "$actual" >&2
    exit 1
  fi
}

export KIWI_PROJECT_DIR="$fixture_dir"
source "$repo_dir/lib/kiwi.sh"

printf 'before\n' > "$fixture_dir/target.txt"

assert_eq 'before' \
  "$(kiwi_run_tool '{"name":"read","args":{"path":"target.txt"}}')" \
  'read resolves a relative path inside KIWI_PROJECT_DIR'

assert_eq 'wrote new.txt' \
  "$(kiwi_run_tool '{"name":"write","args":{"path":"new.txt","content":"created"}}')" \
  'write reports success'
assert_eq 'created' "$(<"$fixture_dir/new.txt")" 'write creates the file in KIWI_PROJECT_DIR'

assert_eq 'edited target.txt' \
  "$(kiwi_run_tool '{"name":"edit","args":{"path":"target.txt","old":"before","new":"after"}}')" \
  'edit reports success'
assert_eq 'after' "$(<"$fixture_dir/target.txt")" 'edit changes the file in KIWI_PROJECT_DIR'

if ! kiwi_run_tool '{"name":"ls","args":{"path":"."}}' | grep -qx '.*target.txt'; then
  printf 'FAIL: ls does not list the project directory\n' >&2
  exit 1
fi

assert_eq 'ERROR: tool call is not a JSON object' \
  "$(kiwi_run_tool 'not-json')" 'malformed tool calls are rejected'

long_task="$(printf 'x%.0s' {1..1000})"
messages="$(jq -cn --arg task "$long_task" '[{"role":"user","content":$task}]')"
trimmed="$(KIWI_CTX=500 KIWI_MAX_TOKENS=50 kiwi_trim_history "$messages")"
if (( $(jq -r '.[0].content | length' <<<"$trimmed") > 200 )); then
  printf 'FAIL: oversized initial task was not trimmed to the context budget\n' >&2
  exit 1
fi

printf 'ok: kiwicode regression tests passed\n'
