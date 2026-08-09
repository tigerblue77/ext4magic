#!/bin/bash

# The journal, "-J" and "-T".
#
# The journal is where ext4magic recovers from : every old inode copy and every
# old directory block it works with comes out of it. These two reports are the
# only view a user has of what is in there, and they are also the fastest way of
# telling whether ext4magic understood the journal at all.

# The value dumpe2fs reads for a journal field, so the report can be checked
# against a second reader of the same bytes
function journal_field_from_dumpe2fs() {
  local -r IMAGE="$1"
  local -r FIELD="$2"

  dumpe2fs -h "$IMAGE" 2> /dev/null |
    sed -n "s/^${FIELD}:[[:space:]]*//p" |
    head -1 |
    sed 's/[[:space:]]*$//'
}

# The field of the journal superblock report ext4magic prints, which uses a
# leading space and a colon
function journal_report_field() {
  printf '%s\n' "$1" |
    sed -n "s/^ ${2}:[[:space:]]*//p" |
    head -1 |
    sed 's/[[:space:]]*$//'
}


function test_the_journal_report_says_which_journal_it_opened() {
  require_root || return 0
  local -r IMAGE="$(make_image --name journal_named)"

  run_ext4magic -J "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "internal Journal at Inode 8" \
    "an internal journal is named with the inode it lives on"
}

function test_the_journal_report_carries_the_journal_signature() {
  require_root || return 0
  local -r IMAGE="$(make_image --name journal_signature)"

  run_ext4magic -J "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Journal Super Block" "the report has its heading"
  assert_equals "0xc03b3998" "$(journal_report_field "$CAPTURED_OUTPUT" "Signature")" \
    "the signature every jbd2 journal carries"
}

function test_the_journal_report_carries_the_size_the_journal_was_made_with() {
  require_root || return 0
  # "-J size=" is in mebibytes, so a 8 MiB journal on a 4096 byte block
  # filesystem is 2048 blocks. Both numbers are read back
  local -r IMAGE="$(make_image --journal-megabytes 8 --block-size 4096 --size 96 --name journal_size)"

  run_ext4magic -J "$IMAGE" || true

  assert_equals "4096" "$(journal_report_field "$CAPTURED_OUTPUT" "Journal block size")" \
    "the journal's blocks are the filesystem's blocks"
  assert_equals "2048" "$(journal_report_field "$CAPTURED_OUTPUT" "Number of journal blocks")" \
    "and 8 mebibytes of them is 2048"
}

function test_the_journal_report_agrees_with_dumpe2fs_on_the_size_of_the_journal() {
  require_root || return 0
  local -r IMAGE="$(make_image --size 64 --name journal_versus_dumpe2fs)"

  run_ext4magic -J "$IMAGE" || true

  local -r JOURNAL_BLOCKS="$(journal_report_field "$CAPTURED_OUTPUT" "Number of journal blocks")"
  local -r JOURNAL_BLOCK_SIZE="$(journal_report_field "$CAPTURED_OUTPUT" "Journal block size")"
  assert_matches "$JOURNAL_BLOCKS" '^[0-9]+$' "the number of journal blocks was read" || return 1
  assert_matches "$JOURNAL_BLOCK_SIZE" '^[0-9]+$' "and the size of one" || return 1

  assert_equals "$(journal_field_from_dumpe2fs "$IMAGE" "Total journal blocks")" "$JOURNAL_BLOCKS" \
    "the two readers agree on how many blocks the journal has"
  assert_equals "$(journal_field_from_dumpe2fs "$IMAGE" "Total journal size")" \
    "$(( JOURNAL_BLOCKS * JOURNAL_BLOCK_SIZE / 1024 ))k" \
    "and therefore on how large it is"
  assert_equals "$(journal_field_from_dumpe2fs "$IMAGE" "Journal inode")" "8" \
    "on an internal journal, which is the one both of them read"
}

function test_the_journal_report_carries_the_uuid_of_the_filesystem_it_belongs_to() {
  require_root || return 0
  # An internal journal carries the filesystem's own uuid, which is how a
  # journal handed over with -j is matched to the filesystem it came from
  local -r IMAGE="$(make_image --name journal_uuid)"

  run_ext4magic -J "$IMAGE" || true

  assert_equals "$FIXED_FILESYSTEM_UUID" "$(journal_report_field "$CAPTURED_OUTPUT" "Journal UUID")" \
    "the journal belongs to this filesystem"
  assert_equals "1" "$(journal_report_field "$CAPTURED_OUTPUT" "Number of file systems using journal")" \
    "and to this one alone"
}

