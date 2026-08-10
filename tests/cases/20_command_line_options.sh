#!/bin/bash

# The command line, which is the whole of ext4magic's interface.
#
# Everything here runs before a filesystem is opened, or refuses to run at all,
# so these test cases are the ones that need neither root nor an image. They are
# also the ones a user meets first : a recovery tool that misreads its options
# does the wrong thing to a filesystem someone is trying to save.

# What the usage text names as an option, which is what a reader takes to be
# supported. Read out of the binary rather than written down here, so that the
# two cannot drift apart
function options_named_in_the_usage_text() {
  run_ext4magic > /dev/null 2>&1 || true
  printf '%s\n' "$CAPTURED_OUTPUT" |
    grep -oE '\-[A-Za-z]' |
    sort -u |
    tr -d '-' |
    tr -d '\n'
}


function test_running_it_with_no_argument_at_all_prints_the_usage_and_fails() {
  run_ext4magic || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "it should refuse to run"
  assert_contains "$CAPTURED_OUTPUT" "Missing device name and options" "it should say what is missing"
  assert_contains "$CAPTURED_OUTPUT" "ext4magic -M" "and print the usage"
}

function test_the_usage_names_the_three_ways_the_program_is_called() {
  # The magic scan, the ext3 magic scan and the general form. A reader who only
  # gets this text has to be able to find all three
  run_ext4magic || true

  assert_contains "$CAPTURED_OUTPUT" "ext4magic -M [-j <journal_file>] [-d <target_dir>] <filesystem>" \
    "the whole tree magic recovery"
  assert_contains "$CAPTURED_OUTPUT" "ext4magic -m [-j <journal_file>] [-d <target_dir>] <filesystem>" \
    "the deleted files magic recovery"
  assert_contains "$CAPTURED_OUTPUT" "<filesystem>" "and every form ends with the filesystem"
}

function test_the_version_is_printed_for_a_lone_v_option() {
  run_ext4magic -V

  assert_equals "0" "$CAPTURED_EXIT_CODE" "asking for the version is not an error"
  assert_matches "$CAPTURED_OUTPUT" 'ext4magic +version : [0-9]+\.[0-9]+\.[0-9]+' "its own version"
  assert_matches "$CAPTURED_OUTPUT" 'libext2fs version : [0-9]+\.[0-9]+' "the library it was built against"
  assert_matches "$CAPTURED_OUTPUT" 'CPU is (little|big) endian' "and the byte order it is running on"
}

function test_the_version_it_reports_is_the_one_the_build_was_configured_with() {
  # The version comes from configure.ac through config.h, so a release that
  # forgot to bump one of the two reports the other's number
  local -r CONFIGURED_VERSION="$(sed -n 's/^AM_INIT_AUTOMAKE(ext4magic, \([0-9.]*\)).*/\1/p' "$REPO_ROOT/configure.ac")"

  assert_not_empty "$CONFIGURED_VERSION" "configure.ac should name a version" || return 1

  run_ext4magic -V
  assert_contains "$CAPTURED_OUTPUT" "ext4magic  version : $CONFIGURED_VERSION" \
    "the binary reports the version configure.ac sets"
}

function test_the_version_is_printed_before_anything_else_is_looked_at() {
  # "-V" exits from inside the option loop, so it answers even when the rest of
  # the command line makes no sense at all. That is what makes it usable in a
  # bug report
  run_ext4magic -V -I 0 /nonexistent/filesystem.img

  assert_equals "0" "$CAPTURED_EXIT_CODE" "it still answers"
  assert_contains "$CAPTURED_OUTPUT" "ext4magic  version :" "with the version"
  assert_not_contains "$CAPTURED_OUTPUT" "out of range" "and without complaining about the rest"
}

function test_an_unknown_option_is_refused_with_the_usage() {
  run_ext4magic -Z "$(make_image --name unknown_option)" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "an option it does not have"
  assert_contains "$CAPTURED_OUTPUT" "Usage:" "is answered with the usage"
}

function test_an_option_given_without_the_value_it_takes_is_refused() {
  # getopt reports the missing argument itself, and ext4magic turns that into
  # its usage. Every option taking a value goes through the same path
  local OPTION
  for OPTION in -I -B -t -j -f -i -d -a -b; do
    run_ext4magic "$OPTION" || true
    assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" \
      "\"$OPTION\" without its value should be refused"
  done
}

