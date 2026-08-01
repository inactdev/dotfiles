#!/bin/sh
# Test suite for herdr-agent-handoff-marker. Runs the real script against a
# mocked `herdr` CLI (see mock_herdr_bin() below) so it never touches a live
# herdr daemon or any real tab - safe to run any time, by anyone, with no
# side effects outside a temp dir. Not deployed: home.nix only symlinks the
# script itself, not this file.
#
# Usage: sh home/.local/bin/herdr-agent-handoff-marker.test.sh
set -eu

# CDPATH= is a one-command env override, not a typo'd assignment: it stops a
# user's CDPATH from resolving the cd to some other directory.
# shellcheck disable=SC1007
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
  # Hermetic PATH, never the ambient one: a real herdr installed elsewhere
  # (e.g. /opt/homebrew/bin/herdr) must be unreachable from every test, or a
  # test that deletes the mock silently drives the owner's live session
  # instead. $MOCK_DIR supplies herdr and jq; /usr/bin and /bin supply the
  # handful of coreutils the script needs (sort, grep, tr, cat).
  # shellcheck disable=SC2068
  FIXTURES="$FIXTURES" PATH="$MOCK_DIR:/usr/bin:/bin" "$SCRIPT" $@
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
t1	fm-one
t2	fm-two
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"
  explain_json osc_title_working >"$FIXTURES/explain_p2.json"

  run_marker --all
  assert_eq "--all: hands-off crewmate tab renamed" "t1	⏳ fm-one" "$(renames)"
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
t1	fm-one
t2	fm-two
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p2.json"

  run_marker --only t2
  assert_eq "--only: named tab renamed, other real agent tab left alone" "t2	⏳ fm-two" "$(renames)"
  teardown
}

test_only_never_calls_explain_on_out_of_scope_pane() {
  setup
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
p2 t2
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	fm-one
t2	fm-two
EOF
  # No explain_p1.json fixture at all: if the script ever asked the mock to
  # explain p1 while scoped to --only t2, the mock would exit 1 - which the
  # script swallows as "skip this pane" rather than failing loudly. So this
  # also checks nothing spurious happened to t1 by watching renames.log.
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p2.json"

  run_marker --only t2
  assert_eq "--only: unscoped pane never touched even without a fixture for it" "t2	⏳ fm-two" "$(renames)"
  teardown
}

test_only_accepts_a_comma_separated_list() {
  setup
  # All three tabs are genuinely handed off; --only names two of them, so the
  # third must stay untouched even though it would qualify under --all.
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
p2 t2
p3 t3
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	fm-one
t2	fm-two
t3	fm-three
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p2.json"
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p3.json"

  run_marker --only t1,t3
  assert_eq "--only t1,t3: both named tabs renamed, unnamed tab left alone" \
    "t1	⏳ fm-one
t3	⏳ fm-three" "$(renames)"
  teardown
}

test_only_equals_form_scopes_the_same_way() {
  setup
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
p2 t2
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	fm-one
t2	fm-two
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p2.json"

  run_marker --only=t2
  assert_eq "--only=t2: = form scopes exactly like the space form" "t2	⏳ fm-two" "$(renames)"
  teardown
}

test_dry_run_prints_but_does_not_rename() {
  setup
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	fm-one
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
t1	⏳ fm-one
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"

  run_marker --only t1
  assert_eq "idempotent: already-prefixed handed-off crewmate tab triggers no rename" "" "$(renames)"
  teardown
}

test_resume_restores_exact_original_label() {
  setup
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	⏳ fm-my-custom-name
EOF
  explain_json osc_title_working >"$FIXTURES/explain_p1.json"

  run_marker --only t1
  assert_eq "resume: prefix stripped, custom name restored exactly" "t1	fm-my-custom-name" "$(renames)"
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
t1	fm-one
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
t1	⏳ fm-one
EOF
  # deliberately no explain_p1.json fixture

  run_marker --all
  assert_eq "failed explain: prefixed crewmate tab left untouched, not stripped" "" "$(renames)"
  teardown
}

