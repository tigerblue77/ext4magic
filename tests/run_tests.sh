#!/bin/bash

# Automated test suite for ext4magic.
#
# It drives the real ext4magic binary against throwaway ext2/ext3/ext4 images
# built from scratch by e2fsprogs, and it links the parts of the source that
# work without a filesystem into a unit test binary of its own. So it needs no
# disk of yours, no fixture checked into the repository and no network :
# bash, coreutils, gcc and e2fsprogs are enough.
#
#   ./tests/run_tests.sh                 # run everything
#   ./tests/run_tests.sh --list          # list the test cases without running them
#   ./tests/run_tests.sh -f recovery     # run the test cases whose name matches
#   ./tests/run_tests.sh --tap           # emit TAP output for a CI parser
#   ./tests/run_tests.sh --junit FILE    # write a JUnit XML report
#   ./tests/run_tests.sh --summary FILE  # write a Markdown report
#
# It exits 0 when every test case passed, 1 otherwise.
#
# The test cases that need a real journal have to mount a loop device, which
# needs root : they skip where they cannot run, and the suite says so rather
# than passing quietly. Run it as root to cover them.

TESTS_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIRECTORY/.." && pwd)"
readonly TESTS_DIRECTORY REPO_ROOT
export TESTS_DIRECTORY REPO_ROOT

FILTER=""
LIST_ONLY=false
TAP_OUTPUT=false
USE_COLOR=true
JUNIT_REPORT_FILE=""
MARKDOWN_SUMMARY_FILE=""

function print_usage() {
  cat << 'EOF'
Usage: tests/run_tests.sh [option ...]

  -f, --filter PATTERN  only run the test cases whose name matches PATTERN
  -l, --list            list the test cases without running them
      --tap             emit TAP version 13 output
      --junit FILE      write a JUnit XML report, for a CI that publishes one
      --summary FILE    append a Markdown report, for $GITHUB_STEP_SUMMARY
      --no-color        disable colored output
  -h, --help            show this help

Environment:
  EXT4MAGIC_BINARY      the binary to test (default: src/ext4magic)
EOF
}

# Stop on an option given without the value it takes, instead of letting the
# loop below spin forever : "shift 2" with a single argument left shifts nothing
# and returns non-zero, so the loop would never advance
# Usage : require_option_value "$1" "$#"
function require_option_value() {
  if [ "$2" -lt 2 ]; then
    printf 'Option "%s" requires a value\n\n' "$1" >&2
    print_usage >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -f | --filter) require_option_value "$1" "$#"; FILTER="$2"; shift 2 ;;
    -l | --list) LIST_ONLY=true; shift ;;
    --tap) TAP_OUTPUT=true; USE_COLOR=false; shift ;;
    --junit) require_option_value "$1" "$#"; JUNIT_REPORT_FILE="$2"; shift 2 ;;
    --summary) require_option_value "$1" "$#"; MARKDOWN_SUMMARY_FILE="$2"; shift 2 ;;
    --no-color) USE_COLOR=false; shift ;;
    -h | --help) print_usage; exit 0 ;;
    *) printf 'Unknown option "%s"\n\n' "$1" >&2; print_usage >&2; exit 2 ;;
  esac
done

if [ ! -t 1 ]; then
  USE_COLOR=false
fi

if $USE_COLOR; then
  readonly COLOR_RESET=$'\e[0m'
  readonly COLOR_BOLD=$'\e[1m'
  readonly COLOR_DIM=$'\e[2m'
  readonly COLOR_GREEN=$'\e[32m'
  readonly COLOR_RED=$'\e[31m'
  readonly COLOR_YELLOW=$'\e[33m'
else
  readonly COLOR_RESET="" COLOR_BOLD="" COLOR_DIM="" COLOR_GREEN="" COLOR_RED="" COLOR_YELLOW=""
fi

source "$TESTS_DIRECTORY/lib/assertions.sh"
source "$TESTS_DIRECTORY/lib/images.sh"
source "$TESTS_DIRECTORY/lib/harness.sh"
source "$TESTS_DIRECTORY/lib/reports.sh"

# "test_the_journal_is_read" -> "the journal is read"
function humanize_test_case_name() {
  local -r NAME="${1#test_}"
  printf '%s' "${NAME//_/ }"
}

# tests/cases/30_command_line.sh -> "command line"
# tests/unit/20_ring_buffer.c    -> "ring buffer"
function humanize_test_file_name() {
  local NAME
  NAME="$(basename "$1")"
  NAME="${NAME%.*}"
  NAME="${NAME#*_}"
  printf '%s' "${NAME//_/ }"
}