function test_only_one_mode_may_be_asked_for_at_a_time() {
  # -M -m -R -r -L -l -H all set the one operation mode, and two of them would
  # mean the second silently winning. Every pair is refused
  local -r IMAGE="$(make_image --name one_mode_only)"
  local FIRST SECOND
  for FIRST in -M -m -R -r -L -l -H; do
    for SECOND in -M -m -R -r -L -l -H; do
      [ "$FIRST" == "$SECOND" ] && continue
      run_ext4magic "$FIRST" "$SECOND" "$IMAGE" || true
      assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" \
        "\"$FIRST $SECOND\" should be refused"
    done
  done
}

function test_asking_for_one_mode_twice_is_refused_as_well() {
  # The check is on the mode bit rather than on the letter, so the same option
  # given twice is caught by the same guard
  local -r IMAGE="$(make_image --name mode_twice)"

  run_ext4magic -r -r "$IMAGE" || true
  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "-r twice"
  assert_contains "$CAPTURED_OUTPUT" "only input of one modus allowed" "with the reason"
}

function test_the_refusal_of_two_modes_names_the_modes_it_is_about() {
  local -r IMAGE="$(make_image --name two_modes_message)"

  run_ext4magic -R -l "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "only input of one modus allowed" "the reason"
  local OPTION
  for OPTION in "-M" "-m" "-R" "-r" "-L" "-l" "-H"; do
    assert_contains "$CAPTURED_OUTPUT" "$OPTION" "the message lists $OPTION among the modes"
  done
}

function test_the_modes_that_only_read_may_be_combined_with_a_mode() {
  # -S, -J and -T are reports rather than modes, and a run that wants both a
  # superblock dump and a listing has to be able to ask for both
  local -r IMAGE="$(make_image --name reports_combine)"

  run_ext4magic -S -J -T "$IMAGE" || true
  assert_not_contains "$CAPTURED_OUTPUT" "only input of one modus allowed" \
    "the three reports together are not two modes"
}

function test_an_inode_number_below_one_is_refused() {
  local -r IMAGE="$(make_image --name inode_below_one)"

  run_ext4magic -I 0 "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "inode 0 does not exist"
  assert_contains "$CAPTURED_OUTPUT" "-I: inodeNR" "the message names the option"
  assert_contains "$CAPTURED_OUTPUT" "out of range" "and says why"
}

function test_an_inode_number_that_is_not_a_number_is_refused() {
  # strtoul reads nothing out of it, which leaves zero, which the range check
  # below refuses. The message is about the range rather than about the text,
  # but the run does stop
  local -r IMAGE="$(make_image --name inode_not_a_number)"
  local VALUE
  for VALUE in abc "" " " "--" "one"; do
    run_ext4magic -I "$VALUE" "$IMAGE" || true
    assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" \
      "\"-I $VALUE\" should be refused"
  done
}

function test_a_block_number_below_one_is_refused() {
  local -r IMAGE="$(make_image --name block_below_one)"

  run_ext4magic -B 0 "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "block 0 is the superblock's own"
  assert_contains "$CAPTURED_OUTPUT" "-B: blockNR" "the message names the option"
  assert_contains "$CAPTURED_OUTPUT" "out of range" "and says why"
}

function test_a_transaction_number_below_one_is_refused() {
  local -r IMAGE="$(make_image --name transaction_below_one)"

  run_ext4magic -t 0 "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "there is no transaction 0"
  assert_contains "$CAPTURED_OUTPUT" "-t: transactionNR" "the message names the option"
  assert_contains "$CAPTURED_OUTPUT" "out of range" "and says why"
}

function test_a_journal_file_that_is_not_there_is_refused_before_anything_is_opened() {
  local -r IMAGE="$(make_image --name missing_journal_file)"

  run_ext4magic -j "$CASE_DIRECTORY/no_such_journal" -J "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "an external journal that is not there"
  assert_contains "$CAPTURED_OUTPUT" "Invalid parameter: -j" "the message names the option"
  assert_not_contains "$CAPTURED_OUTPUT" "Filesystem in use" "and the filesystem was never opened"
}

function test_an_input_list_that_is_not_there_is_refused() {
  local -r IMAGE="$(make_image --name missing_input_list)"

  run_ext4magic -i "$CASE_DIRECTORY/no_such_list" "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "an input list that is not there"
  assert_contains "$CAPTURED_OUTPUT" "Invalid parameter: -i" "the message names the option"
}

