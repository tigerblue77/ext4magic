#!/bin/bash

# The time window.
#
# Every mode that reads the journal is bounded by an "after" and a "before", and
# those two are what decides which copies of an inode are considered. Too wide a
# window and the recovery offers a version of the file from before the one that
# was wanted ; too narrow and it finds nothing. So the arithmetic around them is
# worth pinning, and so is the one refusal a user actually runs into.

# The floor "after" has to clear, from ext4magic.c : 315601200 is 1980-01-01,
# chosen so that a timestamp read out of a damaged inode cannot open the window
# onto the whole history of the filesystem
readonly EARLIEST_ACCEPTED_AFTER=315601200


# The window is only reported once the journal is open and only when a time was
# given, so every test case below asks for it through a journal reading mode
function window_reported_by() {
  printf -- '-J'
}

# An epoch second, as ext4magic prints it back
function as_ext4magic_prints_a_time() {
  date -d "@$1" '+%a %b %e %H:%M:%S %Y'
}

function test_an_after_time_on_its_own_leaves_now_as_the_end_of_the_window() {
  require_root || return 0
  local -r IMAGE="$(make_image --name after_alone)"
  local -r AFTER=$(( $(date +%s) - 7200 ))
  local -r STARTED_AT=$(date +%s)

  # shellcheck disable=SC2046
  run_ext4magic $(window_reported_by) -a "$AFTER" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Activ Time after  : $(as_ext4magic_prints_a_time "$AFTER")" \
    "the after time is the one that was given"

  local -r REPORTED_BEFORE="$(printf '%s\n' "$CAPTURED_OUTPUT" | sed -n 's/^Activ Time before : //p')"
  assert_not_empty "$REPORTED_BEFORE" "an end of window was reported" || return 1

  local -r REPORTED_BEFORE_SECONDS=$(date -d "$REPORTED_BEFORE" +%s)
  # "now", read a moment before the run and a moment after it
  if [ "$REPORTED_BEFORE_SECONDS" -ge "$STARTED_AT" ] &&
    [ "$REPORTED_BEFORE_SECONDS" -le "$(date +%s)" ]; then
    pass
  else
    fail "the end of the window should default to the moment of the run" \
      "reported: [$REPORTED_BEFORE_SECONDS]" "the run happened between: [$STARTED_AT] and [$(date +%s)]"
  fi
}

function test_a_before_time_on_its_own_starts_the_window_a_day_earlier() {
  require_root || return 0
  local -r IMAGE="$(make_image --name before_alone)"
  # Inside the last day, because the start of the window still defaults to a
  # day ago and a "before" older than that would make the window empty
  local -r BEFORE=$(( $(date +%s) - 60 ))

  # shellcheck disable=SC2046
  run_ext4magic $(window_reported_by) -b "$BEFORE" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Activ Time before : $(as_ext4magic_prints_a_time "$BEFORE")" \
    "the before time is the one that was given"

  local -r REPORTED_AFTER="$(printf '%s\n' "$CAPTURED_OUTPUT" | sed -n 's/^Activ Time after  : //p')"
  assert_not_empty "$REPORTED_AFTER" "a start of window was reported" || return 1

  local -r WINDOW_WIDTH=$(( BEFORE - $(date -d "$REPORTED_AFTER" +%s) ))
  # The start defaults to a day before the moment of the run rather than a day
  # before the given end, so the window is a little narrower than 86400
  if [ "$WINDOW_WIDTH" -gt 86000 ] && [ "$WINDOW_WIDTH" -le 86400 ]; then
    pass
  else
    fail "the start of the window should default to about a day back" \
      "the window came out [$WINDOW_WIDTH] seconds wide"
  fi
}

function test_a_before_time_older_than_a_day_is_refused_unless_an_after_time_comes_with_it() {
  # The trap in the two defaults : the start of the window is a day ago whatever
  # the end is, so asking for "everything before last week" on its own describes
  # a window that ends before it starts
  require_root || return 0
  local -r IMAGE="$(make_image --name before_older_than_a_day)"
  local -r A_WEEK_AGO=$(( $(date +%s) - 7 * 86400 ))

  # shellcheck disable=SC2046
  run_ext4magic $(window_reported_by) -b "$A_WEEK_AGO" "$IMAGE" || true
  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "on its own it is refused"
  assert_contains "$CAPTURED_OUTPUT" 'range "AFTER <--> BEFORE"' "as an impossible range"

  # shellcheck disable=SC2046
  run_ext4magic $(window_reported_by) -a $(( A_WEEK_AGO - 86400 )) -b "$A_WEEK_AGO" "$IMAGE" || true
  assert_equals "0" "$CAPTURED_EXIT_CODE" "with a start given as well it is accepted"
}