# Collect the test case names of a shell case file, in declaration order
# (declare -F would sort them alphabetically, which would scramble the story
# each file tells). Every form bash accepts for a top-level definition is
# matched : with or without the "function" keyword, indented, and with spaces
# around the parens
function test_case_names_of_file() {
  grep -oE '^[[:space:]]*(function[[:space:]]+)?test_[A-Za-z0-9_]+[[:space:]]*\(\)' "$1" |
    sed -E 's/^[[:space:]]*//; s/^function[[:space:]]+//; s/[[:space:]]*\(\)$//'
}


# --------------------------------------------------------------------------
# What is being tested has to exist before anything is discovered
# --------------------------------------------------------------------------

if [ ! -x "$(ext4magic_binary)" ]; then
  printf 'ext4magic was not found at "%s".\n' "$(ext4magic_binary)" >&2
  printf 'Build it first :\n\n  ./configure && make\n\n' >&2
  printf 'or point the suite at another copy with EXT4MAGIC_BINARY=/path/to/ext4magic.\n' >&2
  exit 1
fi

for REQUIRED_PROGRAM in mke2fs debugfs; do
  if ! command -v "$REQUIRED_PROGRAM" > /dev/null 2>&1; then
    printf 'This suite builds its own filesystems and needs "%s" (e2fsprogs) on the PATH.\n' \
      "$REQUIRED_PROGRAM" >&2
    exit 1
  fi
done

TEST_TEMPORARY_DIRECTORY="$(mktemp -d)"
readonly TEST_TEMPORARY_DIRECTORY
export TEST_TEMPORARY_DIRECTORY
# Unmount anything a test case left behind before the directory holding it goes,
# otherwise the removal fails and the mount survives the run
trap 'for LEFTOVER in "$TEST_TEMPORARY_DIRECTORY"/images/*.mountpoint; do
        [ -d "$LEFTOVER" ] && umount "$LEFTOVER" 2>/dev/null
      done
      rm -rf "$TEST_TEMPORARY_DIRECTORY"' EXIT

# The unit tests link parts of src/ and run in their own binary. It is built
# here rather than by "make", so that the suite is a single command whatever
# state the tree is in
UNIT_TEST_BINARY="$TEST_TEMPORARY_DIRECTORY/unit_tests"
export UNIT_TEST_BINARY
UNIT_TEST_BUILD_LOG="$TEST_TEMPORARY_DIRECTORY/unit_tests_build.log"
if ! bash "$TESTS_DIRECTORY/unit/build.sh" "$UNIT_TEST_BINARY" > "$UNIT_TEST_BUILD_LOG" 2>&1; then
  printf 'The unit tests did not build, so the suite cannot say what they would have found :\n\n' >&2
  cat "$UNIT_TEST_BUILD_LOG" >&2
  exit 1
fi


# --------------------------------------------------------------------------
# Discovery
# --------------------------------------------------------------------------

declare -a SHELL_CASE_FILES=()
while IFS= read -r TEST_FILE; do
  SHELL_CASE_FILES+=("$TEST_FILE")
done < <(find "$TESTS_DIRECTORY/cases" -name '*.sh' -type f 2> /dev/null | sort)

if [ "${#SHELL_CASE_FILES[@]}" -eq 0 ]; then
  printf 'No test case file found in %s\n' "$TESTS_DIRECTORY/cases" >&2
  exit 1
fi

# The runner and the libraries have helpers of their own whose name starts with
# "test_" ; only the functions the case files add count as test cases
TEST_CASE_FUNCTIONS_BEFORE_SOURCING="$(declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p')"
readonly TEST_CASE_FUNCTIONS_BEFORE_SOURCING

# A case file is sourced into this shell, so an "exit" reached while it is read
# - a stray one, or a guard clause written at the top level by mistake - ends
# the runner right here, with that file's own exit code and nothing printed. It
# would look exactly like a successful run that happened to be quiet. The trap
# is what turns that silence into a failure
SOURCING_TEST_FILE=""
function report_interrupted_sourcing() {
  [ -n "$SOURCING_TEST_FILE" ] || return 0
  printf '%s stopped the run while it was being sourced, so no test case ran.\n' \
    "${SOURCING_TEST_FILE#"$REPO_ROOT"/}" >&2
  printf 'A case file must only declare functions and constants at its top level.\n' >&2
  exit 1
}
INTERRUPTED_SOURCING_TRAP='report_interrupted_sourcing'

