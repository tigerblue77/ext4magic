#!/bin/bash

# The superblock report, "-S".
#
# It is the first thing anyone runs on a filesystem they are trying to save,
# because it says whether the thing is readable at all and what it is. Every
# field it prints is read straight out of the superblock, so this file checks
# the report against filesystems whose properties the suite chose itself, and
# against what e2fsprogs says about the same image.

# The value dumpe2fs reads for a field, so the report can be checked against a
# second reader of the same bytes rather than against a number written here
function dumpe2fs_field() {
  local -r IMAGE="$1"
  local -r FIELD="$2"

  dumpe2fs -h "$IMAGE" 2> /dev/null |
    sed -n "s/^${FIELD}:[[:space:]]*//p" |
    head -1 |
    sed 's/[[:space:]]*$//'
}


function test_the_superblock_report_names_the_filesystem_it_read() {
  require_root || return 0
  local -r IMAGE="$(make_image --name superblock_named)"

  run_ext4magic -S "$IMAGE" || true

  assert_contains "$CAPTURED_STDOUT" "Filesystem in use: $IMAGE" \
    "the report says which filesystem it is about"
}

function test_the_superblock_report_carries_the_ext_magic_number() {
  require_root || return 0
  local -r IMAGE="$(make_image --name superblock_magic)"

  run_ext4magic -S "$IMAGE" || true

  assert_equals "0xEF53" "$(superblock_field "$CAPTURED_STDOUT" "Filesystem magic number")" \
    "the magic number every ext filesystem carries"
}

function test_the_superblock_report_agrees_with_dumpe2fs_on_every_size_and_count() {
  require_root || return 0
  # Two independent readers of the same bytes. Anything they disagree on is a
  # misread by one of them, and it is worth knowing which fields those are
  local -r IMAGE="$(make_image --size 64 --name superblock_versus_dumpe2fs)"
  local FIELD
  local EXPECTED ACTUAL

  run_ext4magic -S "$IMAGE" || true

  for FIELD in "Inode count" "Block count" "Reserved block count" "Free blocks" \
    "Free inodes" "First block" "Block size" "Fragment size" \
    "Blocks per group" "Fragments per group" "Inodes per group" \
    "Inode size" "Filesystem UUID" "Filesystem state" "Errors behavior" \
    "Filesystem OS type" "Mount count" "Maximum mount count" "First inode"; do
    EXPECTED="$(dumpe2fs_field "$IMAGE" "$FIELD")"
    ACTUAL="$(superblock_field "$CAPTURED_STDOUT" "$FIELD")"
    [ -z "$EXPECTED" ] && continue
    assert_equals "$EXPECTED" "$ACTUAL" "\"$FIELD\" should be read the same way by both"
  done
}

function test_the_superblock_report_carries_the_volume_label_it_was_made_with() {
  require_root || return 0
  local -r IMAGE="$(make_image --label "recovery-test" --name superblock_label)"

  run_ext4magic -S "$IMAGE" || true

  assert_equals "recovery-test" "$(superblock_field "$CAPTURED_STDOUT" "Filesystem volume name")" \
    "the label is what identifies a partition to its owner"
}

function test_a_filesystem_with_no_label_is_reported_as_having_none() {
  require_root || return 0
  local -r IMAGE="$(make_image --name superblock_no_label)"

  run_ext4magic -S "$IMAGE" || true

  assert_equals "<none>" "$(superblock_field "$CAPTURED_STDOUT" "Filesystem volume name")" \
    "an empty label is reported as such rather than as an empty line"
}

function test_the_superblock_report_carries_the_uuid() {
  require_root || return 0
  # Every image the suite builds is given the same uuid, so this also says the
  # field is read from the superblock rather than generated
  local -r IMAGE="$(make_image --name superblock_uuid)"

  run_ext4magic -S "$IMAGE" || true

  assert_equals "$FIXED_FILESYSTEM_UUID" "$(superblock_field "$CAPTURED_STDOUT" "Filesystem UUID")" \
    "the uuid the filesystem was made with"
}

function test_the_superblock_report_lists_the_features_the_filesystem_was_made_with() {
  require_root || return 0
  # The feature list decides which code paths ext4magic takes, so it is the one
  # line of this report a reader is meant to act on
  local -r EXT3_IMAGE="$(make_image --type ext3 --name superblock_features_ext3)"
  local -r EXT4_IMAGE="$(make_image --type ext4 --name superblock_features_ext4)"

  run_ext4magic -S "$EXT3_IMAGE" || true
  local -r EXT3_FEATURES="$(superblock_field "$CAPTURED_STDOUT" "Filesystem features")"
  assert_contains "$EXT3_FEATURES" "has_journal" "an ext3 filesystem has a journal"
  assert_not_contains "$EXT3_FEATURES" "extent" "and no extents"

  run_ext4magic -S "$EXT4_IMAGE" || true
  local -r EXT4_FEATURES="$(superblock_field "$CAPTURED_STDOUT" "Filesystem features")"
  assert_contains "$EXT4_FEATURES" "has_journal" "an ext4 filesystem has a journal"
  assert_contains "$EXT4_FEATURES" "extent" "and extents"
}

