#!/bin/bash

# The suite's own guarantees.
#
# A test suite is trusted more than the code it covers, because a green run is
# read as "nothing is wrong" rather than as "nothing was checked". The ways this
# one could stay green while verifying nothing are what this file is about, and
# so are the two reports, whose consumer is a parser rather than a reader.

# The runner reads its case files as text to list them in declaration order, so
# a definition merely quoted in this file would be discovered and run as part of
# the outer suite. The probe below therefore names its own test cases through
# this prefix rather than writing "test_" out
readonly PROBE_PREFIX="test"

# Build a throwaway suite around a case file of a given body, run the real
# runner over it, and print its output. The runner derives everything from its
# own path, so a copy of tests/ beside a copy of the repository is enough
# Usage : OUTPUT=$(run_a_probe_suite 'function test_x() { assert_equals 1 1 ; }')
function run_a_probe_suite() {
  local -r CASE_FILE_BODY="$1"
  shift
  local -r PROBE_ROOT="$CASE_DIRECTORY/probe_${RANDOM}"

  rm -rf "$PROBE_ROOT"
  mkdir -p "$PROBE_ROOT/tests/cases"

  # The real src/, so that the probe finds both the binary the runner refuses to
  # start without and the sources its unit tests are linked from. The probes are
  # about the runner, not about ext4magic
  ln -s "$REPO_ROOT/src" "$PROBE_ROOT/src"
  cp "$TESTS_DIRECTORY/run_tests.sh" "$PROBE_ROOT/tests/"
  cp -r "$TESTS_DIRECTORY/lib" "$TESTS_DIRECTORY/unit" "$PROBE_ROOT/tests/"

  printf '%s\n' "$CASE_FILE_BODY" > "$PROBE_ROOT/tests/cases/50_probe.sh"

  bash "$PROBE_ROOT/tests/run_tests.sh" --no-color "$@" 2>&1
  return 0
}

# The same, keeping the probe's directory so a report written into it can be
# read back. The directory is printed
function run_a_probe_suite_in() {
  local -r PROBE_ROOT="$1"
  local -r CASE_FILE_BODY="$2"
  shift 2

  rm -rf "$PROBE_ROOT"
  mkdir -p "$PROBE_ROOT/tests/cases"
  ln -s "$REPO_ROOT/src" "$PROBE_ROOT/src"
  cp "$TESTS_DIRECTORY/run_tests.sh" "$PROBE_ROOT/tests/"
  cp -r "$TESTS_DIRECTORY/lib" "$TESTS_DIRECTORY/unit" "$PROBE_ROOT/tests/"
  printf '%s\n' "$CASE_FILE_BODY" > "$PROBE_ROOT/tests/cases/50_probe.sh"

  bash "$PROBE_ROOT/tests/run_tests.sh" --no-color "$@" > "$PROBE_ROOT/output" 2>&1
  printf '%s' "$PROBE_ROOT"
}


function test_a_test_case_that_asserts_nothing_is_reported_as_a_failure() {
  # The one failure a passing suite cannot show you : a test case that returned
  # early on a condition that no longer holds verifies nothing and looks green
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_checks_nothing() { return 0 ; }")"

  assert_contains "$OUTPUT" "recorded no assertion" "the runner says what is wrong"
  assert_contains "$OUTPUT" "1 test cases failed" "and counts it as a failure"
}

function test_a_test_case_whose_assertion_fails_is_reported_with_what_it_expected() {
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_fails() { assert_equals \"5\" \"7\" \"a message the report carries\" ; }")"

  assert_contains "$OUTPUT" "a message the report carries" "the assertion's own message"
  assert_contains "$OUTPUT" "expected: [5]" "what it expected"
  assert_contains "$OUTPUT" "actual:   [7]" "and what it got"
}

function test_a_test_case_that_crashes_is_reported_rather_than_ending_the_run() {
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_crashes() { assert_equals 1 1 ; exit 3 ; }
function ${PROBE_PREFIX}_that_runs_after_it() { assert_equals 1 1 ; }")"

  assert_contains "$OUTPUT" "exited with code 3" "the crash is reported"
  assert_contains "$OUTPUT" "that runs after it" "and the test case behind it still ran"
}