function test_the_journal_report_carries_the_first_transaction_it_can_replay() {
  require_root || return 0
  local -r IMAGE="$(make_image --name journal_first_transaction)"

  run_ext4magic -J "$IMAGE" || true

  assert_matches "$(journal_report_field "$CAPTURED_OUTPUT" "Sequence number of first transaction")" \
    '^[0-9]+$' "the sequence number is a number"
  assert_matches "$(journal_report_field "$CAPTURED_OUTPUT" "Journal block where the journal actually starts")" \
    '^[0-9]+$' "and so is the block it starts at"
}

function test_the_journal_report_names_the_feature_flags_of_the_journal() {
  require_root || return 0
  # These decide how the descriptor blocks are laid out, which is what
  # ext4magic has to know to read the journal at all
  local -r IMAGE="$(make_image --name journal_features)"

  run_ext4magic -J "$IMAGE" || true

  local FIELD
  for FIELD in "Compatible Features" "Incompatible features" "Read only compatible features"; do
    assert_matches "$(journal_report_field "$CAPTURED_OUTPUT" "$FIELD")" '^[0-9]+$' \
      "\"$FIELD\" is reported as a number"
  done
}

function test_the_journal_report_reads_a_journal_of_every_filesystem_type_that_has_one() {
  require_root || return 0
  local TYPE
  for TYPE in ext3 ext4; do
    local IMAGE
    IMAGE="$(make_image --type "$TYPE" --name "journal_$TYPE")"

    run_ext4magic -J "$IMAGE" || true
    assert_equals "0xc03b3998" "$(journal_report_field "$CAPTURED_OUTPUT" "Signature")" \
      "a $TYPE journal is read"
  done
}

function test_the_journal_report_reads_a_journal_of_every_block_size() {
  require_root || return 0
  local BLOCK_SIZE
  for BLOCK_SIZE in 1024 2048 4096; do
    local IMAGE
    IMAGE="$(make_image --block-size "$BLOCK_SIZE" --size 48 --name "journal_b$BLOCK_SIZE")"

    run_ext4magic -J "$IMAGE" || true
    assert_equals "$BLOCK_SIZE" "$(journal_report_field "$CAPTURED_OUTPUT" "Journal block size")" \
      "the journal of a $BLOCK_SIZE byte block filesystem"
  done
}

function test_the_journal_report_reads_a_journal_handed_over_as_a_file() {
  require_root || return 0
  # The journal dumped out with debugfs is the documented way of working on a
  # filesystem that cannot be unmounted, and it has to read the same as the
  # internal one it was copied from
  local -r IMAGE="$(make_image --name journal_from_file)"
  local -r JOURNAL_COPY="$CASE_DIRECTORY/journal.copy"

  run_ext4magic -J "$IMAGE" || true
  local -r FROM_THE_FILESYSTEM="$(printf '%s\n' "$CAPTURED_OUTPUT" | sed -n '/Journal Super Block/,$p')"

  run_debugfs "$IMAGE" "dump <8> $JOURNAL_COPY" > /dev/null
  run_ext4magic -j "$JOURNAL_COPY" -J "$IMAGE" || true
  local -r FROM_THE_FILE="$(printf '%s\n' "$CAPTURED_OUTPUT" | sed -n '/Journal Super Block/,$p')"

  assert_not_empty "$FROM_THE_FILESYSTEM" "the internal journal was read" || return 1
  assert_equals "$FROM_THE_FILESYSTEM" "$FROM_THE_FILE" \
    "a dumped copy of a journal reads exactly like the journal it came from"
}