for TEST_FILE in "${SHELL_CASE_FILES[@]}"; do
  SOURCING_TEST_FILE="$TEST_FILE"
  trap "$INTERRUPTED_SOURCING_TRAP" EXIT
  source "$TEST_FILE"
done
SOURCING_TEST_FILE=""
trap 'for LEFTOVER in "$TEST_TEMPORARY_DIRECTORY"/images/*.mountpoint; do
        [ -d "$LEFTOVER" ] && umount "$LEFTOVER" 2>/dev/null
      done
      rm -rf "$TEST_TEMPORARY_DIRECTORY"' EXIT

# The ordered list of every test case, as "kind<tab>file<tab>name" triples.
# The unit tests come first : they are the foundations the rest stands on, and
# they are the fastest to report
declare -a ALL_TEST_CASES=()
declare -a DISCOVERED_TEST_CASE_NAMES=()

while IFS=$'\t' read -r UNIT_FILE UNIT_NAME; do
  [ -n "$UNIT_NAME" ] || continue
  ALL_TEST_CASES+=("unit"$'\t'"$UNIT_FILE"$'\t'"$UNIT_NAME")
  DISCOVERED_TEST_CASE_NAMES+=("$UNIT_NAME")
done < <("$UNIT_TEST_BINARY" --list)

for TEST_FILE in "${SHELL_CASE_FILES[@]}"; do
  while IFS= read -r TEST_CASE_NAME; do
    [ -n "$TEST_CASE_NAME" ] || continue
    ALL_TEST_CASES+=("shell"$'\t'"$TEST_FILE"$'\t'"$TEST_CASE_NAME")
    DISCOVERED_TEST_CASE_NAMES+=("$TEST_CASE_NAME")
  done < <(test_case_names_of_file "$TEST_FILE")
done

# A test case name declared twice does not collide : every shell case file is
# sourced into the same shell, so the second definition silently replaces the
# first, the name discovered in the first file then runs the second file's body,
# both entries pass, the run stays green, and one of the two test cases has
# simply stopped existing. The unit binary refuses two tests under one name for
# the same reason ; this check spans both, so that a shell case and a unit test
# cannot share a name either and be told apart in the report by nothing
declare -a DUPLICATED_TEST_CASES=()
while IFS= read -r DUPLICATED_TEST_CASE; do
  [ -n "$DUPLICATED_TEST_CASE" ] || continue
  DUPLICATED_TEST_CASES+=("$DUPLICATED_TEST_CASE")
done < <(printf '%s\n' "${DISCOVERED_TEST_CASE_NAMES[@]}" | sort | uniq -d)

if [ "${#DUPLICATED_TEST_CASES[@]}" -ne 0 ]; then
  printf 'These test case names are declared more than once, so only one definition of each would run :\n' >&2
  printf '  %s\n' "${DUPLICATED_TEST_CASES[@]}" >&2
  printf 'Test case names must be unique across the whole suite.\n' >&2
  exit 1
fi

# Discovery reads the shell case files as text, execution runs what bash
# actually defined. When the two disagree, a test case exists and never runs -
# the failure mode that costs the most, because the suite stays green while
# covering less than it says. Comparing the two lists is what keeps them honest
declare -a UNDISCOVERED_TEST_CASES=()
while IFS= read -r DEFINED_TEST_CASE; do
  [ -n "$DEFINED_TEST_CASE" ] || continue
  FOUND=false
  for TEST_CASE_NAME in "${DISCOVERED_TEST_CASE_NAMES[@]}"; do
    if [ "$TEST_CASE_NAME" == "$DEFINED_TEST_CASE" ]; then
      FOUND=true
      break
    fi
  done
  $FOUND || UNDISCOVERED_TEST_CASES+=("$DEFINED_TEST_CASE")
done < <(declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p' |
  grep -Fxv -f <(printf '%s\n' "$TEST_CASE_FUNCTIONS_BEFORE_SOURCING") || true)

if [ "${#UNDISCOVERED_TEST_CASES[@]}" -ne 0 ]; then
  printf 'These test cases are defined but were not found by the runner, so they would never run :\n' >&2
  printf '  %s\n' "${UNDISCOVERED_TEST_CASES[@]}" >&2
  printf 'Declare them at the top level of their file, as "function test_name() {".\n' >&2
  exit 1
fi

