#!/bin/bash

# Opening a filesystem, and refusing to.
#
# ext4magic is pointed at whatever a user believes holds their data : a partition,
# an image, a file that turned out to be something else entirely. What it does
# with each of those is the first thing that happens on every run, and a wrong
# answer here is the one a user has no way of telling apart from "there was
# nothing to find".

function test_a_filesystem_that_is_not_there_is_reported() {
  run_ext4magic -S "$CASE_DIRECTORY/no_such_image.img" || true

  assert_contains "$CAPTURED_STDERR" "while opening filesystem" "the failure is reported on stderr"
  assert_contains "$CAPTURED_STDERR" "no_such_image.img" "naming what could not be opened"
  assert_not_contains "$CAPTURED_STDOUT" "Filesystem magic number" "and nothing was reported about it"
}

function test_a_file_that_is_not_a_filesystem_is_reported() {
  local -r NOT_A_FILESYSTEM="$CASE_DIRECTORY/random.img"

  head -c 65536 /dev/urandom > "$NOT_A_FILESYSTEM"

  run_ext4magic -S "$NOT_A_FILESYSTEM" || true

  assert_contains "$CAPTURED_STDERR" "while opening filesystem" "the failure is reported"
  assert_not_contains "$CAPTURED_STDOUT" "Filesystem magic number" "and no superblock was invented for it"
}

function test_an_empty_file_is_reported() {
  local -r EMPTY="$CASE_DIRECTORY/empty.img"

  : > "$EMPTY"

  run_ext4magic -S "$EMPTY" || true

  assert_contains "$CAPTURED_STDERR" "while opening filesystem" "the failure is reported"
  assert_not_contains "$CAPTURED_STDOUT" "Block size" "and nothing was read out of it"
}

function test_a_directory_given_instead_of_a_filesystem_is_reported() {
  run_ext4magic -S "$CASE_DIRECTORY" || true

  assert_contains "$CAPTURED_STDERR" "while opening filesystem" "the failure is reported"
  assert_not_contains "$CAPTURED_STDOUT" "Filesystem magic number" "and nothing was read out of it"
}

function test_a_truncated_filesystem_is_reported_rather_than_read_past_its_end() {
  # An image copied off a failing disk stops in the middle. The superblock is
  # intact, so it opens, and everything after it is missing
  local -r IMAGE="$(make_image --size 32 --name truncated)"

  truncate -s 64K "$IMAGE"

  run_ext4magic_with_timeout 60 -S "$IMAGE" || true

  assert_not_equals "$EXIT_CODE_OF_A_RUN_THAT_WAS_KILLED" "$CAPTURED_EXIT_CODE" \
    "it comes back rather than reading for ever"
}

function test_every_filesystem_type_it_supports_is_opened() {
  require_root || return 0
  # ext2, ext3 and ext4 all reach the same reader, and the superblock report is
  # the shortest proof that each of them was understood
  local TYPE
  for TYPE in ext2 ext3 ext4; do
    local IMAGE
    IMAGE="$(make_image --type "$TYPE" --name "open_$TYPE")"

    run_ext4magic -S "$IMAGE" || true
    assert_contains "$CAPTURED_STDOUT" "Filesystem magic number:  0xEF53" \
      "a $TYPE filesystem is opened"
    assert_contains "$CAPTURED_STDOUT" "Filesystem in use: $IMAGE" \
      "and named back, so the user sees which one was read"
  done
}

function test_every_block_size_is_opened_and_reported() {
  require_root || return 0
  # 1k, 2k and 4k are the three ext4 supports, and the block size decides how
  # everything else in the filesystem is addressed
  local BLOCK_SIZE
  for BLOCK_SIZE in 1024 2048 4096; do
    local IMAGE
    IMAGE="$(make_image --block-size "$BLOCK_SIZE" --name "blocksize_$BLOCK_SIZE")"

    run_ext4magic -S "$IMAGE" || true
    assert_equals "$BLOCK_SIZE" "$(superblock_field "$CAPTURED_STDOUT" "Block size")" \
      "a $BLOCK_SIZE byte block filesystem reports its block size"
  done
}

