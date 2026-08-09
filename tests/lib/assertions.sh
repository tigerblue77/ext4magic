#!/bin/bash

# Assertion helpers.
#
# Each test case runs in its own subshell, so an assertion cannot simply
# increment a counter : the outcome is recorded in the two files the runner
# prepares before every test case ($TEST_ASSERTIONS_FILE and
# $TEST_DIAGNOSTICS_FILE).
#
# Assertions return 0 on success and 1 on failure but never abort the test case,
# so that a data-driven test looping over a dozen filesystem layouts reports
# every offending layout in one run instead of only the first one. Use
# "assert_... || return 1" in the cases where the rest of the test case cannot
# run once the assertion failed.

function _record_assertion() {
  printf '.' >> "$TEST_ASSERTIONS_FILE"
}

function _record_failure() {
  local -r TITLE="$1"
  shift

  {
    printf '%s\n' "$TITLE"
    local DETAIL
    for DETAIL in "$@"; do
      printf '  %s\n' "$DETAIL"
    done
  } >> "$TEST_DIAGNOSTICS_FILE"
}

# Record a passing assertion, for the test cases that run the check themselves
# Usage : if <check>; then pass; else fail "..."; fi
function pass() {
  _record_assertion
}

# Unconditionally fail the current test case
# Usage : fail "message" ["detail" ...]
function fail() {
  local -r MESSAGE="$1"
  shift

  _record_assertion
  _record_failure "$MESSAGE" "$@"
  return 1
}

# Usage : assert_equals "$EXPECTED" "$ACTUAL" ["message"]
function assert_equals() {
  local -r EXPECTED="$1"
  local -r ACTUAL="$2"
  local -r MESSAGE="${3:-values should be equal}"

  _record_assertion
  if [ "$EXPECTED" == "$ACTUAL" ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "expected: [$EXPECTED]" "actual:   [$ACTUAL]"
  return 1
}

# Usage : assert_not_equals "$UNEXPECTED" "$ACTUAL" ["message"]
function assert_not_equals() {
  local -r UNEXPECTED="$1"
  local -r ACTUAL="$2"
  local -r MESSAGE="${3:-values should differ}"

  _record_assertion
  if [ "$UNEXPECTED" != "$ACTUAL" ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "both values are: [$ACTUAL]"
  return 1
}

# Usage : assert_contains "$HAYSTACK" "$NEEDLE" ["message"]
function assert_contains() {
  local -r HAYSTACK="$1"
  local -r NEEDLE="$2"
  local -r MESSAGE="${3:-text should contain substring}"

  _record_assertion
  if [[ "$HAYSTACK" == *"$NEEDLE"* ]]; then
    return 0
  fi

  _record_failure "$MESSAGE" "substring: [$NEEDLE]" "text:      [$(_shortened "$HAYSTACK")]"
  return 1
}

# Usage : assert_not_contains "$HAYSTACK" "$NEEDLE" ["message"]
function assert_not_contains() {
  local -r HAYSTACK="$1"
  local -r NEEDLE="$2"
  local -r MESSAGE="${3:-text should not contain substring}"

  _record_assertion
  if [[ "$HAYSTACK" != *"$NEEDLE"* ]]; then
    return 0
  fi

  _record_failure "$MESSAGE" "substring: [$NEEDLE]" "text:      [$(_shortened "$HAYSTACK")]"
  return 1
}

# Usage : assert_matches "$VALUE" "$EXTENDED_REGEX" ["message"]
function assert_matches() {
  local -r VALUE="$1"
  local -r REGEX="$2"
  local -r MESSAGE="${3:-value should match regex}"

  _record_assertion
  if [[ "$VALUE" =~ $REGEX ]]; then
    return 0
  fi

  _record_failure "$MESSAGE" "regex: [$REGEX]" "value: [$(_shortened "$VALUE")]"
  return 1
}

# Usage : assert_not_matches "$VALUE" "$EXTENDED_REGEX" ["message"]
function assert_not_matches() {
  local -r VALUE="$1"
  local -r REGEX="$2"
  local -r MESSAGE="${3:-value should not match regex}"

  _record_assertion
  if [[ ! "$VALUE" =~ $REGEX ]]; then
    return 0
  fi

  _record_failure "$MESSAGE" "regex: [$REGEX]" "value: [$(_shortened "$VALUE")]"
  return 1
}

# Assert on one LINE of a multi-line output.
#
# bash's own "=~" anchors "^" and "$" to the whole string rather than to each
# line, so a pattern describing one row of a table silently never matches when
# it is written with those anchors. This is the assertion for that, and it takes
# the anchors literally
# Usage : assert_has_line "$OUTPUT" '^ *2 +d +755' ["message"]
function assert_has_line() {
  local -r OUTPUT="$1"
  local -r LINE_REGEX="$2"
  local -r MESSAGE="${3:-a line should match}"

  _record_assertion
  if printf '%s\n' "$OUTPUT" | grep -qE -- "$LINE_REGEX"; then
    return 0
  fi

  _record_failure "$MESSAGE" "no line matched: [$LINE_REGEX]" "output: [$(_shortened "$OUTPUT")]"
  return 1
}

# Usage : assert_empty "$VALUE" ["message"]
function assert_empty() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-value should be empty}"

  _record_assertion
  if [ -z "$VALUE" ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "value: [$(_shortened "$VALUE")]"
  return 1
}

# Usage : assert_not_empty "$VALUE" ["message"]
function assert_not_empty() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-value should not be empty}"

  _record_assertion
  if [ -n "$VALUE" ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "value is empty"
  return 1
}