function test_a_test_case_that_is_skipped_is_counted_apart_from_the_ones_that_passed() {
  # A skip is a statement that nothing was verified, so counting it as a pass
  # would be the same lie as a test case that asserted nothing
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_is_skipped() { skip_test \"nothing to run here\" ; }")"

  assert_contains "$OUTPUT" "skip" "the test case is reported as skipped"
  assert_contains "$OUTPUT" "nothing to run here" "with the reason"
  assert_contains "$OUTPUT" "1 skipped" "and counted apart"
}

function test_a_skip_cannot_hide_a_failure_that_happened_beside_it() {
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_fails_then_skips() { assert_equals 1 2 \"this failed\" ; skip_test \"and then skipped\" ; }")"

  assert_contains "$OUTPUT" "this failed" "the failure is still reported"
  assert_contains "$OUTPUT" "1 test cases failed" "and the run is red"
}

function test_the_runner_refuses_to_run_when_two_test_cases_share_a_name() {
  # Every case file is sourced into one shell, so the second definition would
  # silently replace the first : both entries pass, the run stays green, and one
  # of the two test cases has stopped existing
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_a_name_used_twice() { assert_equals 1 1 ; }
function ${PROBE_PREFIX}_a_name_used_twice() { assert_equals 1 1 ; }")"

  assert_contains "$OUTPUT" "declared more than once" "the runner says what is wrong"
  assert_contains "$OUTPUT" "test_a_name_used_twice" "and names the offender"
}

function test_the_runner_refuses_to_run_when_a_test_case_is_defined_but_not_discovered() {
  # Discovery reads the file as text, execution runs what bash defined. When the
  # two disagree a test case exists and never runs, which is the failure that
  # costs the most because the suite stays green while covering less than it says
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_is_visible() { assert_equals 1 1 ; }
if true; then
  eval \"function ${PROBE_PREFIX}_that_is_hidden() { assert_equals 1 1 ; }\"
fi")"

  assert_contains "$OUTPUT" "were not found by the runner" "the runner says what is wrong"
  assert_contains "$OUTPUT" "test_that_is_hidden" "and names the one that would never run"
}

function test_a_case_file_that_stops_the_run_while_it_is_read_is_reported() {
  # An "exit" at the top level of a case file ends the runner right there, with
  # that file's exit code and nothing printed : it looks exactly like a
  # successful run that happened to be quiet
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_never_runs() { assert_equals 1 1 ; }
exit 0")"

  assert_contains "$OUTPUT" "stopped the run while it was being sourced" "the silence is reported"
  assert_contains "$OUTPUT" "50_probe.sh" "and the file that did it is named"
}

