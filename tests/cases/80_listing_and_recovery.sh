#!/bin/bash

# Listing and recovering, which is what ext4magic is for.
#
# Everything here needs a real journal, and a real journal is only written by a
# mounted filesystem, so these test cases build one, fill it, delete from it and
# unmount it before ext4magic is pointed at the result. Without root they skip
# rather than pretend.
#
# The filesystems are ext3 : the recovery of a file whose blocks are described
# by an extent tree does not currently come back with its content, so an ext4
# filesystem gives nothing to assert a recovery against. What ext4magic does do
# on ext4 is pinned in its own test cases at the end, which is where that
# difference is written down.

# Recover a path out of an image and print the directory it was recovered into
# Usage : TARGET=$(recover_path_from "$IMAGE" "documents" "$DELETION_MARK_TIME")
function recover_path_from() {
  local -r IMAGE="$1"
  local -r PATHNAME="$2"
  local -r AFTER="$3"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -f "$PATHNAME" -r -d "$TARGET" -a "$AFTER" "$IMAGE" > /dev/null 2>&1 || true
  printf '%s' "$TARGET"
}

# An image filled and emptied, ready for a recovery.
#
# It sets $IMAGE_WITH_DELETED_FILES, $ORIGINALS_DIRECTORY and
# $DELETION_MARK_TIME rather than printing the path : a command substitution
# would run it in a subshell, and the last two would be lost with it
# Usage : a_filesystem_with_deleted_files ext3 || return 1
function a_filesystem_with_deleted_files() {
  local -r TYPE="${1:-ext3}"

  IMAGE_WITH_DELETED_FILES="$(make_image --type "$TYPE" --size 64 --name "recovery_$TYPE")"
  populate_and_delete "$IMAGE_WITH_DELETED_FILES" || return 1
  return 0
}


function test_a_path_that_still_exists_is_resolved_to_its_inode() {
  require_root || return 0
  require_loop_mount || return 0
  # The first thing every -f run does. The directory was not deleted, so this is
  # only about reading the filesystem
  local -r IMAGE="$(make_image --type ext3 --name resolve_a_path)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -f documents -l -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" 'Inode found "documents"' "the directory was found"
  assert_matches "$CAPTURED_OUTPUT" 'Inode found "documents" +[0-9]+' "under an inode number"
}

function test_a_path_that_never_existed_is_reported_as_not_found() {
  require_root || return 0
  require_loop_mount || return 0
  local -r IMAGE="$(make_image --type ext3 --name resolve_a_missing_path)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -f no_such_directory -l -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_contains "$CAPTURED_STDERR" 'Inode not found for "no_such_directory"' \
    "the path is reported as not found"
  assert_contains "$CAPTURED_STDERR" "Check the valid PATHNAME" "with what to check"
}

function test_a_nested_path_is_resolved_through_each_of_its_components() {
  require_root || return 0
  require_loop_mount || return 0
  local -r IMAGE="$(make_image --type ext3 --name resolve_a_nested_path)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -f documents/reports -l -a "$DELETION_MARK_TIME" "$IMAGE" || true

  # The whole path is echoed back, not only its last component, so a user can
  # see which of the two it resolved when they mistyped one of them
  assert_contains "$CAPTURED_OUTPUT" 'Inode found "documents/reports"' \
    "the path that was asked for is the one reported"
  assert_not_contains "$CAPTURED_STDERR" "Inode not found" "and nothing on the way to it was missing"
  assert_contains "$CAPTURED_OUTPUT" "quarterly.txt" \
    "and the file deleted from it is the one listed"
}

function test_the_root_directory_is_resolved_without_a_name() {
  require_root || return 0
  require_loop_mount || return 0
  local -r IMAGE="$(make_image --type ext3 --name resolve_the_root)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -f / -l -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Inode found" "the root is found"
  assert_matches "$CAPTURED_OUTPUT" 'Inode found "" +2' "on inode 2, where every ext filesystem's root is"
}