function test_both_ends_of_the_window_are_taken_as_they_were_given() {
  require_root || return 0
  local -r IMAGE="$(make_image --name both_ends)"
  local -r AFTER=1600000000
  local -r BEFORE=1700000000

  # shellcheck disable=SC2046
  run_ext4magic $(window_reported_by) -a "$AFTER" -b "$BEFORE" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Activ Time after  : $(as_ext4magic_prints_a_time "$AFTER")" \
    "the start of the window"
  assert_contains "$CAPTURED_OUTPUT" "Activ Time before : $(as_ext4magic_prints_a_time "$BEFORE")" \
    "and its end"
}

function test_a_window_that_ends_before_it_starts_is_refused() {
  # Below root ext4magic clears its operation mode before any of its parameters
  # are looked at, so nothing is refused and there is nothing to observe
  require_root || return 0
  local -r IMAGE="$(make_image --name inverted_window)"

  run_ext4magic -H -a 1700000000 -b 1600000000 "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "the window is empty"
  assert_contains "$CAPTURED_OUTPUT" 'range "AFTER <--> BEFORE"' "the message names the range"
  assert_contains "$CAPTURED_OUTPUT" 'must greater then' "and says which way round they go"
}

function test_a_window_whose_two_ends_are_the_same_instant_is_refused() {
  # Below root ext4magic clears its operation mode before any of its parameters
  # are looked at, so nothing is refused and there is nothing to observe
  require_root || return 0
  # The comparison is strict, so a window of zero width holds nothing and is
  # refused rather than quietly finding nothing
  local -r IMAGE="$(make_image --name zero_width_window)"

  run_ext4magic -H -a 1700000000 -b 1700000000 "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "a window of no width"
  assert_contains "$CAPTURED_OUTPUT" 'range "AFTER <--> BEFORE"' "is refused as a range"
}

function test_an_after_time_before_1980_is_refused() {
  # Below root ext4magic clears its operation mode before any of its parameters
  # are looked at, so nothing is refused and there is nothing to observe
  require_root || return 0
  # A timestamp read out of a damaged inode is often zero or nearly so, and a
  # window opening there would have the scan consider every copy the journal
  # holds. 1980-01-01 is where ext4magic draws the line
  local -r IMAGE="$(make_image --name after_before_1980)"
  local AFTER
  for AFTER in 1 1000 86400 315601199 "$EARLIEST_ACCEPTED_AFTER"; do
    run_ext4magic -H -a "$AFTER" "$IMAGE" || true
    assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" \
      "an after time of $AFTER is below the floor"
  done
}

function test_an_after_time_from_1980_onwards_is_accepted() {
  require_root || return 0
  local -r IMAGE="$(make_image --name after_after_1980)"

  # shellcheck disable=SC2046
  run_ext4magic $(window_reported_by) -a "$((EARLIEST_ACCEPTED_AFTER + 1))" "$IMAGE" || true

  assert_not_contains "$CAPTURED_OUTPUT" 'range "AFTER <--> BEFORE"' \
    "one second past the floor is accepted"
  assert_equals "0" "$CAPTURED_EXIT_CODE" "and the run goes ahead"
}

function test_a_time_of_zero_is_refused_at_either_end() {
  # No require_root here : this one is refused inside the option loop, before
  # the mode is cleared, so it is one of the few refusals that still happen
  local -r IMAGE="$(make_image --name zero_time)"

  run_ext4magic -H -a 0 "$IMAGE" || true
  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "an after time of zero"
  assert_contains "$CAPTURED_OUTPUT" "-a: time" "named as the option it came from"

  run_ext4magic -H -b 0 "$IMAGE" || true
  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "a before time of zero"
  assert_contains "$CAPTURED_OUTPUT" "-b: time" "named as the option it came from"
}