test_primary_shaped_tab_never_marked_even_when_handed_off() {
  setup
  # Regression: the captain's own tab (or a secondmate's) is never labeled
  # fm-<id> - only crewmate task tabs created by a spawn are. The
  # fm_handed_off_shell_running rule is pure content screen-scraping, so it
  # matches identically whether the "N shell(s) still running" text shows
  # up in a crewmate pane or the primary's own pane. This is the bug the
  # captain caught live: a primary-shaped tab (label "1", the ordinary
  # herdr-assigned tab name, not fm-*) must never get the hourglass no
  # matter what matched_rule says.
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	1
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"

  run_marker --all
  assert_eq "primary-shaped tab: handed-off content never earns the hourglass" "" "$(renames)"
  teardown
}

test_secondmate_shaped_tab_never_marked_even_when_handed_off() {
  setup
  # Same shape as the primary case, but with a secondmate's own tab label
  # (2ndmate-<id> is the secondmate's home-workspace label; the secondmate's
  # own tab within it, like the primary's, is never fm-*).
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	2ndmate-abc123
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"

  run_marker --all
  assert_eq "secondmate-shaped tab: handed-off content never earns the hourglass" "" "$(renames)"
  teardown
}

test_self_heals_stray_prefix_on_non_crewmate_tab_even_while_still_handed_off() {
  setup
  # Simulates recovering from the pre-fix bug: a primary-shaped tab already
  # carries a stray hourglass from before this scoping existed, and its pane
  # content is STILL matching the handoff rule. The old is_handed_off/
  # has_prefix pairing alone would never strip this (both "mark" and
  # "recover" branches require has_prefix to disagree with is_handed_off).
  # Self-heal must strip it unconditionally because the tab isn't fm-*.
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	⏳ 1
EOF
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"

  run_marker --all
  assert_eq "self-heal: stray hourglass stripped from non-crewmate tab despite still-matching handoff content" \
    "t1	1" "$(renames)"
  teardown
}

test_self_heals_stray_prefix_on_non_crewmate_tab_with_failed_explain() {
  setup
  # Self-heal must not depend on a successful explain call either: the
  # crewmate check is label-only, so even an explain failure (which
  # protects a genuine crewmate's prefix via is_unknown) must not block
  # stripping a stray mark from a tab that was never fm-* to begin with.
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	⏳ 1
EOF
  # deliberately no explain_p1.json fixture

  run_marker --all
  assert_eq "self-heal: stray hourglass stripped from non-crewmate tab even when explain fails" \
    "t1	1" "$(renames)"
  teardown
}