function test_the_superblock_report_reads_a_filesystem_of_every_type() {
  require_root || return 0
  local TYPE
  for TYPE in ext2 ext3 ext4; do
    local IMAGE
    IMAGE="$(make_image --type "$TYPE" --name "superblock_$TYPE")"

    run_ext4magic -S "$IMAGE" || true
    assert_equals "0xEF53" "$(superblock_field "$CAPTURED_STDOUT" "Filesystem magic number")" \
      "a $TYPE superblock is read"
    assert_not_empty "$(superblock_field "$CAPTURED_STDOUT" "Inode count")" \
      "and its inode count is reported"
  done
}

function test_the_superblock_report_reads_a_filesystem_of_every_block_size() {
  require_root || return 0
  local BLOCK_SIZE
  for BLOCK_SIZE in 1024 2048 4096; do
    local IMAGE
    IMAGE="$(make_image --block-size "$BLOCK_SIZE" --size 48 --name "superblock_b$BLOCK_SIZE")"

    run_ext4magic -S "$IMAGE" || true
    assert_equals "$BLOCK_SIZE" "$(superblock_field "$CAPTURED_STDOUT" "Block size")" \
      "the block size is read"
    assert_equals "$(dumpe2fs_field "$IMAGE" "Block count")" \
      "$(superblock_field "$CAPTURED_STDOUT" "Block count")" \
      "and so is the block count that follows from it"
  done
}

function test_the_block_count_matches_the_size_of_the_image_it_was_made_in() {
  require_root || return 0
  # A block count that does not match the image is how a truncated or wrongly
  # copied image shows itself, so it is worth being able to trust
  local -r IMAGE="$(make_image --size 64 --block-size 4096 --name superblock_block_count)"

  run_ext4magic -S "$IMAGE" || true

  assert_equals "16384" "$(superblock_field "$CAPTURED_STDOUT" "Block count")" \
    "64 mebibytes of 4096 byte blocks"
}

function test_the_superblock_report_says_whether_the_filesystem_was_cleanly_unmounted() {
  require_root || return 0
  require_loop_mount || return 0
  # The state is what tells a user whether the journal still holds work that was
  # never written back, which changes what a recovery can expect to find
  local -r IMAGE="$(make_image --name superblock_state)"

  run_ext4magic -S "$IMAGE" || true
  assert_equals "clean" "$(superblock_field "$CAPTURED_STDOUT" "Filesystem state")" \
    "a filesystem that was never mounted is clean"

  local MOUNT_POINT
  MOUNT_POINT="$(mount_image "$IMAGE")" || {
    fail "the image could not be mounted"
    return 1
  }
  printf 'something\n' > "$MOUNT_POINT/a_file"
  sync
  unmount_image "$IMAGE"

  run_ext4magic -S "$IMAGE" || true
  assert_equals "clean" "$(superblock_field "$CAPTURED_STDOUT" "Filesystem state")" \
    "and so is one that was unmounted properly"
  assert_not_empty "$(superblock_field "$CAPTURED_STDOUT" "Last mounted on")" \
    "which now has a last mount point"
}

function test_the_superblock_report_carries_the_times_the_filesystem_records() {
  require_root || return 0
  local -r IMAGE="$(make_image --name superblock_times)"

  run_ext4magic -S "$IMAGE" || true

  local FIELD
  for FIELD in "Filesystem created" "Last write time" "Last checked"; do
    assert_matches "$(superblock_field "$CAPTURED_STDOUT" "$FIELD")" \
      '[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]+ [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}' \
      "\"$FIELD\" is printed as a date"
  done
}

function test_the_superblock_report_carries_the_journal_inode_when_there_is_a_journal() {
  require_root || return 0
  local -r WITH_JOURNAL="$(make_image --type ext4 --name superblock_journal_inode)"
  local -r WITHOUT_JOURNAL="$(make_image --type ext2 --name superblock_no_journal_inode)"

  run_ext4magic -S "$WITH_JOURNAL" || true
  assert_equals "8" "$(superblock_field "$CAPTURED_STDOUT" "Journal inode")" \
    "the journal always lives on inode 8"

  run_ext4magic -S "$WITHOUT_JOURNAL" || true
  assert_empty "$(superblock_field "$CAPTURED_STDOUT" "Journal inode")" \
    "and a filesystem without one reports no journal inode"
}

function test_the_superblock_report_is_the_same_from_one_run_to_the_next() {
  require_root || return 0
  # Nothing in it may come from the run itself : two reads of one unchanged
  # image have to produce the same bytes, or the report is describing something
  # other than the filesystem
  local -r IMAGE="$(make_image --name superblock_repeatable)"

  run_ext4magic -S "$IMAGE" || true
  local -r FIRST_READ="$CAPTURED_STDOUT"
  run_ext4magic -S "$IMAGE" || true

  assert_not_empty "$FIRST_READ" "the report was produced" || return 1
  assert_equals "$FIRST_READ" "$CAPTURED_STDOUT" "and it does not change between two reads"
}

function test_the_superblock_report_goes_to_stdout_so_it_can_be_redirected() {
  require_root || return 0
  # A user saving the state of a filesystem before touching it redirects this
  # report to a file. Anything of it on stderr would be lost
  local -r IMAGE="$(make_image --name superblock_stream)"

  run_ext4magic -S "$IMAGE" || true

  assert_contains "$CAPTURED_STDOUT" "Filesystem magic number" "the report is on stdout"
  assert_empty "$CAPTURED_STDERR" "and nothing was written to stderr"
}