# Usage : assert_greater_than "$MINIMUM" "$ACTUAL" ["message"]
function assert_greater_than() {
  local -r MINIMUM="$1"
  local -r ACTUAL="$2"
  local -r MESSAGE="${3:-value should be greater}"

  _record_assertion
  if [ "$ACTUAL" -gt "$MINIMUM" ] 2> /dev/null; then
    return 0
  fi

  _record_failure "$MESSAGE" "should be greater than: [$MINIMUM]" "actual:                 [$ACTUAL]"
  return 1
}

# Usage : assert_command_succeeds "message" command [argument ...]
function assert_command_succeeds() {
  local -r MESSAGE="$1"
  shift

  local ACTUAL_EXIT_CODE=0
  local OUTPUT
  OUTPUT="$("$@" 2>&1)" || ACTUAL_EXIT_CODE=$?

  _record_assertion
  if [ "$ACTUAL_EXIT_CODE" -eq 0 ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "command:   [$*]" "exit code: [$ACTUAL_EXIT_CODE]" "output:    [$(_shortened "$OUTPUT")]"
  return 1
}

# Usage : assert_command_fails "message" command [argument ...]
function assert_command_fails() {
  local -r MESSAGE="$1"
  shift

  local ACTUAL_EXIT_CODE=0
  "$@" > /dev/null 2>&1 || ACTUAL_EXIT_CODE=$?

  _record_assertion
  if [ "$ACTUAL_EXIT_CODE" -ne 0 ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "command: [$*]" "it succeeded instead"
  return 1
}

# Usage : assert_file_exists "$PATH" ["message"]
function assert_file_exists() {
  local -r FILE="$1"
  local -r MESSAGE="${2:-file should exist}"

  _record_assertion
  if [ -f "$FILE" ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "path: [$FILE]" "$(_directory_listing_of "$FILE")"
  return 1
}

# Usage : assert_file_does_not_exist "$PATH" ["message"]
function assert_file_does_not_exist() {
  local -r FILE="$1"
  local -r MESSAGE="${2:-file should not exist}"

  _record_assertion
  if [ ! -e "$FILE" ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "path: [$FILE]"
  return 1
}

# Compare two files byte for byte. The one assertion that says a recovery was
# actually a recovery : a file of the right name and the right size whose
# content is not the original one is exactly the failure mode a recovery tool
# has, and it is invisible to every other check
# Usage : assert_files_identical "$EXPECTED_FILE" "$ACTUAL_FILE" ["message"]
function assert_files_identical() {
  local -r EXPECTED_FILE="$1"
  local -r ACTUAL_FILE="$2"
  local -r MESSAGE="${3:-files should be identical}"

  _record_assertion
  if [ ! -f "$ACTUAL_FILE" ]; then
    _record_failure "$MESSAGE" "expected file: [$EXPECTED_FILE]" "actual file:   [$ACTUAL_FILE] does not exist"
    return 1
  fi
  if cmp -s "$EXPECTED_FILE" "$ACTUAL_FILE"; then
    return 0
  fi

  _record_failure "$MESSAGE" \
    "expected: [$EXPECTED_FILE] $(wc -c < "$EXPECTED_FILE" | tr -d ' ') bytes, sha256 $(_sha256_of "$EXPECTED_FILE")" \
    "actual:   [$ACTUAL_FILE] $(wc -c < "$ACTUAL_FILE" | tr -d ' ') bytes, sha256 $(_sha256_of "$ACTUAL_FILE")" \
    "first difference: $(cmp "$EXPECTED_FILE" "$ACTUAL_FILE" 2>&1 | head -1)"
  return 1
}

function _sha256_of() {
  sha256sum "$1" 2> /dev/null | cut -c1-16 || printf 'unavailable'
}

# Diagnostics are read in a terminal and in a Markdown report ; a whole
# ext4magic run pasted into either drowns the line that matters
function _shortened() {
  local -r TEXT="$1"
  local -r MAXIMUM=1200

  if [ "${#TEXT}" -le "$MAXIMUM" ]; then
    printf '%s' "$TEXT"
    return 0
  fi
  printf '%s ... (%d characters truncated)' "${TEXT:0:$MAXIMUM}" "$((${#TEXT} - MAXIMUM))"
}

# What a missing file's directory does hold, which is the question actually
# being asked when an expected recovery is not there
function _directory_listing_of() {
  local -r DIRECTORY="$(dirname "$1")"

  if [ ! -d "$DIRECTORY" ]; then
    printf 'its directory [%s] does not exist either' "$DIRECTORY"
    return 0
  fi
  printf 'its directory holds: [%s]' "$(ls -A "$DIRECTORY" 2> /dev/null | head -20 | tr '\n' ' ')"
}

# Skip the current test case, reporting why. Used for the cases that need a
# capability the environment may not provide : mounting a loop device requires
# root and a free /dev/loop, which an unprivileged machine does not have
# Usage : skip_test "reason"
function skip_test() {
  printf '%s\n' "$1" > "$TEST_SKIPPED_FILE"
}
