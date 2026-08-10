#!/bin/bash

# The two dumps, "-I" and "-B".
#
# They are what a user reaches for once the automatic recovery has not found
# something : read an inode, read a block, work out by hand where the file went.
# Both print raw filesystem structures, so what they say has to be right down to
# the field, and both are pointed at numbers a user typed, so what they do with
# a number that is not there matters as much as what they do with one that is.

# The value debugfs reads for a field of an inode, so the dump can be checked
# against a second reader of the same bytes
function debugfs_inode_field() {
  local -r IMAGE="$1"
  local -r INODE="$2"
  local -r FIELD="$3"

  query_debugfs "$IMAGE" "stat <$INODE>" |
    sed -n "s/.*${FIELD}: \([^ ]*\).*/\1/p" |
    head -1
}


function test_the_root_inode_is_dumped_as_a_directory() {
  require_root || return 0
  # Inode 2 is the root directory of every ext filesystem, and it is the one
  # inode that is there whatever else has happened
  local -r IMAGE="$(make_image --name inode_root)"

  run_ext4magic -I 2 "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Dump internal Inode 2" "the dump names the inode"
  assert_contains "$CAPTURED_OUTPUT" "Inode is Allocated" "the root inode is in use"
  assert_contains "$CAPTURED_OUTPUT" "Type: directory" "and it is a directory"
}

function test_the_dump_of_a_directory_lists_what_is_in_it() {
  require_root || return 0
  local -r IMAGE="$(make_image --name inode_directory_listing)"

  run_ext4magic -I 2 "$IMAGE" || true

  # One line per entry : inode number, type, mode, owner, size, time and name
  assert_has_line "$CAPTURED_OUTPUT" '^ *2 +d +755 .* \.$' "the directory holds itself"
  assert_has_line "$CAPTURED_OUTPUT" '^ *2 +d +755 .* \.\.$' "and its parent"
  assert_has_line "$CAPTURED_OUTPUT" '^ *11 +d +700 .* lost\+found$' \
    "and the directory mke2fs puts in every filesystem, on the inode it always uses"
}

function test_the_dump_carries_the_mode_the_owner_and_the_size() {
  require_root || return 0
  local -r IMAGE="$(make_image --name inode_fields)"

  run_ext4magic -I 2 "$IMAGE" || true

  assert_matches "$CAPTURED_OUTPUT" 'Mode: +0755' "the root directory's mode"
  assert_matches "$CAPTURED_OUTPUT" 'User: +0 +Group: +0' "owned by root"
  assert_matches "$CAPTURED_OUTPUT" 'Size: [0-9]+' "with a size"
  assert_matches "$CAPTURED_OUTPUT" 'Links: [0-9]+' "and a link count"
}

function test_the_dump_carries_the_four_timestamps() {
  require_root || return 0
  # ctime, atime and mtime are on every inode ; crtime only exists on the larger
  # inode, and is the one ext4magic uses to tell a file created inside the
  # window from one that merely changed in it
  local -r IMAGE="$(make_image --inode-size 256 --name inode_times)"

  run_ext4magic -I 2 "$IMAGE" || true

  local FIELD
  for FIELD in " ctime" " atime" " mtime" "crtime"; do
    assert_matches "$CAPTURED_OUTPUT" "$FIELD: [0-9]+" "\"$FIELD\" is dumped"
  done
}

function test_the_smaller_inode_has_no_creation_time_to_dump() {
  require_root || return 0
  # A 128 byte inode stops before i_crtime, so there is nothing to print. It is
  # the difference that decides whether a recovery can use the creation time
  local -r IMAGE="$(make_image --inode-size 128 --features "^metadata_csum,^64bit,^extent" \
    --name inode_small)"

  run_ext4magic -I 2 "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Dump internal Inode 2" "the inode is dumped"
  assert_not_contains "$CAPTURED_OUTPUT" "crtime" "and there is no creation time on it"
}