function test_both_inode_sizes_are_opened_and_reported() {
  require_root || return 0
  # 128 is the ext2 inode, which has no creation time and no room for one ; 256
  # is what every filesystem made today has. ext4magic reads the two apart in
  # several places, starting here
  local INODE_SIZE
  for INODE_SIZE in 128 256; do
    local IMAGE
    IMAGE="$(make_image --inode-size "$INODE_SIZE" --features "^metadata_csum,^64bit" \
      --name "inodesize_$INODE_SIZE")"

    run_ext4magic -S "$IMAGE" || true
    assert_equals "$INODE_SIZE" "$(superblock_field "$CAPTURED_STDOUT" "Inode size")" \
      "a $INODE_SIZE byte inode filesystem reports its inode size"
  done
}

function test_a_filesystem_with_no_journal_is_opened_but_refuses_the_modes_that_need_one() {
  require_root || return 0
  # ext4magic recovers out of the journal, so a filesystem without one has
  # nothing for it. Opening still works, because -S and -I do not need a journal
  local -r IMAGE="$(make_image --type ext2 --name no_journal)"

  run_ext4magic -S "$IMAGE" || true
  assert_contains "$CAPTURED_STDOUT" "Filesystem magic number" "the filesystem itself is readable"

  local MODE
  for MODE in -J -T; do
    run_ext4magic "$MODE" "$IMAGE" || true
    assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" \
      "\"$MODE\" needs a journal and there is none"
    assert_contains "$CAPTURED_OUTPUT" "filesystem has no journal" "and it says exactly that"
  done
}

function test_a_filesystem_whose_journal_was_removed_afterwards_is_refused_the_same_way() {
  require_root || return 0
  # Not the same thing as never having had one : the feature flag is cleared on
  # a filesystem that was made with a journal
  local -r IMAGE="$(make_image --name journal_removed)"

  tune2fs -O ^has_journal "$IMAGE" > /dev/null 2>&1 || {
    skip_test "tune2fs cannot remove the journal here"
    return 0
  }

  run_ext4magic -J "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "there is no journal any more"
  assert_contains "$CAPTURED_OUTPUT" "filesystem has no journal" "and it says exactly that"
}

function test_an_external_journal_file_is_read_instead_of_the_internal_one() {
  require_root || return 0
  # The documented way of working on a filesystem that cannot be unmounted : the
  # journal is dumped out with debugfs and handed over with -j
  local -r IMAGE="$(make_image --name external_journal)"
  local -r JOURNAL_COPY="$CASE_DIRECTORY/journal.copy"

  run_debugfs "$IMAGE" "dump <8> $JOURNAL_COPY" > /dev/null
  assert_file_exists "$JOURNAL_COPY" "the journal was dumped out of the filesystem" || return 1

  run_ext4magic -j "$JOURNAL_COPY" -J "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Journal Super Block" "the external journal was read"
  assert_not_contains "$CAPTURED_OUTPUT" "internal Journal" "and the internal one was not"
}

function test_an_external_journal_that_is_not_a_journal_is_refused() {
  require_root || return 0
  local -r IMAGE="$(make_image --name bad_external_journal)"
  local -r NOT_A_JOURNAL="$CASE_DIRECTORY/not_a_journal"

  head -c 65536 /dev/urandom > "$NOT_A_JOURNAL"

  run_ext4magic -j "$NOT_A_JOURNAL" -J "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "it is not a journal"
  assert_contains "$CAPTURED_OUTPUT" "journal" "and the message is about the journal"
}

