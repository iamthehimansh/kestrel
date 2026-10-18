#!/bin/bash
# Keep long subprocess output visible while reporting elapsed time.
run_step() {
  local label="$1"; shift
  local start=$SECONDS pid heartbeat result
  printf '[%s] %s START\n' "$(date +%H:%M:%S)" "$label"
  "$@" &
  pid=$!
  (
    while kill -0 "$pid" 2>/dev/null; do
      sleep 10
      if kill -0 "$pid" 2>/dev/null; then
        printf '[%s] %s active %ss; awaiting completion\n' "$(date +%H:%M:%S)" "$label" "$((SECONDS-start))"
      fi
    done
  ) &
  heartbeat=$!
  if wait "$pid"; then result=0; else result=$?; fi
  kill "$heartbeat" 2>/dev/null || :
  wait "$heartbeat" 2>/dev/null || :
  printf '[%s] %s END exit=%s elapsed=%ss\n' "$(date +%H:%M:%S)" "$label" "$result" "$((SECONDS-start))"
  return "$result"
}
