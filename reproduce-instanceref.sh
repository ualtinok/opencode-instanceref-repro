#!/usr/bin/env bash
set -euo pipefail

LOG=/tmp/instanceref-repro.log
OC_STDOUT=/tmp/opencode-instanceref.stdout
OC_STDERR=/tmp/opencode-instanceref.stderr

rm -f "$LOG" "$OC_STDOUT" "$OC_STDERR"

printf '%s\n' '=== OpenCode version ==='
opencode --version

printf '%s\n' '=== Minimal OpenCode config ==='
cat /root/.config/opencode/opencode.jsonc

printf '%s\n' '=== Starting OpenCode TUI briefly to trigger plugin init + probes ==='
opencode /work/project --print-logs \
  > "$OC_STDOUT" \
  2> "$OC_STDERR" &
opencode_pid=$!

# Wait until either the log shows a REPRODUCED line, all probes have run
# (5 lines tagged "PROBE init"), or 30s elapsed.
for _ in $(seq 1 120); do
  if [ -s "$LOG" ]; then
    if grep -q "REPRODUCED:" "$LOG"; then
      break
    fi
    if [ "$(grep -c 'PROBE init' "$LOG" || true)" -ge 5 ]; then
      # All init probes completed; give async errors a beat to land.
      sleep 1
      break
    fi
  fi
  if ! kill -0 "$opencode_pid" 2>/dev/null; then
    break
  fi
  sleep 0.25
done

kill "$opencode_pid" 2>/dev/null || true
sleep 1
kill -9 "$opencode_pid" 2>/dev/null || true
set +e
wait "$opencode_pid" 2>/dev/null
status=$?
set -e
printf 'opencode exit status: %s\n' "$status"

printf '%s\n' '=== OpenCode startup lines ==='
grep -E 'version=|service=|InstanceRef|loading plugin|bootstrapping' "$OC_STDERR" 2>/dev/null | head -40 || true

printf '%s\n' '=== Reproducer plugin log ==='
if [ ! -s "$LOG" ]; then
  printf '%s\n' 'ERROR: plugin log was not created — plugin did not load.'
  printf '%s\n' '--- opencode stderr tail ---'
  tail -80 "$OC_STDERR" || true
  exit 1
fi
cat "$LOG"

reproduced_count=$(grep -c "REPRODUCED:" "$LOG" || true)
instance_ref_matches=$(grep -c "instance_ref_match=true" "$LOG" || true)
probe_init_count=$(grep -c "PROBE init" "$LOG" || true)
probe_error_count=$(grep -c "PROBE init.*ERROR" "$LOG" || true)

printf '%s\n' '=== Summary ==='
printf 'init probes total:        %s\n' "$probe_init_count"
printf 'init probes failed:       %s\n' "$probe_error_count"
printf 'instance_ref_match=true:  %s\n' "$instance_ref_matches"
printf 'REPRODUCED lines:         %s\n' "$reproduced_count"

printf '%s\n' '=== Server-side error scan (opencode stderr) ==='
grep -c "InstanceRef not provided" "$OC_STDERR" 2>/dev/null || true
grep -B1 -A4 "InstanceRef not provided" "$OC_STDERR" 2>/dev/null | head -40 || true

if [ "$reproduced_count" -ge 1 ] || [ "$instance_ref_matches" -ge 1 ]; then
  printf '%s\n' 'REPRODUCED: at least one SDK probe returned "InstanceRef not provided".'
  exit 0
fi

if grep -q "InstanceRef not provided" "$OC_STDERR" 2>/dev/null; then
  printf '%s\n' 'REPRODUCED: "InstanceRef not provided" appeared in opencode stderr even though all probes succeeded.'
  printf '%s\n' '(server-side dies that did not propagate back to the SDK caller)'
  exit 0
fi

printf '%s\n' 'NOT REPRODUCED: no probe surfaced "InstanceRef not provided".'
printf '%s\n' 'Possible causes:'
printf '%s\n' '  - PR #25694 has been merged and this OpenCode version is fixed'
printf '%s\n' '  - the chosen probes do not hit the broken cache-miss path on this version'
printf '%s\n' '  - the probes ran after some other consumer warmed the cache'
exit 1
