#!/bin/bash

# The magic scan, "-m" and "-M".
#
# Once the journal has given up everything it holds, what is left is free blocks
# with a file's bytes still in them and nothing saying where one file ends and
# the next begins. The magic scan reads those blocks, recognises the file types
# it knows, and carves the files back out. It is the last resort, and it is the
# part of ext4magic that promises the least, so what is asserted here is what it
# is fair to hold it to : the passes it runs, where it puts what it finds, what
# it names it, and that it comes back.

# Write a file of a recognisable type into a mounted image, delete it, and
# leave $MARK holding a time just before the deletion
# Usage : carve_setup "$IMAGE" && ...
function a_deleted_file_of_a_recognisable_type() {
  local -r IMAGE="$1"
  local -r LOCAL_FILE="$2"
  local -r NAME_IN_THE_IMAGE="$3"
  local MOUNT_POINT

  MOUNT_POINT="$(mount_image "$IMAGE")" || return 1
  mkdir -p "$MOUNT_POINT/carved"
  cp "$LOCAL_FILE" "$MOUNT_POINT/carved/$NAME_IN_THE_IMAGE"

  close_the_transaction_and_mark "$IMAGE" || return 1
  MOUNT_POINT="$REMOUNTED_AT"
  MARK="$DELETION_MARK_TIME"

  rm -f "$MOUNT_POINT/carved/$NAME_IN_THE_IMAGE"
  sync
  unmount_image "$IMAGE"
  return 0
}


function test_the_magic_scan_runs_its_three_passes_in_order() {
  require_root || return 0
  require_loop_mount || return 0
  # Each pass is a weaker guess than the one before, so the order is what tells
  # a user how much to trust what came out of each. Only ext4 reaches the third
  # one in this release, which is what the ext3 test case below is about
  local -r IMAGE="$(make_image --type ext4 --size 64 --name magic_passes)"
  local -r TARGET="$(new_recovery_directory)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  local -r PASS_ORDER="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -oE 'MAGIC-[0-9]' | awk '!seen[$0]++' | tr '\n' ' ')"
  assert_equals "MAGIC-1 MAGIC-2 MAGIC-3 " "$PASS_ORDER" \
    "the three passes are announced, in order, once each"
}

function test_an_ext3_magic_scan_stops_after_the_second_pass() {
  require_root || return 0
  require_loop_mount || return 0
  # The third pass has no ext3 engine in this release, so it is not announced at
  # all : the message pointing at 0.2.4 takes its place. The two are pinned
  # together so that neither can quietly go missing
  local -r IMAGE="$(make_image --type ext3 --size 64 --name magic_passes_ext3)"
  local -r TARGET="$(new_recovery_directory)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  local -r PASS_ORDER="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -oE 'MAGIC-[0-9]' | awk '!seen[$0]++' | tr '\n' ' ')"
  assert_equals "MAGIC-1 MAGIC-2 " "$PASS_ORDER" "only the first two passes are announced"
  assert_contains "$CAPTURED_OUTPUT" "MAGIC function for ext3 not available" \
    "and the third says why it is not one of them"
}

function test_the_magic_scan_names_what_each_pass_is_looking_for() {
  require_root || return 0
  require_loop_mount || return 0
  local -r IMAGE="$(make_image --type ext4 --size 64 --name magic_pass_names)"
  local -r TARGET="$(new_recovery_directory)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_contains "$CAPTURED_STDOUT" "MAGIC-1 : start lost directory search" "the directories"
  assert_contains "$CAPTURED_STDOUT" "MAGIC-2 : start lost file search" "then the files"
  assert_contains "$CAPTURED_STDOUT" "MAGIC-2 : start lost in journal search" "then what the journal still holds"
}