function test_the_dump_agrees_with_debugfs_on_the_inode_it_read() {
  require_root || return 0
  local -r IMAGE="$(make_image --name inode_versus_debugfs)"

  run_ext4magic -I 2 "$IMAGE" || true

  local -r LINK_COUNT_FROM_DEBUGFS="$(query_debugfs "$IMAGE" "stat <2>" |
    sed -n 's/.*Links: \([0-9]*\).*/\1/p' | head -1)"
  assert_not_empty "$LINK_COUNT_FROM_DEBUGFS" "debugfs read the inode too" || return 1

  assert_contains "$CAPTURED_OUTPUT" "Links: $LINK_COUNT_FROM_DEBUGFS" \
    "the two readers agree on the link count"
}

function test_the_dump_reads_an_inode_of_every_inode_size() {
  require_root || return 0
  local INODE_SIZE
  for INODE_SIZE in 128 256; do
    local IMAGE
    IMAGE="$(make_image --inode-size "$INODE_SIZE" --features "^metadata_csum,^64bit" \
      --name "inode_size_$INODE_SIZE")"

    run_ext4magic -I 2 "$IMAGE" || true
    assert_contains "$CAPTURED_OUTPUT" "Type: directory" \
      "the root inode of a $INODE_SIZE byte inode filesystem is read"
  done
}

function test_the_dump_reads_an_inode_of_every_filesystem_type() {
  require_root || return 0
  local TYPE
  for TYPE in ext2 ext3 ext4; do
    local IMAGE
    IMAGE="$(make_image --type "$TYPE" --name "inode_type_$TYPE")"

    run_ext4magic -I 2 "$IMAGE" || true
    assert_contains "$CAPTURED_OUTPUT" "Type: directory" "the root inode of a $TYPE filesystem"
    assert_contains "$CAPTURED_OUTPUT" "lost+found" "and what is in it"
  done
}

function test_an_inode_that_is_free_is_dumped_and_said_to_be_free() {
  require_root || return 0
  # This is the interesting case for a recovery : an inode nobody is using may
  # still hold the file that was deleted from it
  local -r IMAGE="$(make_image --name inode_free)"

  run_ext4magic -S "$IMAGE" || true
  local -r FIRST_INODE="$(superblock_field "$CAPTURED_STDOUT" "First inode")"
  assert_not_empty "$FIRST_INODE" "the filesystem says where its own inodes stop" || return 1

  # A little past the ones mke2fs used, so it is certainly free
  run_ext4magic -I "$((FIRST_INODE + 20))" "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Dump internal Inode $((FIRST_INODE + 20))" "the inode is dumped"
  assert_contains "$CAPTURED_OUTPUT" "Inode is Unallocated" "and reported as free"
}

function test_an_inode_past_the_end_of_the_table_is_refused() {
  require_root || return 0
  local -r IMAGE="$(make_image --name inode_out_of_range)"

  run_ext4magic -S "$IMAGE" || true
  local -r INODE_COUNT="$(superblock_field "$CAPTURED_STDOUT" "Inode count")"
  assert_not_empty "$INODE_COUNT" "the filesystem says how many inodes it has" || return 1

  run_ext4magic -I "$((INODE_COUNT + 1))" "$IMAGE" || true

  assert_equals "$EXT4MAGIC_EXIT_FAILURE" "$CAPTURED_EXIT_CODE" "there is no such inode"
  assert_contains "$CAPTURED_STDERR" "$((INODE_COUNT + 1))" "and the message names the one that was asked for"
}

function test_a_block_is_dumped_as_hexadecimal_and_as_text() {
  require_root || return 0
  # Two views of the same bytes, side by side, which is what makes a dump
  # readable : the hexadecimal for the structure, the text for the content
  local -r IMAGE="$(make_image --name block_dump)"

  run_ext4magic -B 1 "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Dump Filesystemblock" "the dump names the block"
  assert_matches "$CAPTURED_OUTPUT" '0000:( +[0-9a-f]{2}){16} ' "sixteen bytes to a line"
  assert_matches "$CAPTURED_OUTPUT" '0010:( +[0-9a-f]{2}){16} ' "with the offset of each line in front"
}

