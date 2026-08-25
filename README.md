# kiwicode

A minimal coding harness for the model llm-rig serves. Not a fork of
opencode — an MVP of the same idea, one bash file of logic, tuned for
**this machine's deployment** rather than configurable:

- **Model**: `qwen3.8-27b` (Qwen3.8-27B UD-Q4_K_M, tensor-split over both
  A4000s) as served by llama-swap from `40-serve.sh`
- **Endpoint**: `http://127.0.0.1:8081/v1/messages` (`LLAMA_PORT` overrides)
- **Context**: 8192 — the serving config's `-c 8192`. The harness budgets its
  history against that ceiling instead of assuming more and getting silently
  truncated from the left.

## Usage

```bash
llama-swap must be running (40-serve.sh), then:

KIWI_PROJECT_DIR=~/some-project ~/llm-rig/kiwicode/bin/kiwicode \
  "Add input validation to src/config.py, then run the tests"
```

The agent loops: it replies with exactly one tool call per turn, the harness
executes it and feeds the result back, until the model answers without a tool
call. Thinking blocks are shown dimmed on stderr; only text is replayed to the
server.

## Tools (five)

| tool | args | notes |
|------|------|-------|
| `bash`  | `cmd` | runs in `KIWI_PROJECT_DIR`, 120s timeout |
| `read`  | `path` | whole file |
| `write` | `path`, `content` | create/replace via atomic tmp+mv |
| `edit`  | `path`, `old`, `new` | first exact occurrence |
| `ls`    | `path` | directory listing |

Tool results are capped at `KIWI_RESULT_CAP` (8000 chars) so one giant read
cannot eat the context window. History keeps the task definition plus the
newest turns that fit; the middle of a long session is dropped rather than
letting the server truncate unpredictably.

## Tuning notes for Qwen3.8-27B (what the MVP learned)

- **One tool call per reply, entire reply.** Shown once with a worked example
  in the system prompt. The model follows this reliably; several-calls-per-
  turn or prose-plus-call formats were not attempted.
- **Thinking blocks are never graded or replayed.** They are display-only.
  A response cut off at the token cap mid-thinking produced no tool call and
  no answer — the harness prints a visible truncation warning instead of
  treating the empty text as the final answer.
- **The model can break JSON escaping in `edit`.** Observed once in ten runs:
  repeated malformed `edit` payloads after a failed one, burning turns. It
  recovered by switching to `write` for the whole file, which worked. A
  future version could nudge harder toward `write` when an `edit` fails twice.
- **Prompt is ~200 tokens**, not thousands: at `-c 8192` every system token
  competes with code. Keep it short if you extend it.

## Environment variables (all optional)

| var | default | purpose |
|-----|---------|---------|
| `KIWI_PROJECT_DIR` | `$PWD` | where tools run |
| `KIWI_MODEL` | `qwen3.8-27b` | served model name |
| `KIWI_BASE` | `http://127.0.0.1:$LLAMA_PORT` | llama-swap endpoint |
| `KIWI_CTX` / `KIWI_MAX_TOKENS` | 8192 / 1024 | history budget |
| `KIWI_MAX_TURNS` | 24 | loop safety limit |

## Security posture

MVP: `bash` executes with your full user rights under a 120s timeout, gated by
the system prompt's rules and by you reading the transcript as it streams.
Do not run it unattended against anything you care about.
