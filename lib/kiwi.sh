# shellcheck shell=bash
# kiwicode lib -- everything the bin script does, as functions.
# Sourced, never executed: keeps the entry point a one-liner and lets the
# test harness drive each piece in isolation.

set -uo pipefail

KIWI_MODEL="${KIWI_MODEL:-qwen3.8-27b}"
KIWI_BASE="${KIWI_BASE:-http://127.0.0.1:${LLAMA_PORT:-8081}}"
# The serving config runs -c 8192. Budget history against that ceiling:
# input tokens + max_tokens must fit, or the server truncates from the left
# and the model silently loses the task definition.
KIWI_CTX="${KIWI_CTX:-8192}"
KIWI_MAX_TOKENS="${KIWI_MAX_TOKENS:-1024}"
KIWI_TEMPERATURE="${KIWI_TEMPERATURE:-0}"
KIWI_MAX_TURNS="${KIWI_MAX_TURNS:-24}"
KIWI_TIMEOUT="${KIWI_TIMEOUT:-600}"
# Tool results are bounded so one giant cat cannot eat the context alone.
KIWI_RESULT_CAP="${KIWI_RESULT_CAP:-8000}"

c_info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
c_ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*" >&2; }
c_warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
c_err()  { printf '\033[1;31m  XX\033[0m %s\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }

kiwi_dim() { printf '\033[2m%s\033[0m' "$*"; }

# --- the system prompt -------------------------------------------------------
# Tuned for Qwen3.8-27B specifically, not for agents generally:
#
#   - SHORT. At -c 8192 every system-prompt token is paid for out of the same
#     window that holds the task and the file contents. opencode's prompt is
#     thousands of tokens; this one is ~200.
#   - ONE tool-call format, stated once, with a worked example. Reasoners
#     follow a single shown pattern far more reliably than a list of rules.
#   - "one tool call per message" is the load-bearing constraint: it keeps each
#     turn small (context), makes tool results unambiguous (no ordering
#     questions), and gives the loop a clean stop condition per step.
kiwi_system_prompt() {
  cat <<'EOF'
You are kiwicode, a coding agent working directly on this machine.

TOOLS. Call exactly one tool per reply, as the ENTIRE reply -- one block,
nothing before or after:

<tool>{"name":"bash","args":{"cmd":"ls -la"}}</tool>

Tools:
- bash    {"cmd":"..."}            run in the project dir. For tests, git, builds.
- read    {"path":"..."}           whole file contents.
- write   {"path":"...","content":"..."}   create or replace a whole file.
- edit    {"path":"...","old":"...","new":"..."}  replace first exact occurrence of old.
- ls      {"path":"."}             list a directory.

RULES.
1. One tool call per reply. Never several. Never text plus a call.
2. After each tool result, continue: think, then either the next call or the final answer.
3. Prefer edit over write for existing files; old must match EXACTLY including whitespace.
4. Keep bash commands short and safe. Never rm -rf outside the project dir.
5. When the task is done, reply DONE on its own line followed by a one-sentence summary.
EOF
}

# --- request/response ---------------------------------------------------------

kiwi_payload() {
  # $1 = messages JSON array -> request body on stdout.
  jq -n --arg model "$KIWI_MODEL" --argjson max "$KIWI_MAX_TOKENS" \
        --argjson temp "$KIWI_TEMPERATURE" --argjson msgs "$1" \
        --rawfile system <(kiwi_system_prompt) \
        '{model:$model, max_tokens:$max, temperature:$temp,
          system:$system, messages:$msgs}'
}

kiwi_call() {
  # $1 = messages JSON array. Prints the raw Messages-API response body.
  # curl failure returns non-zero; callers distinguish transport errors.
  kiwi_payload "$1" \
    | curl -sf --max-time "$KIWI_TIMEOUT" -X POST "$KIWI_BASE/v1/messages" \
        -H 'content-type: application/json' \
        -H 'x-api-key: kiwicode' -H 'anthropic-version: 2023-06-01' \
        -d @-
}

# Text of a response: concatenated TEXT blocks only. Thinking blocks are for
# the human watching; they are never replayed to the server and never graded
# as the answer -- a model that reasons its way to an edit without emitting
# one has not edited anything.
kiwi_response_text() {
  jq -r '[.content[]? | select(.type == "text") | .text] | join("")'
}
kiwi_response_thinking() {
  jq -r '[.content[]? | select(.type == "thinking") | .thinking] | join("")'
}
kiwi_stop_reason() {
  jq -r '.stop_reason // .finish_reason // "unavailable"'
}