function test_a_block_dump_says_whether_the_block_is_in_use() {
  require_root || return 0
  # Whether a block is allocated is what says if the data in it still belongs to
  # a live file or is waiting to be overwritten
  local -r IMAGE="$(make_image --size 64 --name block_status)"

  run_ext4magic -B 1 "$IMAGE" || true
  assert_contains "$CAPTURED_OUTPUT" "Block is Allocated" "a block of the filesystem's own metadata"

  run_ext4magic -S "$IMAGE" || true
  local -r BLOCK_COUNT="$(superblock_field "$CAPTURED_STDOUT" "Block count")"
  run_ext4magic -B "$((BLOCK_COUNT - 1))" "$IMAGE" || true
  assert_contains "$CAPTURED_OUTPUT" "Block is Unallocated" "and the last block of an empty filesystem"
}

function test_the_hexadecimal_dump_can_be_asked_for_in_words_instead_of_bytes() {
  require_root || return 0
  # "-x" prints four byte words, which is how the on-disk structures are
  # actually laid out : an inode's fields line up with the columns
  local -r IMAGE="$(make_image --name block_dump_words)"

  run_ext4magic -B 1 -x "$IMAGE" || true

  assert_matches "$CAPTURED_OUTPUT" '0000:( +[0-9a-f]{8}){4} ' "four words to a line"
  assert_not_matches "$CAPTURED_OUTPUT" '0000:( +[0-9a-f]{2}){16} ' "and not sixteen bytes"
}

function test_the_two_hexadecimal_formats_describe_the_same_bytes() {
  require_root || return 0
  # The word format is the byte format read little endian, so the two have to
  # agree byte for byte. They are produced by two different code paths
  local -r IMAGE="$(make_image --name block_dump_formats_agree)"

  run_ext4magic -B 1 "$IMAGE" || true
  local -r AS_BYTES="$(printf '%s\n' "$CAPTURED_STDOUT" |
    sed -n 's/^ *0000: *\(\([0-9a-f]\{2\} \)\{16\}\).*/\1/p' | head -1 | tr -d ' ')"

  run_ext4magic -B 1 -x "$IMAGE" || true
  local -r AS_WORDS="$(printf '%s\n' "$CAPTURED_STDOUT" |
    sed -n 's/^ *0000: *\(\([0-9a-f]\{8\} \)\{4\}\).*/\1/p' | head -1 | tr -d ' ')"

  assert_not_empty "$AS_BYTES" "the byte format produced a first line" || return 1
  assert_not_empty "$AS_WORDS" "and so did the word format" || return 1

  # Each word, byte swapped, is the four bytes it stands for
  local REBUILT="" INDEX
  for ((INDEX = 0; INDEX < 32; INDEX += 8)); do
    local WORD="${AS_WORDS:INDEX:8}"
    REBUILT="$REBUILT${WORD:6:2}${WORD:4:2}${WORD:2:2}${WORD:0:2}"
  done

  assert_equals "$AS_BYTES" "$REBUILT" "the same sixteen bytes, read the two ways"
}

function test_a_block_past_the_end_of_the_filesystem_is_reported_rather_than_read() {
  require_root || return 0
  local -r IMAGE="$(make_image --size 32 --name block_out_of_range)"

  run_ext4magic -S "$IMAGE" || true
  local -r BLOCK_COUNT="$(superblock_field "$CAPTURED_STDOUT" "Block count")"
  assert_not_empty "$BLOCK_COUNT" "the filesystem says how many blocks it has" || return 1

  run_ext4magic_with_timeout 60 -B "$((BLOCK_COUNT + 1000))" "$IMAGE" || true

  assert_not_equals "$EXIT_CODE_OF_A_RUN_THAT_WAS_KILLED" "$CAPTURED_EXIT_CODE" \
    "it comes back rather than reading past the end for ever"
  assert_not_contains "$CAPTURED_OUTPUT" "Segmentation fault" "and it does not crash"
}

function test_the_dump_of_one_inode_is_the_same_from_one_run_to_the_next() {
  require_root || return 0
  local -r IMAGE="$(make_image --name inode_repeatable)"

  run_ext4magic -I 2 "$IMAGE" || true
  local -r FIRST_READ="$CAPTURED_STDOUT"
  run_ext4magic -I 2 "$IMAGE" || true

  assert_not_empty "$FIRST_READ" "the dump was produced" || return 1
  assert_equals "$FIRST_READ" "$CAPTURED_STDOUT" "and it does not change between two reads"
}