function test_the_transaction_report_counts_the_block_copies_the_journal_holds() {
  require_root || return 0
  require_loop_mount || return 0
  # Every copy of a filesystem block the journal carries is one chance of
  # recovering something, so the count is the shortest measure of what there is
  # to work with
  local -r IMAGE="$(make_image --type ext3 --name transactions_counted)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -T "$IMAGE" || true

  assert_matches "$CAPTURED_OUTPUT" 'Found [0-9]+ copy of Filesystemblock in Journal' \
    "the report says how many copies it found"

  local -r HOW_MANY="$(printf '%s\n' "$CAPTURED_OUTPUT" |
    sed -n 's/^Found \([0-9]*\) copy of Filesystemblock in Journal$/\1/p')"
  assert_greater_than "0" "$HOW_MANY" "a filesystem that was written to has copies in its journal"
}

function test_the_transaction_report_has_a_column_for_each_of_the_three_numbers() {
  require_root || return 0
  local -r IMAGE="$(make_image --type ext3 --name transactions_columns)"

  run_ext4magic -T "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "FS-Block" "the filesystem block a copy is of"
  assert_contains "$CAPTURED_OUTPUT" "Journal" "where in the journal the copy sits"
  assert_contains "$CAPTURED_OUTPUT" "Transact" "and which transaction wrote it"
}

function test_every_block_the_transaction_report_names_is_inside_the_filesystem() {
  require_root || return 0
  require_loop_mount || return 0
  # The one property of this report that can be checked without reading the
  # journal a second time : a copy of a block that the filesystem does not have
  # is a misread descriptor, and a recovery working from it reads whatever
  # happens to be at that offset
  local -r IMAGE="$(make_image --type ext3 --size 64 --block-size 4096 --name transactions_in_range)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -S "$IMAGE" || true
  local -r BLOCK_COUNT="$(superblock_field "$CAPTURED_STDOUT" "Block count")"
  assert_not_empty "$BLOCK_COUNT" "the filesystem reports how many blocks it has" || return 1

  run_ext4magic -T "$IMAGE" || true

  local -r OUT_OF_RANGE="$(printf '%s\n' "$CAPTURED_STDOUT" |
    awk -v limit="$BLOCK_COUNT" '/^ *[0-9]+\t/ { if ($1 >= limit) print $1 }' | sort -u | head -5)"

  if [ -z "$OUT_OF_RANGE" ]; then
    pass
  else
    fail "every block named in the journal has to be one this filesystem has" \
      "the filesystem holds blocks 0 to $((BLOCK_COUNT - 1))" \
      "these were named instead: $(printf '%s' "$OUT_OF_RANGE" | tr '\n' ' ')"
  fi
}

function test_the_transactions_of_a_single_block_can_be_asked_for_on_their_own() {
  require_root || return 0
  require_loop_mount || return 0
  # "-B n -T" narrows the report to one block, which is how a user follows the
  # history of a particular piece of the filesystem
  local -r IMAGE="$(make_image --type ext3 --name transactions_of_one_block)"

  populate_and_delete "$IMAGE" || {
    fail "the image could not be filled and emptied"
    return 1
  }

  run_ext4magic -T "$IMAGE" || true
  local -r A_BLOCK_IN_THE_JOURNAL="$(printf '%s\n' "$CAPTURED_STDOUT" |
    awk '/^ *[0-9]+\t/ { if ($1 > 0) { print $1; exit } }')"
  assert_not_empty "$A_BLOCK_IN_THE_JOURNAL" "the journal holds a copy of some block" || return 1

  run_ext4magic -B "$A_BLOCK_IN_THE_JOURNAL" -T "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Transactions of Filesystemblock $A_BLOCK_IN_THE_JOURNAL" \
    "the report is about the block that was asked for"
}

function test_a_block_the_journal_holds_no_copy_of_is_reported_as_having_none() {
  require_root || return 0
  local -r IMAGE="$(make_image --type ext3 --size 64 --name transactions_of_an_untouched_block)"

  run_ext4magic -S "$IMAGE" || true
  local -r BLOCK_COUNT="$(superblock_field "$CAPTURED_STDOUT" "Block count")"
  # The last block of the filesystem, which a freshly made one has never written
  run_ext4magic -B "$((BLOCK_COUNT - 1))" -T "$IMAGE" || true

  assert_contains "$CAPTURED_OUTPUT" "Transactions of Filesystemblock $((BLOCK_COUNT - 1))" \
    "the report is about the block that was asked for"
  assert_not_contains "$CAPTURED_OUTPUT" "Segmentation" "and it comes back rather than crashing"
}