# --- the tool protocol --------------------------------------------------------
# XML-ish tags around a JSON body rather than native tool_use: llama.cpp's
# jinja chat template renders them reliably for this model class, and parsing
# stays a grep instead of a second API surface.

kiwi_extract_tool() {
  # Prints the JSON object inside the first <tool>...</tool> pair, or nothing.
  local text="$1" inner
  inner="$(grep -o '<tool>.*</tool>' <<<"$text" | head -1)"
  [[ -n "$inner" ]] || return 0
  printf '%s' "${inner#<tool>}" | sed 's|</tool>$||'
}

kiwi_run_tool() (
  # $1 = tool JSON. Prints the result as plain text. Nothing executes until
  # the shape validates. Security posture is MVP: bash runs with full user
  # rights under `timeout`, gated by the system prompt's rules and by you
  # reading the transcript. Do not run it unattended on a machine you care
  # about.
  local name cmd path content old new tmp project_dir
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$1" \
    || { printf 'ERROR: tool call is not a JSON object'; return 0; }
  # Run every tool from the selected project. This matters for read/write/edit
  # and ls as much as it does for bash: callers commonly launch the harness
  # from somewhere other than the project it is operating on.
  project_dir="${KIWI_PROJECT_DIR:-$PWD}"
  [[ -d "$project_dir" ]] \
    || { printf 'ERROR: project directory does not exist: %s' "$project_dir"; return 0; }
  cd "$project_dir" \
    || { printf 'ERROR: cannot enter project directory: %s' "$project_dir"; return 0; }
  name="$(jq -r '.name // ""' <<<"$1")"
  case "$name" in
    bash)
      cmd="$(jq -r '.args.cmd // ""' <<<"$1")"
      [[ -n "$cmd" ]] || { printf 'ERROR: bash needs args.cmd'; return 0; }
      timeout 120 bash -c "$cmd" 2>&1
      ;;
    read)
      path="$(jq -r '.args.path // ""' <<<"$1")"
      [[ -n "$path" ]] || { printf 'ERROR: read needs args.path'; return 0; }
      [[ -f "$path" ]] || { printf 'ERROR: no such file: %s' "$path"; return 0; }
      cat "$path"
      ;;
    write)
      path="$(jq -r '.args.path // ""' <<<"$1")"
      content="$(jq -r '.args.content // ""' <<<"$1")"
      [[ -n "$path" ]] || { printf 'ERROR: write needs args.path'; return 0; }
      tmp="$(mktemp "$(dirname "$path")/.kiwi-write.XXXXXX")" \
        || { printf 'ERROR: cannot write %s' "$path"; return 0; }
      if printf '%s' "$content" > "$tmp" && mv "$tmp" "$path"; then
        printf 'wrote %s' "$path"
      else
        rm -f "$tmp"
        printf 'ERROR: writing %s failed' "$path"
      fi
      ;;
    edit)
      path="$(jq -r '.args.path // ""' <<<"$1")"
      old="$(jq -r '.args.old // ""' <<<"$1")"
      new="$(jq -r '.args.new // ""' <<<"$1")"
      if [[ -z "$path" || -z "$old" ]]; then
        printf 'ERROR: edit needs args.path and args.old'
      elif [[ ! -f "$path" ]]; then
        printf 'ERROR: no such file: %s' "$path"
      elif ! grep -qF -- "$old" "$path"; then
        printf 'ERROR: old text not found in %s (must match exactly)' "$path"
      else
        tmp="$(mktemp "$(dirname "$path")/.kiwi-edit.XXXXXX")" \
          || { printf 'ERROR: cannot write %s' "$path"; return 0; }
        if python3 - "$path" "$tmp" "$old" "$new" <<'PYEOF'
import sys
path, tmp, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(path).read()
open(tmp, "w").write(text.replace(old, new, 1))
PYEOF
        then
          if mv "$tmp" "$path"; then
            printf 'edited %s' "$path"
          else
            rm -f "$tmp"
            printf 'ERROR: writing %s failed' "$path"
          fi
        else
          rm -f "$tmp"
          printf 'ERROR: editing %s failed' "$path"
        fi
      fi
      ;;
    ls)
      path="$(jq -r '.args.path // "."' <<<"$1")"
      ls -la "$path" 2>&1
      ;;
    *)
      printf 'ERROR: unknown tool: %s' "$name"
      ;;
  esac
)