function test_each_test_case_runs_in_its_own_shell() {
  # A variable, a working directory or a PATH changed by one test case must not
  # reach the next, or the suite's result depends on the order it ran in
  # Filtered to the probe's own two test cases, so the count below is about them
  # rather than about the unit tests the probe suite also carries
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_leaks_a_variable() { LEAKED=\"from the first\" ; cd /tmp ; assert_equals 1 1 ; }
function ${PROBE_PREFIX}_that_looks_for_the_leak() { assert_empty \"\${LEAKED:-}\" \"nothing leaked\" ; assert_equals \"\$REPO_ROOT\" \"\$PWD\" \"and the directory is the repository again\" ; }" \
    --filter "leak")"

  assert_contains "$OUTPUT" "2 test cases passed" "neither the variable nor the directory leaked"
}

function test_the_filter_selects_by_the_name_of_a_test_case() {
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_is_wanted() { assert_equals 1 1 ; }
function ${PROBE_PREFIX}_that_is_not() { assert_equals 1 1 ; }" \
    --filter "that_is_wanted")"

  assert_contains "$OUTPUT" "that is wanted" "the test case that matched ran"
  assert_not_contains "$OUTPUT" "that is not" "and the one that did not was left out"
  assert_contains "$OUTPUT" "1 test cases passed" "one test case in all"
}

function test_a_filter_that_matches_nothing_is_reported_rather_than_passing_quietly() {
  # A filter with a typo in it would otherwise run nothing and exit 0, which in
  # a CI job reads as a suite that passed
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_exists() { assert_equals 1 1 ; }" \
    --filter "no_such_test_case")"

  assert_contains "$OUTPUT" "No test case matched" "the runner says nothing matched"
}

function test_the_listing_names_every_test_case_without_running_any_of_them() {
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_that_would_fail_if_it_ran() { assert_equals 1 2 ; }" \
    --list)"

  assert_contains "$OUTPUT" "that would fail if it ran" "the test case is listed"
  assert_not_contains "$OUTPUT" "expected: [1]" "and it was not run"
}

function test_the_unit_tests_are_listed_and_run_beside_the_shell_test_cases() {
  # The unit tests live in their own binary, and the whole point of the runner
  # driving them is that a report of the run covers both
  local -r OUTPUT="$(run_a_probe_suite \
    "function ${PROBE_PREFIX}_a_shell_test_case() { assert_equals 1 1 ; }" \
    --list)"

  assert_contains "$OUTPUT" "a shell test case" "the shell test case is listed"
  assert_contains "$OUTPUT" "parse ulong reads a plain decimal number" "and so is a unit test"
}

function test_a_unit_test_that_crashes_is_reported_rather_than_ending_the_run() {
  # The code under test is C reading on-disk structures, so this is the failure
  # mode that matters most : each unit test runs in its own process precisely so
  # that a segmentation fault is one red line rather than a dead suite
  local -r PROBE_ROOT="$CASE_DIRECTORY/crashing_unit_test"

  rm -rf "$PROBE_ROOT"
  mkdir -p "$PROBE_ROOT/tests/cases"
  ln -s "$REPO_ROOT/src" "$PROBE_ROOT/src"
  cp "$TESTS_DIRECTORY/run_tests.sh" "$PROBE_ROOT/tests/"
  cp -r "$TESTS_DIRECTORY/lib" "$TESTS_DIRECTORY/unit" "$PROBE_ROOT/tests/"
  printf 'function %s_a_shell_test_case() { assert_equals 1 1 ; }\n' "$PROBE_PREFIX" \
    > "$PROBE_ROOT/tests/cases/50_probe.sh"

  # A unit test that dereferences a null pointer, added to the probe's own copy
  cat > "$PROBE_ROOT/tests/unit/99_crashing.c" << 'EOF'
#include "unit_tests.h"
UNIT_TEST(test_a_unit_test_that_dereferences_nothing) {
  volatile int *nowhere = (int *) 0;
  ASSERT_TRUE(1, "reached");
  *nowhere = 1;
  ASSERT_TRUE(1, "never reached");
}
EOF

  local -r OUTPUT="$(bash "$PROBE_ROOT/tests/run_tests.sh" --no-color 2>&1)"

  assert_contains "$OUTPUT" "a unit test that dereferences nothing" "the crashing test is named"
  assert_contains "$OUTPUT" "ended with exit code" "the way it ended is reported"
  assert_contains "$OUTPUT" "a shell test case" "and the rest of the suite still ran"
}

function test_the_junit_report_is_well_formed_and_counts_what_ran() {
  # Its consumer is a parser : "it looked fine in the terminal" is not a check
  local -r PROBE_ROOT="$(run_a_probe_suite_in "$CASE_DIRECTORY/junit_probe" \
    "function ${PROBE_PREFIX}_that_passes() { assert_equals 1 1 ; }
function ${PROBE_PREFIX}_that_fails() { assert_equals 1 2 \"a message the report carries\" ; }
function ${PROBE_PREFIX}_that_is_skipped() { skip_test \"nothing to run here\" ; }" \
    --junit "$CASE_DIRECTORY/junit_probe/report.xml")"

  local -r REPORT="$PROBE_ROOT/report.xml"
  assert_file_exists "$REPORT" "the report was written" || return 1

  if command -v python3 > /dev/null 2>&1; then
    assert_command_succeeds "the report has to parse as XML" \
      python3 -c "import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])" "$REPORT"
  fi

  assert_contains "$(cat "$REPORT")" '<?xml version="1.0" encoding="UTF-8"?>' "it declares itself as XML"
  assert_contains "$(cat "$REPORT")" 'a message the report carries' "it carries the failure's message"
  assert_contains "$(cat "$REPORT")" '<skipped message="nothing to run here"/>' "and the skip's reason"
  assert_matches "$(cat "$REPORT")" '<testsuites name="ext4magic" tests="[0-9]+" failures="1" skipped="1"' \
    "the totals count one failure and one skip"
}

function test_every_time_the_junit_report_carries_parses_as_a_number() {
  # The publisher reads every "time" attribute as a float, and one it cannot
  # read aborts the whole report : a green run turned red by its own reporting
  local -r PROBE_ROOT="$(run_a_probe_suite_in "$CASE_DIRECTORY/junit_times" \
    "function ${PROBE_PREFIX}_that_passes() { assert_equals 1 1 ; }" \
    --junit "$CASE_DIRECTORY/junit_times/report.xml")"

  local -r REPORT="$PROBE_ROOT/report.xml"
  assert_file_exists "$REPORT" "the report was written" || return 1

  local TIME_VALUE
  local HOW_MANY=0
  while IFS= read -r TIME_VALUE; do
    HOW_MANY=$((HOW_MANY + 1))
    assert_matches "$TIME_VALUE" '^[0-9]+\.[0-9]{3}$' "every time is seconds and milliseconds"
  done < <(grep -oE 'time="[^"]*"' "$REPORT" | sed 's/time="//; s/"//')

  assert_greater_than "0" "$HOW_MANY" "the report carries some times at all"
}

function test_a_duration_the_clock_made_negative_is_reported_as_zero() {
  # The durations are wall clock differences, and a wall clock may step
  # backwards : a runner syncing its time between the two reads is enough.
  # Bash truncates integer division towards zero and gives the remainder the
  # sign of the dividend, so -992 would print as "0.-992" : each field correct
  # on its own, the string they compose not a number
  assert_equals "0.000" "$(format_duration -1)" "the shape that produces 0.-001"
  assert_equals "0.000" "$(format_duration -992)" "a value a clock sync produces"
  assert_equals "0.000" "$(format_duration -86400000)" "and a day backwards"

  assert_equals "0.000" "$(format_duration 0)" "zero is zero"
  assert_equals "0.001" "$(format_duration 1)" "one millisecond"
  assert_equals "1.234" "$(format_duration 1234)" "and a second and a bit"
}

function test_the_report_escapes_what_xml_gives_a_meaning_to() {
  # This suite puts raw filesystem bytes into its diagnostics, so a report that
  # is not escaped is a report no parser accepts
  assert_equals "&lt;tag&gt;" "$(xml_escaped "<tag>")" "the angle brackets"
  assert_equals "&amp;amp;" "$(xml_escaped "&amp;")" "an ampersand, once, not twice"
  assert_equals "&quot;quoted&quot;" "$(xml_escaped '"quoted"')" "the quotation marks"
  assert_equals "aXb" "$(xml_escaped "a$(printf '\001')Xb")" \
    "and a control character XML forbids is dropped rather than escaped"
}

function test_the_markdown_summary_carries_every_test_case_that_ran() {
  # The XML says what broke ; this says what was checked, which is the part a
  # reader of a pull request is actually after
  local -r PROBE_ROOT="$(run_a_probe_suite_in "$CASE_DIRECTORY/markdown_probe" \
    "function ${PROBE_PREFIX}_that_passes() { assert_equals 1 1 ; }
function ${PROBE_PREFIX}_that_fails() { assert_equals 1 2 \"a message the report carries\" ; }" \
    --summary "$CASE_DIRECTORY/markdown_probe/summary.md")"

  local -r SUMMARY="$PROBE_ROOT/summary.md"
  assert_file_exists "$SUMMARY" "the summary was written" || return 1

  local -r CONTENT="$(cat "$SUMMARY")"
  assert_contains "$CONTENT" "## ext4magic test suite" "it has its heading"
  assert_contains "$CONTENT" "test cases failed" "it leads with the outcome"
  assert_contains "$CONTENT" "a message the report carries" "it shows the failure in full"
  assert_contains "$CONTENT" "tests/run_tests.sh --filter test_that_fails" \
    "with the command to run that one test case again"
  assert_contains "$CONTENT" "Every test case that ran" "and it lists everything that ran"
  assert_contains "$CONTENT" "that passes" "including the ones that passed"
}

function test_the_markdown_summary_is_appended_rather_than_written_over() {
  # It is written for $GITHUB_STEP_SUMMARY, which several steps of one job add
  # to. A summary that truncated the file would take the previous steps with it
  local -r SUMMARY="$CASE_DIRECTORY/appended_summary.md"

  printf 'something written before the suite ran\n' > "$SUMMARY"
  run_a_probe_suite_in "$CASE_DIRECTORY/append_probe" \
    "function ${PROBE_PREFIX}_that_passes() { assert_equals 1 1 ; }" \
    --summary "$SUMMARY" > /dev/null

  local -r CONTENT="$(cat "$SUMMARY")"
  assert_contains "$CONTENT" "something written before the suite ran" "what was there is still there"
  assert_contains "$CONTENT" "## ext4magic test suite" "and the summary was added after it"
}

function test_both_reports_are_written_even_when_the_run_is_red() {
  # A red run is the one whose report matters most
  local -r PROBE_ROOT="$(run_a_probe_suite_in "$CASE_DIRECTORY/red_run_probe" \
    "function ${PROBE_PREFIX}_that_fails() { assert_equals 1 2 ; }" \
    --junit "$CASE_DIRECTORY/red_run_probe/report.xml" \
    --summary "$CASE_DIRECTORY/red_run_probe/summary.md")"

  assert_file_exists "$PROBE_ROOT/report.xml" "the JUnit report was written"
  assert_file_exists "$PROBE_ROOT/summary.md" "and so was the Markdown summary"
  assert_contains "$(cat "$PROBE_ROOT/output")" "1 test cases failed" "on a run that failed"
}

function test_the_runner_exits_non_zero_when_a_test_case_failed() {
  # What a CI job actually reads
  local -r PROBE_ROOT="$CASE_DIRECTORY/exit_code_probe"

  run_a_probe_suite_in "$PROBE_ROOT" \
    "function ${PROBE_PREFIX}_that_passes() { assert_equals 1 1 ; }" > /dev/null
  assert_command_succeeds "a green run exits zero" \
    bash "$PROBE_ROOT/tests/run_tests.sh" --no-color

  run_a_probe_suite_in "$PROBE_ROOT" \
    "function ${PROBE_PREFIX}_that_fails() { assert_equals 1 2 ; }" > /dev/null
  assert_command_fails "a red run does not" \
    bash "$PROBE_ROOT/tests/run_tests.sh" --no-color
}

function test_the_runner_refuses_to_run_without_the_binary_it_is_meant_to_test() {
  # A suite that ran against nothing would report every test case as skipped or
  # failing for the same reason, which buries the one thing that went wrong
  local -r PROBE_ROOT="$CASE_DIRECTORY/no_binary_probe"

  rm -rf "$PROBE_ROOT"
  mkdir -p "$PROBE_ROOT/tests/cases" "$PROBE_ROOT/src"
  cp "$TESTS_DIRECTORY/run_tests.sh" "$PROBE_ROOT/tests/"
  cp -r "$TESTS_DIRECTORY/lib" "$TESTS_DIRECTORY/unit" "$PROBE_ROOT/tests/"
  printf 'function %s_that_passes() { assert_equals 1 1 ; }\n' "$PROBE_PREFIX" \
    > "$PROBE_ROOT/tests/cases/50_probe.sh"

  local OUTPUT
  OUTPUT="$(bash "$PROBE_ROOT/tests/run_tests.sh" --no-color 2>&1)" && {
    fail "the runner should refuse to run with no binary to test"
    return 1
  }

  assert_contains "$OUTPUT" "ext4magic was not found" "it says what is missing"
  assert_contains "$OUTPUT" "./configure && make" "and how to produce it"
}