function test_the_filesystem_is_never_written_to() {
  require_root || return 0
  # The one promise the README makes : "ext4magic will not change the data on
  # your partition". Every mode is run against a copy of one image, and the copy
  # has to come back byte for byte identical
  local -r ORIGINAL="$(make_image --type ext3 --name never_written_original)"
  local -r WORKING_COPY="$CASE_DIRECTORY/working_copy.img"
  local -r TARGET="$(new_recovery_directory)"
  local -r WINDOW="$(wide_open_time_window)"

  cp "$ORIGINAL" "$WORKING_COPY"

  # shellcheck disable=SC2086
  run_ext4magic -S "$WORKING_COPY" > /dev/null 2>&1 || true
  # shellcheck disable=SC2086
  run_ext4magic -J "$WORKING_COPY" > /dev/null 2>&1 || true
  # shellcheck disable=SC2086
  run_ext4magic -T "$WORKING_COPY" > /dev/null 2>&1 || true
  # shellcheck disable=SC2086
  run_ext4magic -H $WINDOW "$WORKING_COPY" > /dev/null 2>&1 || true
  # shellcheck disable=SC2086
  run_ext4magic -I 2 "$WORKING_COPY" > /dev/null 2>&1 || true
  # shellcheck disable=SC2086
  run_ext4magic -B 1 "$WORKING_COPY" > /dev/null 2>&1 || true
  # shellcheck disable=SC2086
  run_ext4magic -m -d "$TARGET" $WINDOW "$WORKING_COPY" > /dev/null 2>&1 || true
  # shellcheck disable=SC2086
  run_ext4magic -M -d "$TARGET" $WINDOW "$WORKING_COPY" > /dev/null 2>&1 || true

  assert_files_identical "$ORIGINAL" "$WORKING_COPY" \
    "no mode of ext4magic may change the filesystem it was pointed at"
}

function test_a_read_only_filesystem_image_is_still_readable() {
  require_root || return 0
  # The safe way of working is on a copy with the write bit taken off it, and
  # ext4magic has to open it read only rather than ask for write access it does
  # not need
  local -r IMAGE="$(make_image --name read_only_image)"

  chmod 444 "$IMAGE"
  run_ext4magic -S "$IMAGE" || true
  chmod 644 "$IMAGE"

  assert_contains "$CAPTURED_STDOUT" "Filesystem magic number" "a read only image is read"
}

function test_a_filesystem_with_the_features_of_a_modern_ext4_is_opened() {
  require_root || return 0
  # What mke2fs turns on by default today, feature by feature, so that a
  # filesystem ext4magic cannot open is reported against the one feature that
  # did it rather than against "ext4"
  local FEATURES
  for FEATURES in "extent" "extent,64bit" "extent,metadata_csum" "extent,flex_bg" \
    "extent,dir_index" "extent,huge_file,dir_nlink,extra_isize"; do
    local IMAGE
    IMAGE="$(make_image --may-fail --features "has_journal,filetype,sparse_super,$FEATURES" \
      --name "features_$(printf '%s' "$FEATURES" | tr ',' '_')")" || {
      skip_test "mke2fs cannot build a filesystem with $FEATURES"
      return 0
    }

    run_ext4magic -S "$IMAGE" || true
    assert_contains "$CAPTURED_STDOUT" "Filesystem magic number: " \
      "a filesystem with $FEATURES is opened"
  done
}

function test_a_filesystem_whose_superblock_was_destroyed_is_reported_rather_than_guessed_at() {
  # Wiping the primary superblock is what a bad write to the start of a
  # partition does. Without -s and -n, which only an expert build has, there is
  # nothing ext4magic can do but say so
  local -r IMAGE="$(make_image --name destroyed_superblock)"

  dd if=/dev/zero of="$IMAGE" bs=1024 seek=1 count=1 conv=notrunc status=none

  run_ext4magic_with_timeout 60 -S "$IMAGE" || true

  assert_not_equals "$EXIT_CODE_OF_A_RUN_THAT_WAS_KILLED" "$CAPTURED_EXIT_CODE" \
    "it comes back rather than hanging"
  assert_contains "$CAPTURED_STDERR" "while opening filesystem" "and reports that it could not open it"
}
