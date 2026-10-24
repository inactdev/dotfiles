#!/usr/bin/env bash
# Test suite for modules/inkwell-tailscale-serve.sh - the activation step
# that publishes the local Inkwell backend on this machine's tailnet
# address, once, and refuses to touch an existing serve configuration.
#
# Hermetic, and it has to be: the one thing this step must never do is
# reconfigure a real tailnet from a dev or test session. So `tailscale` here
# is a stub that answers `serve status --json` from a fixture and records
# every call, and the candidate list the script searches for a CLI is
# pointed at a scratch directory - which also means the "no CLI anywhere"
# case tests the same on a machine that has Tailscale installed as on one
# that does not. `timeout` is stubbed too, by a wrapper that logs the
# duration it was asked for and then runs the command immediately: the
# non-blocking promise is checkable that way without a test that waits a
# minute to prove it.
#
# Usage: bash modules/inkwell-tailscale-serve.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SERVE="$SCRIPT_DIR/inkwell-tailscale-serve.sh"
PORT=8080

pass_count=0
fail_count=0

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
    printf 'ok - %s\n' "$desc"
  else
    fail_count=$((fail_count + 1))
    printf 'FAIL - %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
  fi
}

assert_contains() {
  local desc=$1 haystack=$2 needle=$3
  case "$haystack" in
    *"$needle"*)
      pass_count=$((pass_count + 1))
      printf 'ok - %s\n' "$desc"
      ;;
    *)
      fail_count=$((fail_count + 1))
      printf 'FAIL - %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
      ;;
  esac
}

assert_not_contains() {
  local desc=$1 haystack=$2 needle=$3
  case "$haystack" in
    *"$needle"*)
      fail_count=$((fail_count + 1))
      printf 'FAIL - %s\n  expected NOT to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
      ;;
    *)
      pass_count=$((pass_count + 1))
      printf 'ok - %s\n' "$desc"
      ;;
  esac
}

setup() {
  unset TMPDIR
  TMP=$(mktemp -d)
  HOME="$TMP/home"
  MOCK_DIR="$TMP/mock"
  CLI_DIR="$TMP/cli"
  STATE="$TMP/state"
  CLI="$CLI_DIR/tailscale"
  CALLS="$STATE/calls"
  mkdir -p "$HOME" "$MOCK_DIR" "$CLI_DIR" "$STATE"
  PATH="$MOCK_DIR:/usr/bin:/bin"
  # Only the scratch CLI is ever a candidate, so no real tailscale on the
  # machine running this can be reached or consulted.
  INKWELL_TS_CLI_CANDIDATES=$CLI
  export HOME PATH STATE INKWELL_TS_CLI_CANDIDATES

  : >"$CALLS"
  printf 'null\n' >"$STATE/status"
  printf '0\n' >"$STATE/status-exit"
  printf '0\n' >"$STATE/serve-exit"
  stub_timeout
  make_cli
}

teardown() {
  rm -rf "$TMP"
}

# `timeout <duration> <command...>`: records what it was asked to bound and
# then runs it without waiting.
stub_timeout() {
  cat >"$MOCK_DIR/timeout" <<'STUB'
#!/bin/sh
echo "timeout $*" >>"$STATE/calls"
shift
exec "$@"
STUB
  chmod +x "$MOCK_DIR/timeout"
}

# The stub CLI. Records its arguments and whether it was told to be a CLI at
# all, answers `serve status --json` from the fixture, and reports what the
# real one reports on success for `serve --bg`.
make_cli() {
  cat >"$CLI" <<'STUB'
#!/bin/sh
echo "tailscale $* be-cli=${TAILSCALE_BE_CLI:-unset}" >>"$STATE/calls"
if [ "${1:-}" = "serve" ] && [ "${2:-}" = "status" ]; then
  [ -f "$STATE/status-stderr" ] && cat "$STATE/status-stderr" >&2
  cat "$STATE/status"
  exit "$(cat "$STATE/status-exit")"
fi
if [ "${1:-}" = "serve" ]; then
  if [ "$(cat "$STATE/serve-exit")" != 0 ]; then
    echo "stub: serve refused" >&2
    exit "$(cat "$STATE/serve-exit")"
  fi
  echo "Available within your tailnet:"
  echo "https://mac.tailnet.ts.net/"
  echo "|-- proxy http://127.0.0.1:8080"
fi
exit 0
STUB
  chmod +x "$CLI"
}

# A serve configuration as `tailscale serve status --json` prints one: a
# node-level web handler on 443 proxying to $1.
status_proxying_to() {
  cat >"$STATE/status" <<JSON
{
  "Web": {
    "mac.tailnet.ts.net:443": {
      "Handlers": {
        "/": {
          "Proxy": "$1"
        }
      }
    }
  }
}
JSON
}

run_serve() {
  SERVE_OUT=$(bash "$SERVE" "$PORT" 2>"$TMP/err")
  SERVE_RC=$?
  SERVE_ERR=$(cat "$TMP/err")
  CALL_LOG=$(cat "$CALLS")
}

test_unconfigured_node_is_published() {
  setup
  run_serve

  assert_eq "exits 0" 0 "$SERVE_RC"
  assert_contains "publishes the port in the background" "$CALL_LOG" "tailscale serve --bg $PORT"
  assert_contains "under a timeout, so it can never block a switch" "$CALL_LOG" \
    "timeout 60 $CLI serve --bg $PORT"
  assert_contains "reading the current configuration under one too" "$CALL_LOG" \
    "timeout 30 $CLI serve status --json"
  assert_contains "insists on being the CLI, not the GUI app" "$CALL_LOG" "be-cli=1"
  assert_contains "says it survives a reboot" "$SERVE_OUT" "survives a reboot"
  teardown
}