function test_a_deleted_file_is_recovered_with_its_content_intact() {
  require_root || return 0
  require_loop_mount || return 0
  # The whole point of the program. A file of the right name and the right size
  # holding the wrong bytes is the failure this is about, so the comparison is
  # byte for byte against the original
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  local RECOVERED
  RECOVERED="$(recovered_file_matching "$TARGET" "$ORIGINALS_DIRECTORY/documents/notes.txt")"
  if [ -n "$RECOVERED" ]; then
    pass
    assert_files_identical "$ORIGINALS_DIRECTORY/documents/notes.txt" "$RECOVERED" \
      "the recovered file is the file that was deleted"
  else
    fail "the deleted file was not recovered" \
      "looked for the content of: [$ORIGINALS_DIRECTORY/documents/notes.txt]" \
      "under: [$TARGET]" \
      "which holds: [$(recovered_files "$TARGET" | tr '\n' ' ')]"
  fi
}

function test_every_deleted_file_is_recovered_with_its_content_intact() {
  require_root || return 0
  require_loop_mount || return 0
  # Three files of three different sizes : one that fits in a handful of blocks,
  # one that needs an indirect block, and one that needs a double indirect one.
  # The three reach three different paths through the block reader
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  local RELATIVE_PATH
  for RELATIVE_PATH in documents/notes.txt documents/reports/quarterly.txt pictures/holiday.dat; do
    local RECOVERED
    RECOVERED="$(recovered_file_matching "$TARGET" "$ORIGINALS_DIRECTORY/$RELATIVE_PATH")"
    if [ -n "$RECOVERED" ]; then
      pass
    else
      fail "\"$RELATIVE_PATH\" was not recovered with its content" \
        "$(wc -c < "$ORIGINALS_DIRECTORY/$RELATIVE_PATH" | tr -d ' ') bytes were deleted" \
        "the recovery produced: [$(recovered_files "$TARGET" | tr '\n' ' ')]"
    fi
  done
}

function test_a_recovered_file_keeps_the_name_and_the_directory_it_was_deleted_from() {
  require_root || return 0
  require_loop_mount || return 0
  # Recovering the bytes is half of it : a thousand files under invented names
  # is not a recovery anybody can use
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_file_exists "$TARGET/documents/notes.txt" "the file is under the name it had"
  assert_file_exists "$TARGET/documents/reports/quarterly.txt" "and so is the one in a subdirectory"
  assert_file_exists "$TARGET/pictures/holiday.dat" "and the one in another directory"
}

function test_a_recovered_file_matches_the_original_byte_for_byte_under_its_own_name() {
  require_root || return 0
  require_loop_mount || return 0
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  local RELATIVE_PATH
  for RELATIVE_PATH in documents/notes.txt documents/reports/quarterly.txt pictures/holiday.dat; do
    if [ -f "$TARGET/$RELATIVE_PATH" ]; then
      assert_files_identical "$ORIGINALS_DIRECTORY/$RELATIVE_PATH" "$TARGET/$RELATIVE_PATH" \
        "\"$RELATIVE_PATH\" came back as it went in"
    else
      fail "\"$RELATIVE_PATH\" was not recovered under its own name" \
        "the recovery produced: [$(recovered_files "$TARGET" | tr '\n' ' ')]"
    fi
  done
}

function test_a_file_that_was_not_deleted_is_left_where_it_is() {
  require_root || return 0
  require_loop_mount || return 0
  # "-m" recovers what was deleted. A run that also copied out the live files
  # would bury the ones the user is looking for
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -m -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_file_does_not_exist "$TARGET/keep/kept.txt" \
    "the file that was never deleted was not recovered"
}

function test_the_magic_scan_ignores_the_end_of_the_window_and_says_so() {
  require_root || return 0
  require_loop_mount || return 0
  # The magic scan resets the end of the window to the moment of the run,
  # whatever "-b" said, because what it carves out of free blocks has no
  # timestamp to be bounded by. It warns that it is going to ignore options,
  # and this is which one : a window closing an hour before the deletions still
  # comes back with them
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -m -d "$TARGET" -a "$((DELETION_MARK_TIME - 7200))" \
    -b "$((DELETION_MARK_TIME - 3600))" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "may be some command line options ignored" \
    "the run warns that it is going to ignore options"
  assert_not_empty "$(recovered_files "$TARGET")" \
    "and the deletions past the end of the window are recovered all the same"
}

