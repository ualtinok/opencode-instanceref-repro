#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Minimal "InstanceRef not provided" reproducer driver.
#
# 1. Start aimock (OpenAI-compatible mock LLM) in the background.
# 2. Run `opencode run` with the mock provider; the mock answers turn #0
#    with a tool call to our minimal `repro_check` plugin tool.
# 3. The plugin tool calls Effect.runPromise(context.ask(...)) — which
#    hits the broken cache-miss path in InstanceState.get on 1.15.4+.
# 4. Grep the run output for "InstanceRef not provided".
#    Exit 0 = REPRODUCED, exit 1 = NOT REPRODUCED.
# ---------------------------------------------------------------------------
set -euo pipefail

MOCK_LOG=/tmp/instanceref-mock.log
OC_OUT=/tmp/instanceref-opencode.stdout
OC_ERR=/tmp/instanceref-opencode.stderr
rm -f "$MOCK_LOG" "$OC_OUT" "$OC_ERR"

echo "=== OpenCode version ==="
opencode --version

echo "=== OpenCode config ==="
cat /root/.config/opencode/opencode.json

echo "=== Starting aimock ==="
node /usr/local/bin/instanceref-mock-server.js > "$MOCK_LOG" 2>&1 &
mock_pid=$!

# Wait for aimock to be listening.
for _ in $(seq 1 40); do
  if grep -q "aimock] listening" "$MOCK_LOG" 2>/dev/null; then break; fi
  sleep 0.25
done
if ! grep -q "aimock] listening" "$MOCK_LOG" 2>/dev/null; then
  echo "ERROR: aimock failed to start within 10s" >&2
  cat "$MOCK_LOG" >&2 || true
  kill "$mock_pid" 2>/dev/null || true
  exit 2
fi

echo "=== aimock reachable? ==="
curl -sS http://127.0.0.1:4010/v1/models | head -c 300 || echo "FAILED"
echo ""

echo "=== Running opencode with mock-model ==="
# OPENAI_API_KEY is required by opencode's OpenAI provider adapter even
# though we're hitting a mock endpoint. --dangerously-skip-permissions
# makes opencode run our plugin's ctx.ask path with auto-allow instead
# of immediately rejecting it (which would short-circuit before the bug).
# `timeout --signal=KILL 60` mirrors AFT's own e2e harness — `opencode run`
# does not gracefully exit after a session in non-interactive mode; the
# success signal is the work that happens before the kill.
set +e
OPENAI_API_KEY=sk-mock-instanceref-repro \
timeout --signal=KILL 60 opencode run \
  --model mock/mock-model \
  --dangerously-skip-permissions \
  "Please call the repro_check tool to probe the InstanceRef behavior." \
  > "$OC_OUT" 2> "$OC_ERR" < /dev/null
oc_status=$?
set -e

# `timeout` exit codes: 0 = clean exit, 124 = TERM timeout, 137 = KILL.
# All three mean the session got far enough to either complete or be
# reaped — they're not failures of the harness itself.

kill "$mock_pid" 2>/dev/null || true
sleep 0.3
kill -9 "$mock_pid" 2>/dev/null || true
wait "$mock_pid" 2>/dev/null || true

echo "=== opencode exit status: $oc_status ==="

echo "=== opencode stdout (tail 40) ==="
tail -40 "$OC_OUT" 2>/dev/null || true

echo "=== opencode stderr (tail 40) ==="
tail -40 "$OC_ERR" 2>/dev/null || true

echo "=== aimock log (tail 20) ==="
tail -20 "$MOCK_LOG" 2>/dev/null || true

stdout_hits=$(grep -c "InstanceRef not provided" "$OC_OUT" 2>/dev/null || true)
stderr_hits=$(grep -c "InstanceRef not provided" "$OC_ERR" 2>/dev/null || true)
total=$((stdout_hits + stderr_hits))

echo "=== Summary ==="
echo "InstanceRef matches in stdout: $stdout_hits"
echo "InstanceRef matches in stderr: $stderr_hits"

if [ "$total" -ge 1 ]; then
  echo "REPRODUCED: \"InstanceRef not provided\" surfaced during a normal plugin permission ask."
  exit 0
fi

echo "NOT REPRODUCED."
echo "Possible causes:"
echo "  - OpenCode shipped the InstanceState.get cached-lookup fix"
echo "  - the mock LLM never produced the tool call (check aimock log above)"
echo "  - opencode failed to load the plugin (check stderr above)"
exit 1