# Apply the filter
declare -a SELECTED_TEST_CASES=()
for TEST_CASE in "${ALL_TEST_CASES[@]}"; do
  IFS=$'\t' read -r TEST_KIND TEST_FILE TEST_CASE_NAME <<< "$TEST_CASE"
  if [ -n "$FILTER" ] && [[ ! "$TEST_CASE_NAME" =~ $FILTER ]] && [[ ! "$TEST_FILE" =~ $FILTER ]]; then
    continue
  fi
  SELECTED_TEST_CASES+=("$TEST_CASE")
done

readonly TOTAL_TEST_CASES="${#SELECTED_TEST_CASES[@]}"

if [ "$TOTAL_TEST_CASES" -eq 0 ]; then
  printf 'No test case matched "%s"\n' "$FILTER" >&2
  exit 1
fi

if $LIST_ONLY; then
  CURRENT_TEST_FILE=""
  for TEST_CASE in "${SELECTED_TEST_CASES[@]}"; do
    IFS=$'\t' read -r TEST_KIND TEST_FILE TEST_CASE_NAME <<< "$TEST_CASE"
    if [ "$TEST_FILE" != "$CURRENT_TEST_FILE" ]; then
      CURRENT_TEST_FILE="$TEST_FILE"
      printf '\n%s\n' "$(humanize_test_file_name "$TEST_FILE")"
    fi
    printf '  %s\n' "$(humanize_test_case_name "$TEST_CASE_NAME")"
  done
  printf '\n%d test cases\n' "$TOTAL_TEST_CASES"
  exit 0
fi


# --------------------------------------------------------------------------
# Execution
# --------------------------------------------------------------------------

TEST_ASSERTIONS_FILE="$TEST_TEMPORARY_DIRECTORY/assertions"
TEST_DIAGNOSTICS_FILE="$TEST_TEMPORARY_DIRECTORY/diagnostics"
TEST_SKIPPED_FILE="$TEST_TEMPORARY_DIRECTORY/skipped"
readonly TEST_ASSERTIONS_FILE TEST_DIAGNOSTICS_FILE TEST_SKIPPED_FILE
export TEST_ASSERTIONS_FILE TEST_DIAGNOSTICS_FILE TEST_SKIPPED_FILE

if $TAP_OUTPUT; then
  printf 'TAP version 13\n'
  printf '1..%d\n' "$TOTAL_TEST_CASES"
else
  printf '%sext4magic - automated test suite%s\n' "$COLOR_BOLD" "$COLOR_RESET"
  printf '%s%s%s\n' "$COLOR_DIM" "$(bash --version | head -1)" "$COLOR_RESET"
  printf '%s%s, e2fsprogs %s%s\n' "$COLOR_DIM" "$(ext4magic_binary)" "$(e2fsprogs_version)" "$COLOR_RESET"
  if ! loop_mounting_is_available; then
    printf '%sno loop mounting available : the test cases needing a real journal will skip%s\n' \
      "$COLOR_YELLOW" "$COLOR_RESET"
  fi
  printf '\n'
fi

PASSED_TEST_CASES=0
FAILED_TEST_CASES=0
SKIPPED_TEST_CASES=0
TOTAL_ASSERTIONS=0
TEST_CASE_INDEX=0
CURRENT_TEST_FILE=""
declare -a FAILED_TEST_CASE_NAMES=()