function test_a_window_that_opens_after_the_deletions_recovers_nothing() {
  require_root || return 0
  require_loop_mount || return 0
  # The start of the window is honoured : it is read off the inodes, which do
  # carry a deletion time. A window opening after everything was deleted has
  # nothing in it
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -m -d "$TARGET" -a "$((DELETION_MARK_TIME + 3600))" "$IMAGE" || true

  assert_empty "$(recovered_files "$TARGET")" \
    "a window that opens an hour after the deletions recovers nothing"
}

function test_the_recovery_reports_each_file_it_wrote() {
  require_root || return 0
  require_loop_mount || return 0
  # The listing on stdout is what a user reads to know what they got, and it has
  # to name the same files the recovery directory holds
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  local RECOVERED_FILE
  while IFS= read -r RECOVERED_FILE; do
    [ -n "$RECOVERED_FILE" ] || continue
    assert_contains "$CAPTURED_STDOUT" "$RECOVERED_FILE" \
      "the run named \"$RECOVERED_FILE\" among what it recovered"
  done < <(recovered_files "$TARGET" | head -5)
}

function test_the_recovery_stages_are_announced_as_they_are_reached() {
  require_root || return 0
  require_loop_mount || return 0
  # The magic recovery is three passes, and knowing which one produced a file
  # is what tells a user how much to trust it : a file from the first pass came
  # back with its name, one from the third was carved out of free blocks
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "MAGIC-1 : start lost directory search" "the first pass"
  assert_contains "$CAPTURED_OUTPUT" "MAGIC-2 : start lost file search" "the second"
}

function test_a_recovery_of_the_whole_tree_finds_at_least_what_a_recovery_of_the_deleted_finds() {
  require_root || return 0
  require_loop_mount || return 0
  # "-M" is "-m" plus the files that were not deleted, so whatever "-m" comes
  # back with, "-M" has to come back with as well
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r DELETED_ONLY="$(new_recovery_directory)"
  local -r WHOLE_TREE="$(new_recovery_directory)"

  run_ext4magic -m -d "$DELETED_ONLY" -a "$DELETION_MARK_TIME" "$IMAGE" || true
  run_ext4magic -M -d "$WHOLE_TREE" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  local -r FROM_DELETED_ONLY="$(recovered_files "$DELETED_ONLY" | wc -l | tr -d ' ')"
  local -r FROM_THE_WHOLE_TREE="$(recovered_files "$WHOLE_TREE" | wc -l | tr -d ' ')"

  assert_greater_than "0" "$FROM_DELETED_ONLY" "the deleted files recovery found something" || return 1
  if [ "$FROM_THE_WHOLE_TREE" -ge "$FROM_DELETED_ONLY" ]; then
    pass
  else
    fail "the whole tree recovery found fewer files than the deleted files recovery" \
      "-m found: [$FROM_DELETED_ONLY]" "-M found: [$FROM_THE_WHOLE_TREE]"
  fi
}

function test_recovering_twice_into_the_same_directory_never_overwrites_the_first_run() {
  require_root || return 0
  require_loop_mount || return 0
  # A user who is not sure runs it again, often with a wider window. What the
  # first run recovered is the thing that must not be lost : the second run adds
  # to the directory, under other names, rather than writing over it
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true
  local -r FILES_AFTER_THE_FIRST_RUN="$(recovered_files "$TARGET")"
  local -r CHECKSUMS_AFTER_THE_FIRST_RUN="$(cd "$TARGET" && find . -type f -exec sha256sum {} + | sort -k2)"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_not_empty "$FILES_AFTER_THE_FIRST_RUN" "the first run recovered something" || return 1

  # Every file the first run wrote is still there, holding the same bytes
  local CHECKSUM_LINE FILE_PATH
  while IFS= read -r CHECKSUM_LINE; do
    [ -n "$CHECKSUM_LINE" ] || continue
    FILE_PATH="${CHECKSUM_LINE#* }"
    FILE_PATH="${FILE_PATH# }"
    assert_contains "$(cd "$TARGET" && find . -type f -exec sha256sum {} + | sort -k2)" \
      "$CHECKSUM_LINE" "\"$FILE_PATH\" was left as the first run wrote it"
  done <<< "$CHECKSUMS_AFTER_THE_FIRST_RUN"
}