test_herdr_missing_exits_clean() {
  setup
  rm -f "$MOCK_DIR/herdr"
  set +e
  out=$(FIXTURES="$FIXTURES" PATH="$MOCK_DIR:/usr/bin:/bin" "$SCRIPT" --all 2>&1)
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

test_path_isolation_hides_a_real_herdr() {
  setup
  # A real herdr genuinely lives on this machine's PATH (/opt/homebrew/bin).
  # Stand in for it here and prove no test can reach it: the mock is deleted,
  # so if run_marker leaked the ambient PATH the script would find and drive
  # this one instead - which is how a test suite ends up renaming the owner's
  # live tabs.
  REAL_DIR="$TMP/realbin"
  mkdir -p "$REAL_DIR"
  cat >"$REAL_DIR/herdr" <<EOF
#!/bin/sh
printf 'invoked: %s\n' "\$*" >>"$FIXTURES/live_herdr.log"
exit 0
EOF
  chmod +x "$REAL_DIR/herdr"
  rm -f "$MOCK_DIR/herdr"

  set +e
  out=$(
    PATH="$REAL_DIR:$PATH"
    export PATH
    run_marker --all 2>&1
  )
  code=$?
  set -e
  assert_eq "path isolation: exits 0 with no herdr on the hermetic PATH" "0" "$code"
  assert_eq "path isolation: no output" "" "$out"
  assert_eq "path isolation: herdr on the ambient PATH is never invoked" "" "$(cat "$FIXTURES/live_herdr.log" 2>/dev/null || true)"
  teardown
}

test_stale_prefix_stripped_when_pane_is_no_longer_an_agent() {
  setup
  # The pane behind t1 has stopped being reported as an agent at all (owner
  # exited Claude while the handed-off shell kept running), so nothing in
  # `herdr agent list` mentions it. Its hourglass must still come off, and
  # t2's must not - it is outside the --only scope.
  agents_json </dev/null >"$FIXTURES/agents.json"
  tabs_json <<'EOF' >"$FIXTURES/tabs.json"
t1	⏳ fm-my-custom-name
t2	⏳ fm-other
EOF

  run_marker --only t1
  assert_eq "stale prefix: stripped to the exact original label, out-of-scope prefixed tab untouched" "t1	fm-my-custom-name" "$(renames)"
  teardown
}

test_conflicting_scope_flags_rejected() {
  setup
  set +e
  out=$(run_marker --only t1 --all 2>&1)
  code=$?
  set -e
  assert_eq "--only + --all: exits 2 instead of silently sweeping everything" "2" "$code"
  assert_eq "--only + --all: no renames issued" "" "$(renames)"
  case "$out" in
    *"conflicting scope flags"*) : ;;
    *)
      fail_count=$((fail_count + 1))
      printf 'FAIL - --only + --all: explains the conflict\n  actual: %s\n' "$out"
      ;;
  esac

  set +e
  out=$(run_marker --all --only t1 2>&1)
  code=$?
  set -e
  assert_eq "--all + --only (reverse order): also exits 2" "2" "$code"
  teardown
}

test_only_without_a_value_exits_2() {
  setup
  set +e
  out=$(run_marker --only 2>&1)
  code=$?
  set -e
  assert_eq "--only with no value: exits 2, not a bare set -e abort (1)" "2" "$code"
  assert_eq "--only with no value: no renames issued" "" "$(renames)"
  case "$out" in
    *"--only requires at least one tab id"*) : ;;
    *)
      fail_count=$((fail_count + 1))
      printf 'FAIL - --only with no value: prints the documented message\n  actual: %s\n' "$out"
      ;;
  esac
  teardown
}

test_null_label_is_skipped() {
  setup
  agents_json <<'EOF' >"$FIXTURES/agents.json"
p1 t1
EOF
  printf '{"result":{"tabs":[{"tab_id":"t1","label":null}]}}' >"$FIXTURES/tabs.json"
  explain_json fm_handed_off_shell_running >"$FIXTURES/explain_p1.json"

  run_marker --only t1
  assert_eq "null label: tab skipped, never renamed to a literal 'null'" "" "$(renames)"
  teardown
}

test_no_args_refuses
test_all_sweeps_every_agent_tab
test_only_scopes_to_named_tabs
test_only_never_calls_explain_on_out_of_scope_pane
test_only_accepts_a_comma_separated_list
test_only_equals_form_scopes_the_same_way
test_dry_run_prints_but_does_not_rename
test_idempotent_no_double_prefix
test_resume_restores_exact_original_label
test_overlay_rule_does_not_false_positive
test_explain_failure_leaves_tab_untouched
test_primary_shaped_tab_never_marked_even_when_handed_off
test_secondmate_shaped_tab_never_marked_even_when_handed_off
test_self_heals_stray_prefix_on_non_crewmate_tab_even_while_still_handed_off
test_self_heals_stray_prefix_on_non_crewmate_tab_with_failed_explain
test_herdr_missing_exits_clean
test_herdr_failing_exits_clean
test_path_isolation_hides_a_real_herdr
test_stale_prefix_stripped_when_pane_is_no_longer_an_agent
test_conflicting_scope_flags_rejected
test_only_without_a_value_exits_2
test_null_label_is_skipped

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