for TEST_CASE in "${SELECTED_TEST_CASES[@]}"; do
  IFS=$'\t' read -r TEST_KIND TEST_FILE TEST_CASE_NAME <<< "$TEST_CASE"
  ((TEST_CASE_INDEX++))

  if [ "$TEST_FILE" != "$CURRENT_TEST_FILE" ]; then
    CURRENT_TEST_FILE="$TEST_FILE"
    if ! $TAP_OUTPUT; then
      printf '%s%s%s\n' "$COLOR_BOLD" "$(humanize_test_file_name "$TEST_FILE")" "$COLOR_RESET"
    fi
  fi

  : > "$TEST_ASSERTIONS_FILE"
  : > "$TEST_DIAGNOSTICS_FILE"
  rm -f "$TEST_SKIPPED_FILE"

  TEST_CASE_EXIT_CODE=0
  TEST_CASE_STARTED_AT=$(current_time_in_milliseconds)

  if [ "$TEST_KIND" == "unit" ]; then
    # Each unit test runs in its own process. The code under test is C parsing
    # on-disk structures, so a test that segfaults has to be reported as a
    # failing test case rather than take the suite down with it
    UNIT_OUTPUT="$("$UNIT_TEST_BINARY" --run "$TEST_CASE_NAME" 2>&1)" || TEST_CASE_EXIT_CODE=$?
    # The binary's last line is "# assertions <n>", and the rest is diagnostics
    TEST_CASE_ASSERTIONS="$(printf '%s\n' "$UNIT_OUTPUT" | sed -n 's/^# assertions \([0-9]*\)$/\1/p' | tail -1)"
    TEST_CASE_ASSERTIONS="${TEST_CASE_ASSERTIONS:-0}"
    UNIT_DIAGNOSTICS="$(printf '%s\n' "$UNIT_OUTPUT" | sed '/^# assertions [0-9]*$/d')"
    case "$TEST_CASE_EXIT_CODE" in
      0) : ;;
      77) printf '%s\n' "$UNIT_DIAGNOSTICS" > "$TEST_SKIPPED_FILE"; TEST_CASE_EXIT_CODE=0 ;;
      1) printf '%s\n' "$UNIT_DIAGNOSTICS" > "$TEST_DIAGNOSTICS_FILE" ;;
      *)
        # A crash, a timeout, or the binary refusing the name. The exit code is
        # the only thing that says which, so it is reported with what was printed
        {
          printf 'the unit test ended with exit code %d (%s)\n' "$TEST_CASE_EXIT_CODE" \
            "$(kill -l "$((TEST_CASE_EXIT_CODE - 128))" 2> /dev/null || printf 'not a signal')"
          printf '%s\n' "$UNIT_DIAGNOSTICS"
        } > "$TEST_DIAGNOSTICS_FILE"
        ;;
    esac
    TEST_CASE_EXIT_CODE=0
  else
    # Each shell test case runs in its own subshell so that the variables,
    # functions, PATH and working directory it changes cannot leak into the next
    (
      setup_test_context
      cd "$REPO_ROOT" || exit 1
      "$TEST_CASE_NAME"
    ) > "$TEST_TEMPORARY_DIRECTORY/output" 2>&1 || TEST_CASE_EXIT_CODE=$?
    TEST_CASE_ASSERTIONS=$(wc -c < "$TEST_ASSERTIONS_FILE" | tr -d ' ')
  fi

  # Clamped here as well as in format_duration : this value is also summed per
  # suite and for the whole run, and one negative member drags those totals
  # below what the test cases actually took
  TEST_CASE_DURATION=$(($(current_time_in_milliseconds) - TEST_CASE_STARTED_AT))
  if [ "$TEST_CASE_DURATION" -lt 0 ]; then
    TEST_CASE_DURATION=0
  fi

  TOTAL_ASSERTIONS=$((TOTAL_ASSERTIONS + TEST_CASE_ASSERTIONS))
  HUMAN_READABLE_NAME="$(humanize_test_case_name "$TEST_CASE_NAME")"
  TEST_SUITE_NAME="$(humanize_test_file_name "$TEST_FILE")"
  TEST_FILE_PATH="${TEST_FILE#"$REPO_ROOT"/}"

  # skip_test() only records a reason, it does not return from the test case.
  # Anything that failed before or after that call still counts : a skip is a
  # statement that nothing was verified, so it cannot also hide a failure
  if [ -f "$TEST_SKIPPED_FILE" ] && [ ! -s "$TEST_DIAGNOSTICS_FILE" ] && [ "$TEST_CASE_EXIT_CODE" -eq 0 ]; then
    ((SKIPPED_TEST_CASES++))
    SKIP_REASON="$(cat "$TEST_SKIPPED_FILE")"
    record_test_result "$TEST_SUITE_NAME" "$TEST_FILE_PATH" "$TEST_CASE_NAME" "$HUMAN_READABLE_NAME" \
      "skipped" "$TEST_CASE_DURATION" "$TEST_CASE_ASSERTIONS" "$SKIP_REASON"
    if $TAP_OUTPUT; then
      printf 'ok %d - %s # SKIP %s\n' "$TEST_CASE_INDEX" "$HUMAN_READABLE_NAME" "$SKIP_REASON"
    else
      printf '  %sskip%s %s %s(%s)%s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$HUMAN_READABLE_NAME" "$COLOR_DIM" "$SKIP_REASON" "$COLOR_RESET"
    fi
    continue
  fi

  # A test case that asserted nothing verified nothing. It usually means the
  # case returned early on a condition that no longer holds, and it is the one
  # failure a passing suite cannot show you, so it is reported as a failure
  # rather than counted among the green ones
  if [ ! -f "$TEST_SKIPPED_FILE" ] && [ "$TEST_CASE_ASSERTIONS" -eq 0 ] &&
    [ ! -s "$TEST_DIAGNOSTICS_FILE" ] && [ "$TEST_CASE_EXIT_CODE" -eq 0 ]; then
    printf 'the test case recorded no assertion, so it verified nothing\n' > "$TEST_DIAGNOSTICS_FILE"
  fi

  if [ -s "$TEST_DIAGNOSTICS_FILE" ] || [ "$TEST_CASE_EXIT_CODE" -ne 0 ]; then
    ((FAILED_TEST_CASES++))
    FAILED_TEST_CASE_NAMES+=("$TEST_CASE_NAME")
    # A non-zero exit code with no recorded failure means the test case itself
    # crashed, which is worth showing whatever it wrote
    TEST_CASE_DIAGNOSTICS="$(cat "$TEST_DIAGNOSTICS_FILE")"
    if [ "$TEST_CASE_EXIT_CODE" -ne 0 ] && [ ! -s "$TEST_DIAGNOSTICS_FILE" ]; then
      TEST_CASE_DIAGNOSTICS="test case exited with code $TEST_CASE_EXIT_CODE"$'\n'"$(cat "$TEST_TEMPORARY_DIRECTORY/output")"
    fi
    record_test_result "$TEST_SUITE_NAME" "$TEST_FILE_PATH" "$TEST_CASE_NAME" "$HUMAN_READABLE_NAME" \
      "failed" "$TEST_CASE_DURATION" "$TEST_CASE_ASSERTIONS" "$TEST_CASE_DIAGNOSTICS"

    if $TAP_OUTPUT; then
      printf 'not ok %d - %s\n' "$TEST_CASE_INDEX" "$HUMAN_READABLE_NAME"
      printf '%s\n' "$TEST_CASE_DIAGNOSTICS" | sed 's/^/# /'
    else
      printf '  %sfail%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$HUMAN_READABLE_NAME"
      printf '%s\n' "$TEST_CASE_DIAGNOSTICS" | sed 's/^/       /'
    fi
    continue
  fi

  ((PASSED_TEST_CASES++))
  record_test_result "$TEST_SUITE_NAME" "$TEST_FILE_PATH" "$TEST_CASE_NAME" "$HUMAN_READABLE_NAME" \
    "passed" "$TEST_CASE_DURATION" "$TEST_CASE_ASSERTIONS" ""
  if $TAP_OUTPUT; then
    printf 'ok %d - %s\n' "$TEST_CASE_INDEX" "$HUMAN_READABLE_NAME"
  else
    printf '  %sok%s   %s %s(%d assertions)%s\n' "$COLOR_GREEN" "$COLOR_RESET" "$HUMAN_READABLE_NAME" "$COLOR_DIM" "$TEST_CASE_ASSERTIONS" "$COLOR_RESET"
  fi