function test_a_second_recovery_names_its_copies_apart_rather_than_replacing_what_is_there() {
  require_root || return 0
  require_loop_mount || return 0
  # The other half of the same guarantee : a second run that finds the same file
  # again writes it beside the first copy under a name of its own
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true
  local -r HOW_MANY_AFTER_THE_FIRST_RUN="$(recovered_files "$TARGET" | wc -l | tr -d " ")"

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true
  local -r HOW_MANY_AFTER_THE_SECOND_RUN="$(recovered_files "$TARGET" | wc -l | tr -d " ")"

  assert_greater_than "0" "$HOW_MANY_AFTER_THE_FIRST_RUN" "the first run recovered something" || return 1
  assert_greater_than "$((HOW_MANY_AFTER_THE_FIRST_RUN - 1))" "$HOW_MANY_AFTER_THE_SECOND_RUN" \
    "the second run left at least as many files as it found"
}

function test_the_recovery_directory_is_left_alone_when_the_run_is_refused() {
  require_root || return 0
  require_loop_mount || return 0
  # A run stopped by a bad option must not have written anything : the user is
  # going to fix the option and run it again into the same directory
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r TARGET="$(new_recovery_directory)"

  run_ext4magic -m -r -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "two modes are refused"
  assert_empty "$(recovered_files "$TARGET")" "and nothing was written before the refusal"
}

function test_a_deleted_file_is_recovered_whatever_the_block_size_of_the_filesystem() {
  require_root || return 0
  require_loop_mount || return 0
  # The block size decides how the file's blocks are addressed and how many
  # indirect blocks it takes to describe them
  local BLOCK_SIZE
  for BLOCK_SIZE in 1024 2048 4096; do
    local IMAGE TARGET
    IMAGE="$(make_image --type ext3 --size 64 --block-size "$BLOCK_SIZE" \
      --name "recovery_b$BLOCK_SIZE")"
    populate_and_delete "$IMAGE" || {
      fail "the $BLOCK_SIZE byte block image could not be filled and emptied"
      continue
    }
    TARGET="$(new_recovery_directory)"

    run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" > /dev/null 2>&1 || true

    if [ -f "$TARGET/documents/notes.txt" ]; then
      assert_files_identical "$ORIGINALS_DIRECTORY/documents/notes.txt" \
        "$TARGET/documents/notes.txt" \
        "a file deleted from a $BLOCK_SIZE byte block filesystem comes back whole"
    else
      fail "nothing was recovered from a $BLOCK_SIZE byte block filesystem" \
        "the recovery produced: [$(recovered_files "$TARGET" | tr '\n' ' ')]"
    fi
  done
}

function test_a_deleted_file_is_recovered_whatever_the_inode_size_of_the_filesystem() {
  require_root || return 0
  require_loop_mount || return 0
  # A 128 byte inode has no creation time, which is one of the fields the
  # recovery uses to choose between two copies of an inode
  local INODE_SIZE
  for INODE_SIZE in 128 256; do
    local IMAGE TARGET
    IMAGE="$(make_image --type ext3 --size 64 --inode-size "$INODE_SIZE" \
      --name "recovery_i$INODE_SIZE")"
    populate_and_delete "$IMAGE" || {
      fail "the $INODE_SIZE byte inode image could not be filled and emptied"
      continue
    }
    TARGET="$(new_recovery_directory)"

    run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" > /dev/null 2>&1 || true

    if [ -f "$TARGET/documents/notes.txt" ]; then
      assert_files_identical "$ORIGINALS_DIRECTORY/documents/notes.txt" \
        "$TARGET/documents/notes.txt" \
        "a file deleted from a $INODE_SIZE byte inode filesystem comes back whole"
    else
      fail "nothing was recovered from a $INODE_SIZE byte inode filesystem" \
        "the recovery produced: [$(recovered_files "$TARGET" | tr '\n' ' ')]"
    fi
  done
}

