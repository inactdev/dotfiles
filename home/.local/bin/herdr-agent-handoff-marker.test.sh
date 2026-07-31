#!/bin/sh
# Test suite for herdr-agent-handoff-marker. Runs the real script against a
# mocked `herdr` CLI (see mock_herdr() below) so it never touches a live
# herdr daemon or any real tab - safe to run any time, by anyone, with no
# side effects outside a temp dir. Not deployed: home.nix only symlinks the
# script itself, not this file.
#
# Usage: sh home/.local/bin/herdr-agent-handoff-marker.test.sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SCRIPT="$SCRIPT_DIR/herdr-agent-handoff-marker"

pass_count=0
fail_count=0

# --- mock herdr -------------------------------------------------------
# Driven entirely by fixture files under $FIXTURES, set up per test:
#   agents.json                 -> `herdr agent list` response
#   tabs.json                   -> `herdr tab list` response
#   explain_<pane_id>.json      -> `herdr agent explain <pane_id> --json`
#                                   response; missing file = explain fails
#   renames.log                 -> appended "<tab_id>\t<label>" per real
#                                   (non-dry-run) `herdr tab rename` call
mock_herdr_bin() {
  dir=$1
  cat >"$dir/herdr" <<'MOCK'
#!/bin/sh
set -eu
[ -n "${FIXTURES:-}" ] || { echo "mock herdr: FIXTURES not set" >&2; exit 1; }
case "$1 $2" in
  "agent list")
    cat "$FIXTURES/agents.json"
    ;;
  "tab list")
    cat "$FIXTURES/tabs.json"
    ;;
  "agent explain")
    pane_id=$3
    f="$FIXTURES/explain_${pane_id}.json"
    [ -f "$f" ] || exit 1
    cat "$f"
    ;;
  "tab rename")
    shift 2
    tab_id=$1
    shift
    printf '%s\t%s\n' "$tab_id" "$*" >>"$FIXTURES/renames.log"
    ;;
  *)
    echo "mock herdr: unhandled args: $*" >&2
    exit 1
    ;;
esac
MOCK
  chmod +x "$dir/herdr"
}

# --- fixture builders ---------------------------------------------------
agents_json() {
  # $1 = "pane_id tab_id" pairs, one per line
  printf '{"result":{"agents":['
  first=1
  while IFS=' ' read -r pane_id tab_id; do
    [ -n "$pane_id" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"pane_id":"%s","tab_id":"%s"}' "$pane_id" "$tab_id"
  done
  printf ']}}'
}

tabs_json() {
  # $1 = "tab_id\tlabel" pairs, one per line
  printf '{"result":{"tabs":['
  first=1
  while IFS='	' read -r tab_id label; do
    [ -n "$tab_id" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"tab_id":"%s","label":"%s"}' "$tab_id" "$label"
  done
  printf ']}}'
}

explain_json() {
  # $1 = matched_rule id, $2 = optional extra evaluated_rules matched id
  # (simulates the handoff rule still matching underneath a higher-priority
  # non-handoff winner, e.g. the osc_title_working regression case)
  top=$1
  extra=${2:-}
  printf '{"matched_rule":{"id":"%s"},"evaluated_rules":[{"id":"%s","matched":true}' "$top" "$top"
  if [ -n "$extra" ]; then
    printf ',{"id":"%s","matched":true}' "$extra"
  fi
  printf ']}'
}

# --- test scaffolding -----------------------------------------------------
setup() {
  TMP=$(mktemp -d)
  MOCK_DIR="$TMP/bin"
  FIXTURES="$TMP/fixtures"
  mkdir -p "$MOCK_DIR" "$FIXTURES"
  mock_herdr_bin "$MOCK_DIR"
  JQ_BIN=$(command -v jq)
  ln -s "$JQ_BIN" "$MOCK_DIR/jq"
  : >"$FIXTURES/renames.log"
}

teardown() {
  rm -rf "$TMP"
}

run_marker() {
  # shellcheck disable=SC2068
  FIXTURES="$FIXTURES" PATH="$MOCK_DIR:$PATH" "$SCRIPT" $@
}

renames() {
  cat "$FIXTURES/renames.log"
}

assert_eq() {
  desc=$1
  expected=$2
  actual=$3
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
    printf 'ok - %s\n' "$desc"
  else
    fail_count=$((fail_count + 1))
    printf 'FAIL - %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
  fi
}

# --- tests ------------------------------------------------------------

test_no_args_refuses() {
  setup
  set +e
  out=$(run_marker 2>&1)
  code=$?
  set -e
  assert_eq "no args: exits with usage error (2)" "2" "$code"
  assert_eq "no args: no renames issued" "" "$(renames)"
  case "$out" in
    *"explicit scope"*) : ;;
    *)
      fail_count=$((fail_count + 1))
      printf 'FAIL - no args: usage message mentions explicit scope\n  actual: %s\n' "$out"
      ;;
  esac
  teardown
}