function test_an_input_list_that_is_not_a_regular_file_is_refused() {
  # A directory passes the stat, so it is the second check that has to catch it
  local -r IMAGE="$(make_image --name input_list_directory)"

  run_ext4magic -i "$CASE_DIRECTORY" "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "a directory is not an input list"
  assert_contains "$CAPTURED_OUTPUT" "can not use" "and it says so"
}

function test_an_input_list_that_is_not_a_regular_file_at_all_is_refused() {
  # The check is S_ISREG, not "it exists" : a fifo would block the read for
  # ever, and a device would be read as if it were a list of file names
  local -r IMAGE="$(make_image --name input_list_special_files)"
  local -r FIFO="$CASE_DIRECTORY/a_fifo"

  mkfifo "$FIFO" 2> /dev/null || {
    skip_test "this filesystem does not allow creating a fifo"
    return 0
  }

  run_ext4magic -i "$FIFO" "$IMAGE" || true
  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "a fifo is not an input list"
  assert_contains "$CAPTURED_OUTPUT" "can not use" "and it says so"

  if [ -c /dev/null ]; then
    run_ext4magic -i /dev/null "$IMAGE" || true
    assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "and neither is a character device"
  fi
}

function test_an_input_list_that_is_there_is_accepted_and_named_back() {
  local -r IMAGE="$(make_image --name good_input_list)"
  local -r LIST="$CASE_DIRECTORY/recover.list"

  printf '"documents/report.txt"\n' > "$LIST"

  run_ext4magic -i "$LIST" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "accept for inputfile" "the list is accepted"
  assert_contains "$CAPTURED_OUTPUT" "$LIST" "and named back, so the user sees which file was read"
}

function test_only_one_of_an_inode_number_and_a_file_name_is_taken() {
  # -I and -f both say which object to work on, and the first one given wins
  # with a warning rather than the second silently replacing it
  local -r IMAGE="$(make_image --name inode_and_filename)"

  run_ext4magic -I 2 -f /documents "$IMAGE" || true
  assert_contains "$CAPTURED_OUTPUT" "only input of one inodeNR or filename allowed" \
    "-I then -f is warned about"

  run_ext4magic -f /documents -I 2 "$IMAGE" || true
  assert_contains "$CAPTURED_OUTPUT" "only input of one inodeNR or filename allowed" \
    "and so is -f then -I"
}

function test_asking_for_the_same_file_name_twice_is_warned_about_rather_than_taken_twice() {
  local -r IMAGE="$(make_image --name filename_twice)"

  run_ext4magic -f /one -f /two "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "only input of one inodeNR or filename allowed" \
    "the second name is refused rather than replacing the first"
}

function test_a_recovery_directory_that_is_there_is_accepted_and_named_back() {
  # Below root ext4magic clears its operation mode before any of its parameters
  # are looked at, so nothing is refused and there is nothing to observe
  require_root || return 0
  local -r IMAGE="$(make_image --name good_recovery_directory)"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -r -d "$TARGET" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "accept for recoverdir" "the directory is accepted"
  assert_contains "$CAPTURED_OUTPUT" "$TARGET" "and named back"
}

function test_a_recovery_directory_that_is_not_there_yet_is_created() {
  # Below root ext4magic clears its operation mode before any of its parameters
  # are looked at, so nothing is refused and there is nothing to observe
  require_root || return 0
  # Being told to recover into a directory that does not exist is not a
  # mistake : it is the ordinary way of starting, and the alternative would be
  # making the user create it first
  local -r IMAGE="$(make_image --name created_recovery_directory)"
  local -r TARGET="$CASE_DIRECTORY/not_there_yet"

  assert_file_does_not_exist "$TARGET" "the directory does not exist to begin with" || return 1

  run_ext4magic -r -d "$TARGET" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "accept for recoverdir" "it is accepted"
  if [ -d "$TARGET" ]; then
    pass
  else
    fail "the directory should have been created" "path: [$TARGET]"
  fi
}

function test_a_recovery_directory_that_cannot_be_created_is_refused() {
  # Below root ext4magic clears its operation mode before any of its parameters
  # are looked at, so nothing is refused and there is nothing to observe
  require_root || return 0
  # Only the last component is created, so a path whose parent is missing
  # cannot be made and has to be reported rather than silently recovered
  # somewhere else
  local -r IMAGE="$(make_image --name uncreatable_recovery_directory)"

  run_ext4magic -r -d "$CASE_DIRECTORY/no_such_parent/target" "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "there is nowhere to recover into"
  assert_contains "$CAPTURED_STDERR" "can not create the recover directory" "and it says so on stderr"
}