# Builder for the test case below : one file large enough to need a double
# indirect block, written and deleted
function build_a_deleted_large_file() {
  local -r IMAGE="$1"
  local MOUNT_POINT

  MOUNT_POINT="$(mount_image "$IMAGE")" || return 1
  mkdir -p "$MOUNT_POINT/big"
  cp "$CASE_DIRECTORY/large.dat" "$MOUNT_POINT/big/large.dat"
  close_the_transaction_and_mark "$IMAGE" || return 1
  rm -f "$REMOUNTED_AT/big/large.dat"
  sync
  unmount_image "$IMAGE"
}

function test_the_recovery_of_a_file_larger_than_one_indirect_block_comes_back_whole() {
  require_root || return 0
  require_loop_mount || return 0
  # On a 1024 byte block filesystem a file passes into its double indirect block
  # after 268 kibibytes, which is the boundary get_dind_block_len() is about
  local -r IMAGE="$(make_image --type ext3 --size 96 --block-size 1024 --name recovery_large_file)"
  local -r ORIGINAL="$CASE_DIRECTORY/large.dat"
  local -r TARGET="$(new_recovery_directory)"

  make_local_file "$ORIGINAL" 500000 7
  build_until_recoverable "$IMAGE" "$ORIGINAL" build_a_deleted_large_file || return 1
  local -r MARK="$DELETION_MARK_TIME"

  run_ext4magic -M -d "$TARGET" -a "$MARK" "$IMAGE" > /dev/null 2>&1 || true

  if [ -f "$TARGET/big/large.dat" ]; then
    assert_files_identical "$ORIGINAL" "$TARGET/big/large.dat" \
      "a file spanning its double indirect block comes back whole"
  else
    fail "the large file was not recovered" \
      "the recovery produced: [$(recovered_files "$TARGET" | tr '\n' ' ')]"
  fi
}

# Builder for the test case below : a small source tree, written and deleted
# whole. It reads the tree $CASE_DIRECTORY/originals holds
function build_a_deleted_project_tree() {
  local -r IMAGE="$1"
  local MOUNT_POINT

  MOUNT_POINT="$(mount_image "$IMAGE")" || return 1
  cp -r "$CASE_DIRECTORY/originals/project" "$MOUNT_POINT/"
  close_the_transaction_and_mark "$IMAGE" || return 1
  rm -rf "$REMOUNTED_AT/project"
  sync
  unmount_image "$IMAGE"
}

function test_a_deleted_directory_is_recovered_with_everything_that_was_in_it() {
  require_root || return 0
  require_loop_mount || return 0
  # A recursive delete is the case the magic recovery was written for
  local -r IMAGE="$(make_image --type ext3 --size 64 --name recovery_of_a_tree)"
  local -r TARGET="$(new_recovery_directory)"
  local -r ORIGINALS="$CASE_DIRECTORY/originals"

  mkdir -p "$ORIGINALS/project/source" "$ORIGINALS/project/notes"
  make_local_file "$ORIGINALS/project/source/main.c" 9000 11
  make_local_file "$ORIGINALS/project/source/util.c" 12000 12
  make_local_file "$ORIGINALS/project/notes/todo.txt" 3000 13

  build_until_recoverable "$IMAGE" "$ORIGINALS/project/source/main.c" \
    build_a_deleted_project_tree || return 1
  local -r MARK="$DELETION_MARK_TIME"

  run_ext4magic -M -d "$TARGET" -a "$MARK" "$IMAGE" > /dev/null 2>&1 || true

  local RELATIVE_PATH
  for RELATIVE_PATH in project/source/main.c project/source/util.c project/notes/todo.txt; do
    if [ -f "$TARGET/$RELATIVE_PATH" ]; then
      assert_files_identical "$ORIGINALS/$RELATIVE_PATH" "$TARGET/$RELATIVE_PATH" \
        "\"$RELATIVE_PATH\" came back with the tree"
    else
      fail "\"$RELATIVE_PATH\" was not recovered with its directory" \
        "the recovery produced: [$(recovered_files "$TARGET" | tr '\n' ' ')]"
    fi
  done
}

