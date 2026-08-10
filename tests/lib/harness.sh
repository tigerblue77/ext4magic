#!/bin/bash

# The environment a test case runs in, and the helpers that talk to ext4magic
# itself.

# Prepare the environment every test case starts from. A test case only has to
# set up what it is about
function setup_test_context() {
  # ext4magic reads the locale for nothing a test asserts on, but e2fsprogs and
  # the C library format numbers and dates through it, so it is pinned : a
  # runner whose locale uses a comma for the decimal separator would otherwise
  # change what the assertions below compare against
  export LC_ALL=C
  export LANG=C

  # Every test case gets its own directory to write into, under the run's
  # temporary directory, so that two of them cannot collide on a file name and
  # nothing is written into the repository
  CASE_DIRECTORY="$TEST_TEMPORARY_DIRECTORY/case_$$_${RANDOM}"
  mkdir -p "$CASE_DIRECTORY"
  export CASE_DIRECTORY

  # Set by run_ext4magic, and read by the assertions that follow it
  CAPTURED_OUTPUT=""
  CAPTURED_STDOUT=""
  CAPTURED_STDERR=""
  CAPTURED_EXIT_CODE=0
}

# The binary under test. $EXT4MAGIC_BINARY lets a CI point the suite at an
# installed copy, or at one built out of tree ; by default it is the one "make"
# leaves in src/
function ext4magic_binary() {
  printf '%s' "${EXT4MAGIC_BINARY:-$REPO_ROOT/src/ext4magic}"
}

# The unit test binary, built by the runner before anything runs
function unit_test_binary() {
  printf '%s' "${UNIT_TEST_BINARY:-$TEST_TEMPORARY_DIRECTORY/unit_tests}"
}

# Run ext4magic with the given arguments.
#
# The two streams are captured apart, because this program uses them for one
# conversation : a refusal is explained on stderr while the banner around it
# goes to stdout, so a test that only looked at one of the two would be
# asserting on half a sentence. $CAPTURED_OUTPUT is stdout followed by stderr,
# which is what almost every assertion here wants ; the two are also available
# on their own for the test cases whose subject is which stream a message went
# to.
#
# The streams are not interleaved into one file, deliberately : that would need
# either a pseudo terminal or a tee per stream, and the second reaps
# asynchronously, so the capture would sometimes be read before it was
# complete. A suite that is flaky about what it captured is worse than one that
# reports the two streams in a fixed order.
#
# Sets $CAPTURED_STDOUT, $CAPTURED_STDERR, $CAPTURED_OUTPUT and
# $CAPTURED_EXIT_CODE. The exit code is also returned, so that
# "run_ext4magic ... || true" reads naturally
#
# Usage : run_ext4magic -S "$IMAGE"
function run_ext4magic() {
  local -r STDOUT_FILE="$CASE_DIRECTORY/ext4magic.out"
  local -r STDERR_FILE="$CASE_DIRECTORY/ext4magic.err"

  CAPTURED_EXIT_CODE=0
  "$(ext4magic_binary)" "$@" > "$STDOUT_FILE" 2> "$STDERR_FILE" || CAPTURED_EXIT_CODE=$?

  CAPTURED_STDOUT="$(cat "$STDOUT_FILE" 2> /dev/null)"
  CAPTURED_STDERR="$(cat "$STDERR_FILE" 2> /dev/null)"
  CAPTURED_OUTPUT="$CAPTURED_STDOUT"$'\n'"$CAPTURED_STDERR"

  return "$CAPTURED_EXIT_CODE"
}

# Run ext4magic under a time limit.
#
# Every test case that hands ext4magic a filesystem goes through here or through
# run_ext4magic ; this one is for the cases whose input is deliberately damaged,
# where the failure being guarded against is the program not coming back at all.
# Without it a scan that loops forever would be reported as a CI job that timed
# out, with no indication of which test case was running
#
# Usage : run_ext4magic_with_timeout 30 -m -d "$TARGET" "$IMAGE"
function run_ext4magic_with_timeout() {
  local -r SECONDS_ALLOWED="$1"
  shift

  local -r STDOUT_FILE="$CASE_DIRECTORY/ext4magic.out"
  local -r STDERR_FILE="$CASE_DIRECTORY/ext4magic.err"

  CAPTURED_EXIT_CODE=0
  timeout --signal=KILL "$SECONDS_ALLOWED" "$(ext4magic_binary)" "$@" \
    > "$STDOUT_FILE" 2> "$STDERR_FILE" || CAPTURED_EXIT_CODE=$?

  CAPTURED_STDOUT="$(cat "$STDOUT_FILE" 2> /dev/null)"
  CAPTURED_STDERR="$(cat "$STDERR_FILE" 2> /dev/null)"
  CAPTURED_OUTPUT="$CAPTURED_STDOUT$CAPTURED_STDERR"

  return "$CAPTURED_EXIT_CODE"
}