function test_what_the_second_pass_carves_is_filed_under_the_type_it_recognised() {
  require_root || return 0
  require_loop_mount || return 0
  # A file the journal knows the inode of but not the name of is written under
  # its media type, which is the only thing left to call it by
  local -r IMAGE="$(make_image --type ext3 --size 64 --name magic_by_type)"
  local -r TARGET="$(new_recovery_directory)"
  local -r ORIGINAL="$CASE_DIRECTORY/plain.txt"
  local MARK

  make_local_file "$ORIGINAL" 30000 41
  a_deleted_file_of_a_recognisable_type "$IMAGE" "$ORIGINAL" "plain.txt" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -m -d "$TARGET" -a "$MARK" "$IMAGE" || true

  local -r RECOVERED="$(recovered_files "$TARGET")"
  assert_not_empty "$RECOVERED" "the scan carved something out" || return 1

  # Either under the name it had, from the first pass, or under its type from
  # the second. Both are correct outcomes ; a file under neither is not
  if printf '%s\n' "$RECOVERED" | grep -qE '^(carved/plain\.txt|MAGIC-[0-9]/[a-z]+/[a-z-]+/.*)$'; then
    pass
  else
    fail "what was carved was filed neither under its name nor under its type" \
      "the recovery produced: [$(printf '%s' "$RECOVERED" | tr '\n' ' ')]"
  fi
}

function test_a_carved_text_file_is_recognised_as_text() {
  require_root || return 0
  require_loop_mount || return 0
  # The type is decided by libmagic on the bytes of the first block, and plain
  # text is the one type every libmagic build recognises the same way
  local -r IMAGE="$(make_image --type ext3 --size 64 --name magic_text)"
  local -r TARGET="$(new_recovery_directory)"
  local -r ORIGINAL="$CASE_DIRECTORY/plain.txt"
  local MARK

  make_local_file "$ORIGINAL" 40000 42
  a_deleted_file_of_a_recognisable_type "$IMAGE" "$ORIGINAL" "plain.txt" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -m -d "$TARGET" -a "$MARK" "$IMAGE" || true

  local -r RECOVERED="$(recovered_file_matching "$TARGET" "$ORIGINAL")"
  if [ -n "$RECOVERED" ]; then
    pass
    assert_files_identical "$ORIGINAL" "$RECOVERED" "the carved file is the file that was deleted"
  else
    fail "the deleted text file was not carved back out" \
      "the recovery produced: [$(recovered_files "$TARGET" | tr '\n' ' ')]"
  fi
}

function test_the_magic_scan_needs_nothing_but_a_target_directory() {
  require_root || return 0
  require_loop_mount || return 0
  # The whole point of "-M" : a user who has just deleted something runs it with
  # no options at all beyond where to put what it finds
  local -r IMAGE="$(make_image --type ext3 --size 64 --name magic_no_options)"
  local -r TARGET="$(new_recovery_directory)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -M -d "$TARGET" "$IMAGE" || true

  assert_equals "0" "$CAPTURED_EXIT_CODE" "the run goes ahead without a time window"
  assert_not_empty "$(recovered_files "$TARGET")" "and comes back with the deletions"
}

function test_the_magic_scan_recovers_into_the_current_directory_when_it_is_given_none() {
  require_root || return 0
  require_loop_mount || return 0
  # Without "-d" the recovery goes into a directory named after the program, in
  # whatever directory the user was in. That is a file being written somewhere
  # the command line did not name, so it is worth pinning where
  local -r IMAGE="$(make_image --type ext3 --size 64 --name magic_default_target)"
  local -r RUN_FROM="$CASE_DIRECTORY/run_from_here"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  mkdir -p "$RUN_FROM"
  ( cd "$RUN_FROM" && "$(ext4magic_binary)" -M -a "$DELETION_MARK_TIME" "$IMAGE" ) > /dev/null 2>&1 || true

  local -r WHAT_WAS_CREATED="$(find "$RUN_FROM" -mindepth 1 -maxdepth 1 -type d)"
  assert_not_empty "$WHAT_WAS_CREATED" "a recovery directory was created where the run started"
  assert_contains "$WHAT_WAS_CREATED" "RECOVERDIR" \
    "under a name saying what it is rather than beside the user's own files"
}

function test_the_magic_scan_comes_back_on_a_filesystem_of_random_bytes() {
  require_root || return 0
  # The scan reads free blocks and tries to make files of them. Handed a
  # filesystem whose free blocks are noise, it has to come back rather than
  # carve for ever or fall over
  local -r IMAGE="$(make_image --type ext3 --size 48 --name magic_on_noise)"
  local -r TARGET="$(new_recovery_directory)"
  local -r BLOCK_COUNT=8000

  # Past the metadata at the start, so the filesystem still opens
  dd if=/dev/urandom of="$IMAGE" bs=4096 seek=2000 count="$BLOCK_COUNT" conv=notrunc status=none

  run_ext4magic_with_timeout 300 -M -d "$TARGET" -a 1000000000 "$IMAGE" || true

  assert_not_equals "$EXIT_CODE_OF_A_RUN_THAT_WAS_KILLED" "$CAPTURED_EXIT_CODE" \
    "the scan comes back rather than running for ever"
  assert_not_contains "$CAPTURED_OUTPUT" "Segmentation fault" "and it does not crash"
}