function test_a_time_that_is_not_a_number_is_refused() {
  # Below root ext4magic clears its operation mode before any of its parameters
  # are looked at, so nothing is refused and there is nothing to observe
  require_root || return 0
  # strtoul reads nothing out of it, which leaves zero, which the check below
  # refuses
  local -r IMAGE="$(make_image --name time_not_a_number)"
  local VALUE
  for VALUE in yesterday "2024-01-01" "" "-"; do
    run_ext4magic -H -a "$VALUE" "$IMAGE" || true
    assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" \
      "\"-a $VALUE\" is not an epoch second"
  done
}

function test_the_refusal_shows_how_to_write_a_window_that_works() {
  # Below root ext4magic clears its operation mode before any of its parameters
  # are looked at, so nothing is refused and there is nothing to observe
  require_root || return 0
  # The one message a user of this option is going to meet, so it has to carry
  # the command that would have worked
  local -r IMAGE="$(make_image --name window_refusal_example)"

  run_ext4magic -H -a 1700000000 -b 1600000000 "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" 'Example :' "an example is offered"
  assert_contains "$CAPTURED_OUTPUT" '-b $(date +%s)' "showing how to write the end of the window"
  assert_contains "$CAPTURED_OUTPUT" '-a $(date -d "-1 day" +%s)' "and its start"
  assert_contains "$CAPTURED_OUTPUT" "$IMAGE" "against the filesystem that was given"
}

function test_every_mode_that_reads_the_journal_reports_the_window_it_is_working_in() {
  # The window is the parameter a user is most likely to have got wrong, so
  # every mode that is bounded by one prints it before it starts
  require_root || return 0
  local -r IMAGE="$(make_image --name window_reported)"
  local MODE
  for MODE in -T -J -l -L; do
    run_ext4magic "$MODE" -f / -a 1600000000 -b 1700000000 "$IMAGE" || true
    assert_contains "$CAPTURED_OUTPUT" "Activ Time after" \
      "\"$MODE\" reports the start of its window"
    assert_contains "$CAPTURED_OUTPUT" "Activ Time before" \
      "\"$MODE\" reports the end of it"
  done
}

function test_the_histogram_does_not_report_a_window_because_it_does_not_read_the_journal() {
  # -H walks the inode tables rather than the journal, and the window it draws
  # its axis from is printed on the histogram itself. Pinned because it is the
  # one mode taking -a and -b that does not echo them back the way the others do
  require_root || return 0
  local -r IMAGE="$(make_image --name histogram_window)"

  run_ext4magic -H -a 1600000000 -b 1700000000 "$IMAGE" || true

  assert_equals "0" "$CAPTURED_EXIT_CODE" "the run goes ahead"
  assert_not_contains "$CAPTURED_OUTPUT" "Activ Time after" "without the journal banner"
  # The window is on the histogram instead : its start is in the header, and its
  # ten rows are the ends of the ten buckets it was cut into
  assert_contains "$CAPTURED_OUTPUT" "after  --------------------  $(as_ext4magic_prints_a_time 1600000000)" \
    "the header carries the start of the window"
  assert_contains "$CAPTURED_OUTPUT" "1610000000 :" "the first bucket ends a tenth of the way in"
  assert_contains "$CAPTURED_OUTPUT" "1700000000 :" "and the last one ends at the end of the window"
}

function test_the_magic_scan_takes_the_window_over_from_the_filesystem_when_none_was_given() {
  # A user who has just deleted something runs "ext4magic -M" and nothing else.
  # The scan then reads the last deletion time off the filesystem and starts
  # there, which is the whole reason the option can be left out
  require_root || return 0
  require_loop_mount || return 0
  local -r IMAGE="$(make_image --type ext3 --name magic_default_window)"
  local -r TARGET="$(new_recovery_directory)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -M -d "$TARGET" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Activ Time after" "a window was settled on"
  assert_not_contains "$CAPTURED_OUTPUT" 'range "AFTER <--> BEFORE"' "and it is a valid one"
  assert_not_contains "$CAPTURED_OUTPUT" "No time window found" \
    "the deletions gave it something to start from"
}

function test_the_magic_scan_says_so_when_the_filesystem_offers_no_window_to_start_from() {
  # A filesystem nothing was ever deleted from has no last deletion time, so
  # there is nothing to work back from and the user has to give one
  require_root || return 0
  local -r IMAGE="$(make_image --type ext3 --name magic_no_window)"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -M -d "$TARGET" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "No time window found" "it says there is nothing to start from"
  assert_contains "$CAPTURED_OUTPUT" "deleted inode" "and why"
}