# --- history management --------------------------------------------------------

kiwi_messages_add() {
  # stdin = messages array, $1/$2 = role/content. Appends, prints the new array.
  # Reads the array from STDIN rather than $1: under `set -u` a caller's
  # command substitution evaluates this function in a context where an unset
  # positional has already burned us once (bash treats referencing $3 with
  # only two args as fatal, even guarded). Stdin is unambiguous.
  jq -c --arg role "$1" --arg content "$2" '. + [{"role":$role,"content":$content}]'
}

kiwi_trim_history() {
  # $1 = messages JSON. Keeps the FIRST message (the task definition) and the
  # NEWEST turns while the estimated token count fits the budget. Losing the
  # middle of a long session beats losing the task or having the server
  # truncate from the left unpredictably.
  local budget=$(( KIWI_CTX - KIWI_MAX_TOKENS - 400 ))   # system prompt + slack
  python3 - "$1" "$budget" <<'PYEOF'
import json, sys
msgs = json.loads(sys.argv[1]); budget = int(sys.argv[2])
def cost(m): return len(m["content"]) // 4
if cost(msgs[0]) > budget:
    # The initial task is important, but it cannot be allowed to make the
    # request exceed the configured context budget by itself.
    marker = "\n...[task truncated to fit context budget]"
    allowed = max(0, budget * 4)
    first = dict(msgs[0])
    if allowed <= len(marker):
        first["content"] = marker[:allowed]
    else:
        first["content"] = first["content"][:allowed - len(marker)] + marker
    print(json.dumps([first])); sys.exit(0)
if sum(cost(m) for m in msgs) <= budget:
    print(json.dumps(msgs)); sys.exit(0)
first, rest = msgs[0], msgs[1:]
keep, used = [], cost(first)
for m in reversed(rest):
    t = cost(m)
    if used + t > budget - 300:
        break
    keep.append(m); used += t
keep.reverse()
print(json.dumps([first] + keep))
PYEOF
}

# --- main loop ------------------------------------------------------------------

kiwi_main() {
  [[ -n "${1:-}" ]] || { printf 'usage: kiwicode "<task>"\n' >&2; exit 2; }
  command -v jq >/dev/null || die "jq not found"

  c_info "kiwicode  model=$KIWI_MODEL  ctx=$KIWI_CTX  dir=${KIWI_PROJECT_DIR:-$PWD}"

  local task="$*"
  local messages
  messages="$(jq -cn --arg t "$task" '[{"role":"user","content":$t}]')"
  local turn=1 resp text thinking tool_json stop clean_content result

  while (( turn <= KIWI_MAX_TURNS )); do
    messages="$(kiwi_trim_history "$messages")"
    if ! resp="$(kiwi_call "$messages")"; then
      die "request to $KIWI_BASE failed (is llama-swap up?)"
    fi

    stop="$(kiwi_stop_reason <<<"$resp")"
    thinking="$(kiwi_response_thinking <<<"$resp")"
    text="$(kiwi_response_text <<<"$resp")"

    [[ -n "$thinking" ]] \
      && printf '%s\n' "$(kiwi_dim "... $(head -c 200 <<<"$thinking" | tr '\n' ' ')")" >&2

    tool_json="$(kiwi_extract_tool "$text")"
    if [[ -z "$tool_json" ]]; then
      # No tool call: the final answer (or a format break, which reads as one).
      printf '%s\n' "$text"
      [[ "$stop" == "max_tokens" ]] \
        && c_warn "response hit the ${KIWI_MAX_TOKENS}-token cap; output may be cut off"
      return 0
    fi

    # Replay this assistant turn WITHOUT thinking blocks: they are dead tokens
    # on the way back up and some servers reject them outright.
    clean_content="$(jq -Rn --arg t "$text" '$t')"
    messages="$(printf '%s' "$messages" | kiwi_messages_add assistant "$clean_content")"
    c_info "turn $turn: $(jq -r '.name' <<<"$tool_json") $(jq -rc '.args.cmd // .args.path // ""' <<<"$tool_json" | head -c 100)"

    result="$(kiwi_run_tool "$tool_json")"
    (( ${#result} > KIWI_RESULT_CAP )) && result="${result:0:KIWI_RESULT_CAP}...(truncated)"
    messages="$(printf '%s' "$messages" | kiwi_messages_add user "[tool result]
$result")"

    (( turn++ ))
  done
  c_err "gave up after $KIWI_MAX_TURNS turns without a final answer"
  return 1
}