# Builder for the test case below : one file with a mode and an owner of its
# own, written and deleted
function build_a_deleted_file_with_attributes() {
  local -r IMAGE="$1"
  local MOUNT_POINT

  MOUNT_POINT="$(mount_image "$IMAGE")" || return 1
  mkdir -p "$MOUNT_POINT/attributes"
  cp "$CASE_DIRECTORY/private.txt" "$MOUNT_POINT/attributes/private.txt"
  chmod 600 "$MOUNT_POINT/attributes/private.txt"
  chown 1234:5678 "$MOUNT_POINT/attributes/private.txt"
  close_the_transaction_and_mark "$IMAGE" || return 1
  rm -f "$REMOUNTED_AT/attributes/private.txt"
  sync
  unmount_image "$IMAGE"
}

function test_a_recovered_file_keeps_the_mode_and_the_owner_it_had() {
  require_root || return 0
  require_loop_mount || return 0
  # The inode copy carries them, and a recovery that dropped them would hand
  # back a tree nobody can put back where it came from
  local -r IMAGE="$(make_image --type ext3 --size 64 --name recovery_of_attributes)"
  local -r TARGET="$(new_recovery_directory)"

  make_local_file "$CASE_DIRECTORY/private.txt" 2000 21
  build_until_recoverable "$IMAGE" "$CASE_DIRECTORY/private.txt" \
    build_a_deleted_file_with_attributes || return 1
  local -r MARK="$DELETION_MARK_TIME"

  run_ext4magic -M -d "$TARGET" -a "$MARK" "$IMAGE" > /dev/null 2>&1 || true

  if [ ! -f "$TARGET/attributes/private.txt" ]; then
    fail "the file was not recovered" \
      "the recovery produced: [$(recovered_files "$TARGET" | tr '\n' ' ')]"
    return 1
  fi

  assert_equals "600" "$(stat -c '%a' "$TARGET/attributes/private.txt")" \
    "the permission bits it had"
  assert_equals "1234" "$(stat -c '%u' "$TARGET/attributes/private.txt")" "the user that owned it"
  assert_equals "5678" "$(stat -c '%g' "$TARGET/attributes/private.txt")" "and the group"
}

# The names the test case below writes and deletes
readonly AWKWARD_NAMES=("a report with spaces.txt" "quoted\"name.txt" "été-accentué.txt" "-leading-dash.txt")

# Builder for the test case below
function build_deleted_files_with_awkward_names() {
  local -r IMAGE="$1"
  local MOUNT_POINT NAME INDEX

  MOUNT_POINT="$(mount_image "$IMAGE")" || return 1
  mkdir -p "$MOUNT_POINT/awkward"
  INDEX=0
  for NAME in "${AWKWARD_NAMES[@]}"; do
    cp "$CASE_DIRECTORY/awkward_$INDEX" "$MOUNT_POINT/awkward/$NAME"
    INDEX=$((INDEX + 1))
  done
  close_the_transaction_and_mark "$IMAGE" || return 1
  for NAME in "${AWKWARD_NAMES[@]}"; do
    rm -f "$REMOUNTED_AT/awkward/$NAME"
  done
  sync
  unmount_image "$IMAGE"
}

function test_a_name_with_spaces_or_bytes_that_are_not_text_survives_the_recovery() {
  require_root || return 0
  require_loop_mount || return 0
  # An ext4 name is a byte string, and the recovery writes it back out as a file
  # name. Anything lost on the way is a file recovered under the wrong name
  local -r IMAGE="$(make_image --type ext3 --size 64 --name recovery_of_awkward_names)"
  local -r TARGET="$(new_recovery_directory)"
  local NAME INDEX

  INDEX=0
  for NAME in "${AWKWARD_NAMES[@]}"; do
    make_local_file "$CASE_DIRECTORY/awkward_$INDEX" $((2000 + INDEX * 100)) "$((30 + INDEX))"
    INDEX=$((INDEX + 1))
  done

  build_until_recoverable "$IMAGE" "$CASE_DIRECTORY/awkward_0" \
    build_deleted_files_with_awkward_names || return 1
  local -r MARK="$DELETION_MARK_TIME"

  run_ext4magic -M -d "$TARGET" -a "$MARK" "$IMAGE" > /dev/null 2>&1 || true

  for NAME in "${AWKWARD_NAMES[@]}"; do
    assert_file_exists "$TARGET/awkward/$NAME" "\"$NAME\" came back under its own name"
  done
}