test_an_empty_configuration_counts_as_unconfigured() {
  setup
  printf '{}\n' >"$STATE/status"
  run_serve

  assert_contains "publishes the port" "$CALL_LOG" "serve --bg $PORT"
  teardown
}

test_a_node_already_serving_this_port_is_left_alone() {
  setup
  status_proxying_to "http://127.0.0.1:$PORT"
  run_serve

  assert_eq "exits 0" 0 "$SERVE_RC"
  assert_contains "says it is already published" "$SERVE_OUT" "already publishes port $PORT"
  assert_not_contains "and reconfigures nothing" "$CALL_LOG" "serve --bg"
  teardown
}

test_a_proxy_to_localhost_by_name_counts_too() {
  setup
  status_proxying_to "http://localhost:$PORT"
  run_serve

  assert_contains "says it is already published" "$SERVE_OUT" "already publishes port $PORT"
  assert_not_contains "and reconfigures nothing" "$CALL_LOG" "serve --bg"
  teardown
}

test_another_services_configuration_is_never_overwritten() {
  setup
  status_proxying_to "http://127.0.0.1:3000"
  run_serve

  assert_eq "never fails the switch" 0 "$SERVE_RC"
  assert_contains "says what it refused to do" "$SERVE_ERR" "already serves something over tailscale"
  assert_contains "and names the command to do it by hand" "$SERVE_ERR" "serve --bg $PORT"
  assert_not_contains "but calls nothing itself" "$CALL_LOG" "tailscale serve --bg"
  teardown
}

test_a_port_that_merely_starts_with_these_digits_is_not_this_port() {
  setup
  # :80801 and :18080 both contain the digits, and neither is this port.
  cat >"$STATE/status" <<'JSON'
{
  "Web": {
    "mac.tailnet.ts.net:443": {
      "Handlers": {
        "/one": { "Proxy": "http://127.0.0.1:80801" },
        "/two": { "Proxy": "http://127.0.0.1:18080" }
      }
    }
  }
}
JSON
  run_serve

  assert_contains "reads as somebody else's configuration" "$SERVE_ERR" \
    "already serves something over tailscale"
  assert_not_contains "not as this port being published" "$SERVE_OUT" "already publishes port"
  teardown
}

test_a_path_mounted_under_the_proxy_still_counts() {
  setup
  status_proxying_to "http://127.0.0.1:$PORT/inkwell"
  run_serve

  assert_contains "says it is already published" "$SERVE_OUT" "already publishes port $PORT"
  teardown
}

test_unreadable_configuration_changes_nothing() {
  setup
  printf '1\n' >"$STATE/status-exit"
  printf 'failed to connect to local tailscaled\n' >"$STATE/status"
  run_serve

  assert_eq "never fails the switch" 0 "$SERVE_RC"
  assert_contains "warns on stderr" "$SERVE_ERR" "could not read the current serve configuration"
  assert_contains "passing on tailscale's own answer" "$SERVE_ERR" \
    "failed to connect to local tailscaled"
  assert_not_contains "and configures nothing blind" "$CALL_LOG" "serve --bg"
  teardown
}

test_chatter_on_stderr_is_not_mistaken_for_a_configuration() {
  setup
  # An unconfigured node, with the CLI writing something unrelated alongside
  # it - an update notice, say. Folding that into the configuration would
  # stop this step for the wrong reason.
  printf 'null\n' >"$STATE/status"
  printf 'A new version of Tailscale is available\n' >"$STATE/status-stderr"
  run_serve

  assert_contains "still publishes the port" "$CALL_LOG" "serve --bg $PORT"
  assert_not_contains "and never calls it somebody else's" "$SERVE_ERR" "already serves something"
  teardown
}

test_a_refused_publish_is_a_warning_not_a_failure() {
  setup
  printf '124\n' >"$STATE/serve-exit"
  run_serve

  assert_eq "never fails the switch" 0 "$SERVE_RC"
  assert_contains "warns that the backend stays local" "$SERVE_ERR" "stays local to this machine"
  assert_contains "and names the usual cause" "$SERVE_ERR" "HTTPS certificates"
  teardown
}

test_no_cli_anywhere_is_reported_and_survivable() {
  setup
  rm -f "$CLI"
  run_serve

  assert_eq "never fails the switch" 0 "$SERVE_RC"
  assert_contains "says there is no CLI" "$SERVE_ERR" "no tailscale CLI found"
  assert_contains "and that the backend is still local" "$SERVE_ERR" "http://127.0.0.1:$PORT"
  assert_eq "calls nothing" "" "$CALL_LOG"
  teardown
}

test_the_first_candidate_that_exists_wins() {
  setup
  # Two candidates, the first of them missing - the shape of a Mac with no
  # /usr/local/bin/tailscale launcher but the app bundle's binary present.
  INKWELL_TS_CLI_CANDIDATES="$TMP/nowhere/tailscale $CLI"
  export INKWELL_TS_CLI_CANDIDATES
  run_serve

  assert_contains "falls through to the one that is there" "$CALL_LOG" "tailscale serve --bg $PORT"
  teardown
}

test_unconfigured_node_is_published
test_an_empty_configuration_counts_as_unconfigured
test_a_node_already_serving_this_port_is_left_alone
test_a_proxy_to_localhost_by_name_counts_too
test_another_services_configuration_is_never_overwritten
test_a_port_that_merely_starts_with_these_digits_is_not_this_port
test_a_path_mounted_under_the_proxy_still_counts
test_unreadable_configuration_changes_nothing
test_chatter_on_stderr_is_not_mistaken_for_a_configuration
test_a_refused_publish_is_a_warning_not_a_failure
test_no_cli_anywhere_is_reported_and_survivable
test_the_first_candidate_that_exists_wins

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