function test_the_magic_scan_comes_back_on_a_filesystem_whose_journal_is_noise() {
  require_root || return 0
  # The journal is the one structure the scan trusts, and a damaged filesystem
  # is exactly what ext4magic is pointed at, so a journal of noise is a real
  # input rather than a contrived one
  local -r IMAGE="$(make_image --type ext3 --size 48 --name magic_on_a_noisy_journal)"
  local -r TARGET="$(new_recovery_directory)"
  local -r JOURNAL_COPY="$CASE_DIRECTORY/noisy_journal"

  head -c 4194304 /dev/urandom > "$JOURNAL_COPY"

  run_ext4magic_with_timeout 300 -j "$JOURNAL_COPY" -M -d "$TARGET" -a 1000000000 "$IMAGE" || true

  assert_not_equals "$EXIT_CODE_OF_A_RUN_THAT_WAS_KILLED" "$CAPTURED_EXIT_CODE" \
    "the scan comes back rather than running for ever"
  assert_not_contains "$CAPTURED_OUTPUT" "Segmentation fault" "and it does not crash"
}

function test_the_magic_scan_says_that_the_ext3_engine_is_not_this_version() {
  require_root || return 0
  require_loop_mount || return 0
  # The third pass is written for one filesystem per release : 0.3.x carries the
  # ext4 engine and points at 0.2.4 for ext3. A user whose files were not
  # recovered needs to be told that rather than left to guess
  local -r IMAGE="$(make_image --type ext3 --size 64 --name magic_ext3_engine)"
  local -r TARGET="$(new_recovery_directory)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "MAGIC function for ext3 not available" \
    "the third pass says it has no ext3 engine"
  assert_contains "$CAPTURED_OUTPUT" "0.2.4" "and names the version that does"
}

function test_the_magic_scan_runs_its_own_engine_on_ext4() {
  require_root || return 0
  require_loop_mount || return 0
  local -r IMAGE="$(make_image --type ext4 --size 64 --name magic_ext4_engine)"
  local -r TARGET="$(new_recovery_directory)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "MAGIC-3 : start ext4-magic-scan search" \
    "the ext4 engine is the one that runs"
  assert_not_contains "$CAPTURED_OUTPUT" "MAGIC function for ext3 not available" \
    "and it does not send an ext4 user to the ext3 release"
}

function test_the_magic_scan_leaves_the_filesystem_it_read_untouched() {
  require_root || return 0
  require_loop_mount || return 0
  # The scan is the mode that reads the most of the filesystem, so it is the one
  # worth checking the read only promise against on its own
  local -r IMAGE="$(make_image --type ext3 --size 64 --name magic_read_only)"
  local -r TARGET="$(new_recovery_directory)"
  local -r COPY="$CASE_DIRECTORY/before_the_scan.img"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }
  cp "$IMAGE" "$COPY"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_files_identical "$COPY" "$IMAGE" "the filesystem is byte for byte what it was"
}

function test_the_magic_scan_uses_the_magic_database_it_finds_and_says_which() {
  require_root || return 0
  require_loop_mount || return 0
  # ext4magic ships its own magic database and falls back on libmagic's. Which
  # one was used decides which file types the third pass can recognise at all,
  # so a run that recovered nothing is read together with this line
  local -r IMAGE="$(make_image --type ext3 --size 64 --name magic_database)"
  local -r TARGET="$(new_recovery_directory)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  # Its own database when it is installed, and nothing said when it is not,
  # which is the ordinary case for a build that was not "make install"ed
  if printf '%s' "$CAPTURED_STDOUT" | grep -q "use magic-db on"; then
    assert_matches "$CAPTURED_STDOUT" 'use magic-db on "/usr(/local)?/share/misc/ext4magic"' \
      "the database it found is one of the two places it looks"
  else
    assert_not_contains "$CAPTURED_STDOUT" "use magic-db on" \
      "with no database of its own installed, it says nothing and uses libmagic's"
  fi
}