function test_nothing_is_ever_written_outside_the_recovery_directory() {
  require_root || return 0
  require_loop_mount || return 0
  # The file names come off the filesystem being recovered, which is exactly the
  # input a recovery must not trust : a name holding a path separator or a
  # leading "../" would put the file somewhere the user did not ask for
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"
  local -r ENCLOSING_DIRECTORY="$CASE_DIRECTORY/enclosing"
  local -r TARGET="$ENCLOSING_DIRECTORY/recovered"

  mkdir -p "$TARGET"
  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" > /dev/null 2>&1 || true

  local -r OUTSIDE="$(find "$ENCLOSING_DIRECTORY" -mindepth 1 -maxdepth 1 ! -name recovered)"
  assert_empty "$OUTSIDE" "the recovery wrote nothing beside the directory it was given"
}

function test_a_listing_of_a_directory_never_mentions_a_file_that_was_not_there() {
  require_root || return 0
  require_loop_mount || return 0
  # The listing is what a user reads before deciding to recover, and a name that
  # was never in that directory sends them looking for a file that never existed
  a_filesystem_with_deleted_files ext3 || {
    fail "the image could not be filled and emptied"
    return 1
  }
  local -r IMAGE="$IMAGE_WITH_DELETED_FILES"

  run_ext4magic -f documents -L -a "$DELETION_MARK_TIME" "$IMAGE" || true

  assert_not_contains "$CAPTURED_STDOUT" "holiday.dat" \
    "a file of another directory is not listed under this one"
  assert_not_contains "$CAPTURED_STDOUT" "kept.txt" "and neither is one of a third"
}

function test_nothing_is_recovered_from_an_ext4_filesystem_made_with_todays_defaults() {
  require_root || return 0
  require_loop_mount || return 0
  # The difference between the two filesystems ext4magic is named after, written
  # down rather than left out. On an ext4 made the way mke2fs makes one today,
  # not one of the deleted files comes back with its content.
  #
  # The check is "no recovered file holds what was deleted" rather than a count
  # or a set of names, because there are two ways it fails today and this suite
  # should not have to be edited when one of them is fixed and the other is not :
  # the run either writes files of the right length holding nothing but zeros, or
  # writes none at all. Either way nothing came back.
  #
  # An ext3 filesystem built and emptied the same way, by the test cases above,
  # recovers every one of them byte for byte -- so this is not the suite failing
  # to produce something recoverable.
  local -r IMAGE="$(make_image --type ext4 --size 64 --name ext4_with_todays_defaults)"
  local -r TARGET="$(new_recovery_directory)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -M -d "$TARGET" -a "$DELETION_MARK_TIME" "$IMAGE" || true
  assert_equals "0" "$CAPTURED_EXIT_CODE" "the run itself reports success"

  local RELATIVE_PATH
  for RELATIVE_PATH in documents/notes.txt documents/reports/quarterly.txt pictures/holiday.dat; do
    if [ -n "$(recovered_file_matching "$TARGET" "$ORIGINALS_DIRECTORY/$RELATIVE_PATH")" ]; then
      fail "\"$RELATIVE_PATH\" came back from an ext4 filesystem, which this test case says it does not" \
        "this is the outcome to want -- update this test case rather than leave it passing" \
        "the recovery produced: [$(recovered_files "$TARGET" | tr '\n' ' ')]"
    else
      pass
    fi
  done
}

function test_a_path_cannot_be_resolved_on_an_ext4_filesystem() {
  require_root || return 0
  require_loop_mount || return 0
  # The first step of every "-f" run, and it fails on ext4 while succeeding on
  # an ext3 filesystem built the same way. The directory asked for here was
  # never deleted : it is plainly in the filesystem
  local -r IMAGE="$(make_image --type ext4 --size 64 --name ext4_path_resolution)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -f documents -l -a "$DELETION_MARK_TIME" "$IMAGE" || true
  assert_contains "$CAPTURED_STDERR" 'Inode not found for "documents"' \
    "a directory that is plainly there cannot be resolved on ext4"

  # The root directory is the one path that still resolves, because it is
  # reached by its inode number rather than by walking a directory
  run_ext4magic -f / -l -a "$DELETION_MARK_TIME" "$IMAGE" || true
  assert_matches "$CAPTURED_STDOUT" 'Inode found "" +2' "while the root directory itself still is"
}
