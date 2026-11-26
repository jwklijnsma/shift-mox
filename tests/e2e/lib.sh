#!/usr/bin/env bash
# Helpers shared by the end-to-end test scripts (sourced, not run).

c_off=$'\e[0m' c_info=$'\e[1;34m' c_ok=$'\e[1;32m' c_warn=$'\e[1;33m' c_err=$'\e[1;31m'
[[ -t 1 ]] || c_off="" c_info="" c_ok="" c_warn="" c_err=""

ts()    { date +%H:%M:%S; }
info()  { printf '%s [%s] %s%s\n' "$c_info" "$(ts)" "$*" "$c_off"; }
pass()  { printf '%s [%s] PASS %s%s\n' "$c_ok" "$(ts)" "$*" "$c_off"; }
warn()  { printf '%s [%s] WARN %s%s\n' "$c_warn" "$(ts)" "$*" "$c_off" >&2; }
fail()  { printf '%s [%s] FAIL %s%s\n' "$c_err" "$(ts)" "$*" "$c_off" >&2; return 1; }
die()   { printf '%s [%s] %s%s\n' "$c_err" "$(ts)" "$*" "$c_off" >&2; exit 1; }

# wait_for <timeout-seconds> <description> <command...>
# Runs the command every 15 s until it succeeds; prints progress every minute.
wait_for() {
  local timeout="$1" what="$2" start now last=0
  shift 2
  start=$(date +%s)
  info "waiting for: $what (max $((timeout / 60)) min)"
  while true; do
    if "$@" >/dev/null 2>&1; then
      pass "$what ($(( $(date +%s) - start )) s)"
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      fail "$what: still not true after $((timeout / 60)) min"
      return 1
    fi
    if (( now - last >= 60 )); then
      printf '      ... %s min\n' "$(( (now - start) / 60 ))"
      last=$now
    fi
    sleep 15
  done
}

# oc against the cluster under test (OC and KUBECONFIG set by the caller)
k() { "$OC" --request-timeout=60s "$@"; }

# Run a check: record PASS/FAIL, keep going. CHECK_FAILED counts the failures.
CHECK_FAILED=0
check() {
  local what="$1"; shift
  if "$@"; then pass "$what"; else CHECK_FAILED=$((CHECK_FAILED + 1)); fail "$what" || true; fi
}
