#!/usr/bin/env bash
# Regression test for declare_type parser-diagnostic capture.
#
# declare_type used to surface only a numeric code on failure because the
# idalib bindings discarded the parser's human-readable errors (parse_decl ran
# with PT_SIL, parse_decls passed a null printer_t). The forked idalib captures
# those diagnostics via a printer_t callback. This test verifies that:
#   1. An invalid C declaration returns code != 0 plus a non-empty `errors`
#      string carrying IDA's actual parser messages.
#   2. A valid struct declaration succeeds (code == 0) with no `errors`.
#   3. The multi-declaration path returns { count, errors } with the error
#      count and aggregated diagnostics.
#
# Requires a working IDA license; if IDA reports an invalid license the test
# skips (exit 0) instead of failing, so it is safe to run in unlicensed CI.
set -euo pipefail

BIN="${MCP_STDIO_BIN:-../target/debug/ida-mcp}"
FIXTURE_SRC="${FIXTURE_SRC:-fixtures/mini.c}"
CC_BIN="${CC:-cc}"

work_dir="$(mktemp -d)"
fixture="$work_dir/mini"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    exec 3>&- 2>/dev/null || true
    local waited=0
    while kill -0 "$server_pid" 2>/dev/null && (( waited < 5 )); do
      sleep 1; waited=$((waited + 1))
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      kill -TERM "$server_pid" 2>/dev/null || true
      waited=0
      while kill -0 "$server_pid" 2>/dev/null && (( waited < 5 )); do
        sleep 1; waited=$((waited + 1))
      done
    fi
    kill -0 "$server_pid" 2>/dev/null && kill -KILL "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
  [[ -n "${fifo_in:-}" ]] && rm -f "$fifo_in"
}
trap cleanup EXIT INT TERM

[[ -x "$BIN" ]] || { echo "missing $BIN" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
command -v "$CC_BIN" >/dev/null || { echo "$CC_BIN required to build fixture" >&2; exit 1; }

"$CC_BIN" -O0 -g -fno-omit-frame-pointer -o "$fixture" "$FIXTURE_SRC"

fifo_in="$(mktemp -u).fifo"
mkfifo "$fifo_in"
log="$work_dir/server.log"

"$BIN" < "$fifo_in" > "$log" 2>&1 &
server_pid=$!
exec 3>"$fifo_in"

send() { echo "$1" >&3; }

wait_response() {
  local target_id="$1" timeout="${2:-90}" elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local line
    line=$(grep -m1 "\"id\":${target_id}[,}]" "$log" 2>/dev/null | grep '"jsonrpc"' || true)
    [[ -n "$line" ]] && { echo "$line"; return 0; }
    sleep 1; elapsed=$((elapsed + 1))
  done
  echo "timeout id=$target_id" >&2
  echo "--- server log ---" >&2; cat "$log" >&2
  return 1
}

text() { jq -r '.result.content[0].text // empty'; }

send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"declare-type","version":"0.1"},"capabilities":{}}}'
send '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
wait_response 1 10 >/dev/null
echo "   initialized"

# Open the fixture. Skip the whole test if IDA cannot validate its license.
payload=$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open_idb","arguments":{"path":"%s","auto_analyse":true}}}' "$fixture")
send "$payload"
open_resp=$(wait_response 2 120)
if echo "$open_resp" | grep -qi "license is invalid\|is_valid_license"; then
  echo "⚠️  SKIP: IDA license invalid in this environment; cannot exercise declare_type at runtime"
  exit 0
fi
open_text=$(echo "$open_resp" | text)
echo "$open_text" | jq -e '.session_id' >/dev/null || {
  echo "FAIL: open_idb did not return a session" >&2
  echo "$open_resp" >&2
  exit 1
}
echo "   ✓ opened fixture"

# Phase 1: invalid declaration → diagnostics in `errors`.
send '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"declare_type","arguments":{"decl":"struct Bad { int ; float 3x; };"}}}'
bad=$(wait_response 3 30 | text)
bad_code=$(echo "$bad" | jq -r '.code // empty')
bad_errors=$(echo "$bad" | jq -r '.errors // empty')
[[ "$bad_code" != "0" && -n "$bad_code" ]] || {
  echo "FAIL: invalid decl returned code '$bad_code' (expected non-zero)" >&2
  echo "$bad" >&2; exit 1
}
[[ -n "$bad_errors" ]] || {
  echo "FAIL: invalid decl returned empty 'errors' (expected parser diagnostics)" >&2
  echo "$bad" >&2; exit 1
}
echo "   ✓ invalid decl: code=$bad_code, errors=$(echo "$bad_errors" | head -1 | tr -d '\n')…"

# Phase 2: valid declaration → success, no `errors`.
send '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"declare_type","arguments":{"decl":"struct Good { int a; char *b; };"}}}'
good=$(wait_response 4 30 | text)
good_code=$(echo "$good" | jq -r '.code // empty')
good_name=$(echo "$good" | jq -r '.name // empty')
good_errors=$(echo "$good" | jq -r '.errors // empty')
[[ "$good_code" == "0" ]] || { echo "FAIL: valid decl returned code '$good_code'" >&2; echo "$good" >&2; exit 1; }
[[ "$good_name" == "Good" ]] || { echo "FAIL: valid decl returned name '$good_name'" >&2; echo "$good" >&2; exit 1; }
[[ -z "$good_errors" ]] || { echo "FAIL: valid decl unexpectedly carried errors: $good_errors" >&2; exit 1; }
echo "   ✓ valid decl: name=$good_name, code=$good_code, no errors"

# Phase 3: multi path → { count, errors }.
send '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"declare_type","arguments":{"decl":"struct A { int ; }; struct B { nonexistent_t z; };","multi":true}}}'
multi=$(wait_response 5 30 | text)
multi_count=$(echo "$multi" | jq -r '.count // empty')
multi_errors=$(echo "$multi" | jq -r '.errors // empty')
[[ -n "$multi_count" && "$multi_count" -gt 0 ]] || {
  echo "FAIL: multi decl returned count '$multi_count' (expected > 0)" >&2
  echo "$multi" >&2; exit 1
}
[[ -n "$multi_errors" ]] || {
  echo "FAIL: multi decl returned empty 'errors'" >&2
  echo "$multi" >&2; exit 1
}
echo "   ✓ multi decl: count=$multi_count, errors captured"

send '{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"close_idb","arguments":{}}}'
wait_response 99 10 >/dev/null || true

echo "✅ declare_type diagnostics test passed"