function test_a_recovery_directory_that_is_a_file_is_refused() {
  # Below root ext4magic clears its operation mode before any of its parameters
  # are looked at, so nothing is refused and there is nothing to observe
  require_root || return 0
  local -r IMAGE="$(make_image --name recovery_directory_is_a_file)"
  local -r NOT_A_DIRECTORY="$CASE_DIRECTORY/a_file"

  printf 'not a directory\n' > "$NOT_A_DIRECTORY"

  run_ext4magic -r -d "$NOT_A_DIRECTORY" "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "a file is not a directory"
}

function test_the_options_may_be_given_in_any_order() {
  # getopt is used in its default mode, so the filesystem may come before the
  # options as well as after them
  require_root || return 0
  local -r IMAGE="$(make_image --name option_order)"

  run_ext4magic -S "$IMAGE" || true
  local -r OPTIONS_FIRST="$CAPTURED_STDOUT"

  run_ext4magic "$IMAGE" -S || true
  local -r FILESYSTEM_FIRST="$CAPTURED_STDOUT"

  assert_contains "$OPTIONS_FIRST" "Filesystem magic number" "the report was produced" || return 1
  assert_equals "$OPTIONS_FIRST" "$FILESYSTEM_FIRST" "and the order of the two made no difference"
}

function test_the_expert_options_are_only_there_when_they_were_built_in() {
  # -Q, -c, -D, -s and -n only exist in a build configured with
  # --enable-expert-mode. The usage text names -Q whatever the build, which is
  # what makes this worth pinning : what the binary accepts is the answer, and
  # a default build has to refuse it
  local -r IMAGE="$(make_image --name expert_options)"
  local EXPERT_MODE_IS_BUILT_IN=false

  run_ext4magic -Q -S "$IMAGE" || true
  if ! printf '%s' "$CAPTURED_OUTPUT" | grep -q "Usage:"; then
    EXPERT_MODE_IS_BUILT_IN=true
  fi

  local OPTION
  for OPTION in -Q -c -D; do
    run_ext4magic "$OPTION" -S "$IMAGE" || true
    if $EXPERT_MODE_IS_BUILT_IN; then
      assert_not_contains "$CAPTURED_OUTPUT" "Usage:" \
        "an expert build accepts $OPTION"
    else
      assert_contains "$CAPTURED_OUTPUT" "Usage:" \
        "a default build refuses $OPTION"
    fi
  done
}

function test_the_only_option_the_usage_names_that_the_binary_refuses_is_the_expert_one() {
  # A user reads the usage and tries what it lists. An option named there that
  # the getopt string does not carry answers with the usage again, which is a
  # loop the user cannot get out of. ext4magic.c carries a "FIXME : usage is not
  # correct" over that text, and this is what it is about : the usage names -Q
  # unconditionally while -Q is only compiled in by --enable-expert-mode.
  #
  # The set of mismatches is asserted rather than each option on its own, so
  # this fails both ways : a second option drifting out of the usage fails it,
  # and so does -Q being brought back into line, which is the point at which
  # this test case has to be tightened rather than left passing by luck
  local -r IMAGE="$(make_image --name usage_names_real_options)"
  local -r NAMED_OPTIONS="$(options_named_in_the_usage_text)"
  local INDEX OPTION
  local REFUSED=""

  assert_not_empty "$NAMED_OPTIONS" "the usage should name some options" || return 1

  for ((INDEX = 0; INDEX < ${#NAMED_OPTIONS}; INDEX++)); do
    OPTION="${NAMED_OPTIONS:INDEX:1}"
    # The options taking a value are covered by their own test cases, and
    # giving them none here would be refused for that reason instead
    case "$OPTION" in
      j | d | B | I | f | i | t | a | b | n) continue ;;
    esac

    run_ext4magic "-$OPTION" "$IMAGE" || true
    if printf '%s' "$CAPTURED_OUTPUT" | grep -q "invalid option"; then
      REFUSED="$REFUSED$OPTION"
    fi
  done

  # An expert build has every option the usage names, so there is nothing left
  # over ; a default build is missing exactly -Q
  if [ -n "$REFUSED" ]; then
    assert_equals "Q" "$REFUSED" \
      "a default build should be missing only the expert option the usage names anyway"
  else
    assert_empty "$REFUSED" "an expert build has every option the usage names"
  fi
}