test_all_sweeps_every_agent_tab() {
  setup
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
p2 t2
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	one
t2	two
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"
  explain_json osc_title_working >"$FIXTURES/explain_p2.json"

  run_marker --all
  assert_eq "--all: hands-off tab renamed" "t1	⏳ one" "$(renames)"
  teardown
}

test_only_scopes_to_named_tabs() {
  setup
  # Both t1 and t2 are genuinely handed off, but --only names just t2.
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
p2 t2
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	one
t2	two
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p2.json"

  run_marker --only t2
  assert_eq "--only: named tab renamed, other real agent tab left alone" "t2	⏳ two" "$(renames)"
  teardown
}

test_only_never_calls_explain_on_out_of_scope_pane() {
  setup
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
p2 t2
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	one
t2	two
EOF
  # No explain_p1.json fixture at all: if the script ever asked the mock to
  # explain p1 while scoped to --only t2, the mock would exit 1 - which the
  # script swallows as "skip this pane" rather than failing loudly. So this
  # also checks nothing spurious happened to t1 by watching renames.log.
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p2.json"

  run_marker --only t2
  assert_eq "--only: unscoped pane never touched even without a fixture for it" "t2	⏳ two" "$(renames)"
  teardown
}

test_dry_run_prints_but_does_not_rename() {
  setup
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	one
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"

  out=$(run_marker --only t1 --dry-run)
  assert_eq "--dry-run: no rename call issued" "" "$(renames)"
  case "$out" in
    *"would rename t1"*) : ;;
    *)
      fail_count=$((fail_count + 1))
      printf 'FAIL - --dry-run: prints intended change\n  actual: %s\n' "$out"
      ;;
  esac
  teardown
}

test_idempotent_no_double_prefix() {
  setup
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	⏳ one
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"

  run_marker --only t1
  assert_eq "idempotent: already-prefixed handed-off tab triggers no rename" "" "$(renames)"
  teardown
}

test_resume_restores_exact_original_label() {
  setup
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	⏳ my-custom-name
EOF
  explain_json osc_title_working >"$FIXTURES/explain_p1.json"

  run_marker --only t1
  assert_eq "resume: prefix stripped, custom name restored exactly" "t1	my-custom-name" "$(renames)"
  teardown
}

test_overlay_rule_does_not_false_positive() {
  setup
  # Regression: matched_rule is osc_title_working (actively thinking), but
  # fm_handed_off_shell_running still shows matched=true underneath (stale
  # "N shell(s) still running" text still in the trailing-lines window).
  # Must NOT be treated as handed off - this is exactly the bug the owner
  # caught live.
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	one
EOF
  explain_json osc_title_working fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"

  run_marker --only t1
  assert_eq "actively-thinking pane with stale handoff evidence gets NO hourglass" "" "$(renames)"
  teardown
}

test_explain_failure_leaves_tab_untouched() {
  setup
  # t1 is already prefixed; its pane's explain call fails this tick (no
  # fixture file for p1). Must NOT be treated as "not handed off" and
  # stripped - must be left alone entirely.
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	⏳ one
EOF
  # deliberately no explain_p1.json fixture

  run_marker --all
  assert_eq "failed explain: prefixed tab left untouched, not stripped" "" "$(renames)"
  teardown
}

test_herdr_missing_exits_clean() {
  setup
  rm -f "$MOCK_DIR/herdr"
  set +e
  out=$(PATH="$MOCK_DIR:$PATH" "$SCRIPT" --all 2>&1)
  code=$?
  set -e
  assert_eq "herdr absent: exits 0" "0" "$code"
  assert_eq "herdr absent: no output" "" "$out"
  assert_eq "herdr absent: no renames" "" "$(renames)"
  teardown
}

test_herdr_failing_exits_clean() {
  setup
  cat >"$MOCK_DIR/herdr" <<'EOF'
#!/bin/sh
echo "simulated: could not connect to herdr socket" >&2
exit 1
EOF
  chmod +x "$MOCK_DIR/herdr"
  set +e
  out=$(run_marker --all 2>&1)
  code=$?
  set -e
  assert_eq "herdr failing: exits 0" "0" "$code"
  assert_eq "herdr failing: no output" "" "$out"
  assert_eq "herdr failing: no renames" "" "$(renames)"
  teardown
}

test_no_args_refuses
test_all_sweeps_every_agent_tab
test_only_scopes_to_named_tabs
test_only_never_calls_explain_on_out_of_scope_pane
test_dry_run_prints_but_does_not_rename
test_idempotent_no_double_prefix
test_resume_restores_exact_original_label
test_overlay_rule_does_not_false_positive
test_explain_failure_leaves_tab_untouched
test_herdr_missing_exits_clean
test_herdr_failing_exits_clean

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