done

if ! $TAP_OUTPUT; then
  printf '\n'
  if [ "$FAILED_TEST_CASES" -eq 0 ]; then
    printf '%s%d test cases passed%s' "$COLOR_GREEN" "$PASSED_TEST_CASES" "$COLOR_RESET"
  else
    printf '%s%d test cases failed%s, %d passed' "$COLOR_RED" "$FAILED_TEST_CASES" "$COLOR_RESET" "$PASSED_TEST_CASES"
  fi
  if [ "$SKIPPED_TEST_CASES" -gt 0 ]; then
    printf ', %d skipped' "$SKIPPED_TEST_CASES"
  fi
  printf ' (%d assertions)\n' "$TOTAL_ASSERTIONS"

  if [ "$FAILED_TEST_CASES" -ne 0 ]; then
    printf '\nRe-run a single failing test case with:\n'
    printf '  tests/run_tests.sh --filter %s\n' "${FAILED_TEST_CASE_NAMES[0]}"
  fi
fi

# The reports are written whatever the outcome : a red run is the one whose
# report matters most
if [ -n "$JUNIT_REPORT_FILE" ]; then
  write_junit_report "$JUNIT_REPORT_FILE" ||
    printf 'Could not write the JUnit report to "%s"\n' "$JUNIT_REPORT_FILE" >&2
fi
if [ -n "$MARKDOWN_SUMMARY_FILE" ]; then
  write_markdown_summary "$MARKDOWN_SUMMARY_FILE" ||
    printf 'Could not write the Markdown summary to "%s"\n' "$MARKDOWN_SUMMARY_FILE" >&2
fi

[ "$FAILED_TEST_CASES" -eq 0 ]