# "timeout --signal=KILL" reports a killed command as 137. Named, because a test
# case asserting on it reads as a sentence rather than as a number
readonly EXIT_CODE_OF_A_RUN_THAT_WAS_KILLED=137

# ext4magic's own two exit codes, from its EXIT_SUCCESS / EXIT_FAILURE returns
readonly EXT4MAGIC_EXIT_SUCCESS=0
readonly EXT4MAGIC_EXIT_FAILURE=1

# The value of one field of the -S superblock dump, which prints in the same
# "Name:   value" layout dumpe2fs uses
# Usage : superblock_field "$CAPTURED_OUTPUT" "Block size"
function superblock_field() {
  local -r OUTPUT="$1"
  local -r FIELD="$2"

  printf '%s\n' "$OUTPUT" |
    sed -n "s/^${FIELD}:[[:space:]]*//p" |
    head -1 |
    sed 's/[[:space:]]*$//'
}

# Every file ext4magic wrote under a recovery directory, as paths relative to
# it, sorted so that two runs compare
# Usage : recovered_files "$TARGET_DIRECTORY"
function recovered_files() {
  local -r TARGET_DIRECTORY="$1"

  [ -d "$TARGET_DIRECTORY" ] || return 0
  (cd "$TARGET_DIRECTORY" && find . -type f | sed 's|^\./||' | sort)
}

# The first file under a recovery directory whose content is exactly that of a
# given original. This is how a recovery is checked when ext4magic chooses the
# name itself : the magic scan names what it carves after the type it guessed,
# so the file is identified by what is inside it
# Usage : PATH=$(recovered_file_matching "$TARGET_DIRECTORY" "$ORIGINAL_FILE")
function recovered_file_matching() {
  local -r TARGET_DIRECTORY="$1"
  local -r ORIGINAL_FILE="$2"

  [ -d "$TARGET_DIRECTORY" ] || return 0

  local CANDIDATE
  while IFS= read -r CANDIDATE; do
    if cmp -s "$ORIGINAL_FILE" "$CANDIDATE"; then
      printf '%s' "$CANDIDATE"
      return 0
    fi
  done < <(find "$TARGET_DIRECTORY" -type f)

  return 1
}

# A fresh, empty directory for ext4magic to recover into
# Usage : TARGET=$(new_recovery_directory)
function new_recovery_directory() {
  local -r TARGET="$CASE_DIRECTORY/recovered_${RANDOM}"

  rm -rf "$TARGET"
  mkdir -p "$TARGET"
  printf '%s' "$TARGET"
}

# Skip the current test case unless this run is root.
#
# ext4magic zeroes its whole operation mode for a caller whose uid is not zero
# (ext4magic.c, "if (getuid()) mode = 0;"), so every mode that reads a
# filesystem does nothing at all without it -- including the ones that only
# print. So this is not about the suite needing a privilege the program does
# not : below root there is no behaviour left to assert on
# Usage : require_root || return 0
function require_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  skip_test "ext4magic clears its operation mode below root, so there is nothing to observe"
  return 1
}

# Skip the current test case unless the named program is on the PATH
# Usage : require_program mke2fs || return 0
function require_program() {
  local -r PROGRAM="$1"

  if command -v "$PROGRAM" > /dev/null 2>&1; then
    return 0
  fi
  skip_test "needs $PROGRAM, which is not installed"
  return 1
}

# The version of e2fsprogs the images are made with. Some of what ext4magic
# prints back is a function of what mke2fs wrote, so a test case that depends on
# a feature only newer e2fsprogs enables reads this rather than assuming
function e2fsprogs_version() {
  mke2fs -V 2>&1 | sed -n '1s/^mke2fs \([0-9.]*\).*/\1/p'
}
