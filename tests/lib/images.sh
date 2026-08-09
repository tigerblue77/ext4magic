#!/bin/bash

# Builders for the throwaway ext2/ext3/ext4 images the suite runs ext4magic
# against.
#
# ext4magic reads filesystems, so unlike a program driven through its command
# line it cannot be tested against a mock : the thing it parses is the on-disk
# format itself. What stands in for a mock here is e2fsprogs. Every image is
# made from scratch by mke2fs, filled through debugfs or through a real mount,
# and thrown away with the run, so the suite needs no fixture checked into the
# repository and no disk it did not create.
#
# Two tiers, because they need different privileges :
#
#   - make_image() and the debugfs helpers need nothing. They cover every mode
#     that reads the filesystem as it stands : -S, -J, -I, -B, -H, -T, and the
#     whole of the command line handling
#   - mount_image() and populate_and_delete() need root and a free loop device,
#     because only a mounted filesystem writes the journal, and the journal is
#     what ext4magic recovers from. Test cases that need one call
#     require_loop_mount first, and skip where it is not available
#
# Every test case builds its own images rather than sharing one : a mke2fs of a
# 32 mebibyte image costs a few tens of milliseconds, and a shared image would
# make the result of one test case depend on what the one before it did to it.

# Every image the suite builds gets the same UUID, so that the -S output a test
# asserts on does not change between two runs. mke2fs would otherwise draw a
# random one, which is the only field of a superblock dump that is not a
# function of the options it was made with
readonly FIXED_FILESYSTEM_UUID="0e17ac9c-1eab-4d1f-9c9a-e0a6a02e4f2e"

# Path of the directory this run's images live in
function images_directory() {
  printf '%s/images' "$TEST_TEMPORARY_DIRECTORY"
}

# Whether this run can mount a loop device, which the recipes that need a real
# journal depend on. Answered once and remembered, because the probe itself
# costs a mount
function loop_mounting_is_available() {
  local -r ANSWER_FILE="$TEST_TEMPORARY_DIRECTORY/loop_mounting_is_available"

  if [ -f "$ANSWER_FILE" ]; then
    [ "$(cat "$ANSWER_FILE")" == "yes" ]
    return $?
  fi

  local ANSWER="no"
  if [ "$(id -u)" -eq 0 ] && command -v mount > /dev/null 2>&1; then
    local -r PROBE_DIRECTORY="$TEST_TEMPORARY_DIRECTORY/loop_probe"
    mkdir -p "$PROBE_DIRECTORY/mountpoint"
    if dd if=/dev/zero of="$PROBE_DIRECTORY/probe.img" bs=1M count=8 status=none 2> /dev/null &&
      mke2fs -q -F -t ext4 "$PROBE_DIRECTORY/probe.img" > /dev/null 2>&1 &&
      mount -o loop "$PROBE_DIRECTORY/probe.img" "$PROBE_DIRECTORY/mountpoint" > /dev/null 2>&1; then
      ANSWER="yes"
      umount "$PROBE_DIRECTORY/mountpoint" > /dev/null 2>&1
    fi
    rm -rf "$PROBE_DIRECTORY"
  fi

  printf '%s' "$ANSWER" > "$ANSWER_FILE"
  [ "$ANSWER" == "yes" ]
}

# Skip the current test case unless this run can mount a loop device
# Usage : require_loop_mount || return 0
function require_loop_mount() {
  if loop_mounting_is_available; then
    return 0
  fi
  skip_test "needs root and a free loop device to write a real journal"
  return 1
}

# Build a filesystem image from scratch.
#
# Usage : IMAGE=$(make_image [option ...])
#   --type ext2|ext3|ext4   filesystem type (default ext4)
#   --size N                size in mebibytes (default 32)
#   --block-size N          1024, 2048 or 4096 (default mke2fs's own choice)
#   --inode-size N          128 or 256
#   --features LIST         passed to mke2fs -O, e.g. "^has_journal,extent"
#   --label NAME            volume label
#   --journal-megabytes N   size of the internal journal, in mebibytes, the unit
#                           mke2fs's own "-J size=" takes
#   --name NAME             file name to give the image, for readable diagnostics
#   --may-fail              the caller is asking for a combination mke2fs may
#                           refuse, and will check for itself
#
# The path of the image is printed. mke2fs's own diagnostics are kept in a file
# beside it, which make_image_failure_output reads back.
#
# An image that could not be built records a failure against the calling test
# case rather than only returning non-zero : the call sits inside a command
# substitution, so its exit status is easy to drop by accident, and a test case
# running against an image that is not there fails somewhere else entirely
function make_image() {
  local TYPE="ext4"
  local SIZE_IN_MEBIBYTES=32
  local BLOCK_SIZE=""
  local INODE_SIZE=""
  local FEATURES=""
  local LABEL=""
  local JOURNAL_MEGABYTES=""
  local NAME=""
  local MAY_FAIL=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --type) TYPE="$2"; shift 2 ;;
      --size) SIZE_IN_MEBIBYTES="$2"; shift 2 ;;
      --block-size) BLOCK_SIZE="$2"; shift 2 ;;
      --inode-size) INODE_SIZE="$2"; shift 2 ;;
      --features) FEATURES="$2"; shift 2 ;;
      --label) LABEL="$2"; shift 2 ;;
      --journal-megabytes) JOURNAL_MEGABYTES="$2"; shift 2 ;;
      --name) NAME="$2"; shift 2 ;;
      --may-fail) MAY_FAIL=true; shift ;;
      *) printf 'make_image: unknown option "%s"\n' "$1" >&2; return 1 ;;
    esac
  done

  mkdir -p "$(images_directory)"
  local -r IMAGE="$(images_directory)/${NAME:-$TYPE}_$$_${RANDOM}.img"

  declare -a MKE2FS_ARGUMENTS=(-q -F -t "$TYPE" -U "$FIXED_FILESYSTEM_UUID" -E root_owner=0:0)
  [ -n "$BLOCK_SIZE" ] && MKE2FS_ARGUMENTS+=(-b "$BLOCK_SIZE")
  [ -n "$INODE_SIZE" ] && MKE2FS_ARGUMENTS+=(-I "$INODE_SIZE")
  [ -n "$FEATURES" ] && MKE2FS_ARGUMENTS+=(-O "$FEATURES")
  [ -n "$LABEL" ] && MKE2FS_ARGUMENTS+=(-L "$LABEL")
  [ -n "$JOURNAL_MEGABYTES" ] && MKE2FS_ARGUMENTS+=(-J "size=$JOURNAL_MEGABYTES")

  if ! dd if=/dev/zero of="$IMAGE" bs=1M count="$SIZE_IN_MEBIBYTES" status=none 2> "$IMAGE.log"; then
    $MAY_FAIL || fail "the test's image could not be created" "path: [$IMAGE]"
    printf '%s' "$IMAGE"
    return 1
  fi
  if ! mke2fs "${MKE2FS_ARGUMENTS[@]}" "$IMAGE" >> "$IMAGE.log" 2>&1; then
    $MAY_FAIL || fail "the test's image could not be made into a filesystem" \
      "mke2fs ${MKE2FS_ARGUMENTS[*]}" "$(make_image_failure_output "$IMAGE")"
    printf '%s' "$IMAGE"
    return 1
  fi

  printf '%s' "$IMAGE"
}

# What mke2fs said while an image was being built, for a test case whose image
# did not come out
function make_image_failure_output() {
  cat "$1.log" 2> /dev/null
}

# A file of a given size holding bytes that are neither all the same nor
# random : a recovered copy has to be compared byte for byte, and a random file
# cannot be rebuilt to compare against
# Usage : make_local_file "$PATH" "$SIZE_IN_BYTES" ["$SEED"]
function make_local_file() {
  local -r FILE="$1"
  local -r SIZE_IN_BYTES="$2"
  local -r SEED="${3:-0}"

  mkdir -p "$(dirname "$FILE")"
  # A repeating, seeded pattern : reproducible across runs and across machines,
  # and different enough between two files that one recovered in place of the
  # other is noticed
  awk -v size="$SIZE_IN_BYTES" -v seed="$SEED" 'BEGIN {
    srand(seed);
    written = 0;
    while (written < size) {
      line = sprintf("%08d ext4magic seed=%d %s\n", written, seed, "0123456789abcdefghijklmnopqrstuvwxyz");
      if (written + length(line) > size) {
        printf "%s", substr(line, 1, size - written);
        written = size;
      } else {
        printf "%s", line;
        written += length(line);
      }
    }
  }' > "$FILE"
}

# Run a debugfs command against an image, without mounting it. Writes are only
# possible in the -w mode, which is what makes an image fillable on a machine
# that cannot mount anything
# Usage : run_debugfs "$IMAGE" "command"
function run_debugfs() {
  local -r IMAGE="$1"
  local -r COMMAND="$2"

  debugfs -w -R "$COMMAND" "$IMAGE" 2>&1
}

# Read-only debugfs, for the test cases that check what ext4magic reports
# against what the filesystem actually holds
# Usage : query_debugfs "$IMAGE" "stat <2>"
function query_debugfs() {
  local -r IMAGE="$1"
  local -r COMMAND="$2"

  debugfs -R "$COMMAND" "$IMAGE" 2> /dev/null
}

# Copy a local file into an image without mounting it
# Usage : write_file_into_image "$IMAGE" "$LOCAL_FILE" "/path/in/image"
function write_file_into_image() {
  local -r IMAGE="$1"
  local -r LOCAL_FILE="$2"
  local -r DESTINATION="$3"

  run_debugfs "$IMAGE" "write $LOCAL_FILE $DESTINATION" > /dev/null
}

# Mount an image and print its mount point. The caller unmounts with
# unmount_image, and the runner's temporary directory is removed with the run,
# so a test case that dies without unmounting leaks a mount for the length of
# the run and nothing beyond it
# Usage : MOUNT_POINT=$(mount_image "$IMAGE")
function mount_image() {
  local -r IMAGE="$1"
  local -r MOUNT_POINT="$IMAGE.mountpoint"

  mkdir -p "$MOUNT_POINT"
  # Mounted with the filesystem's own commit interval, deliberately. Shortening
  # it with "commit=1" was measured to make the recovery fixtures LESS reliable,
  # not more : every interval that elapses is another transaction, and the more
  # of them there are the sooner the journal is checkpointed and the copy the
  # recovery needs is free to be overwritten. See close_the_transaction_and_mark()
  if ! mount -o loop "$IMAGE" "$MOUNT_POINT" 2> "$IMAGE.mount.log"; then
    return 1
  fi
  printf '%s' "$MOUNT_POINT"
}

# Usage : unmount_image "$IMAGE"
function unmount_image() {
  local -r IMAGE="$1"

  sync
  umount "$IMAGE.mountpoint" 2> /dev/null
}

# Close the transaction the writes went into, and mark the time.
#
# This is the step every recovery fixture needs and the one that is easy to get
# wrong. ext4magic recovers a file from a copy of its inode taken BEFORE the
# deletion, so the writes and the deletions have to land in two different
# transactions. A sync flushes the data but does not close the transaction, so
# on a loaded machine both were carried by one -- and then there is no earlier
# copy to recover from, and the test case fails for a reason that has nothing
# to do with ext4magic.
#
# Unmounting closes it, but it is the wrong tool : a clean unmount lets the
# journal be checkpointed, and the copy the recovery is about is then free to
# be overwritten by the first transaction after the next mount. That trades one
# intermittent failure for another.
#
# What is used instead is the filesystem's own commit interval, set to a second
# by mount_image(), and waiting out two of them. The image stays mounted and the
# journal keeps everything it has.
#
# It sets two variables rather than printing one of them : a command
# substitution would run it in a subshell and $DELETION_MARK_TIME would be lost
# with it.
#
#   $DELETION_MARK_TIME  an epoch second strictly between the last write and the
#                        first deletion, which is what the -a option takes
#   $REMOUNTED_AT        the mount point to go on deleting from, unchanged
#
# Usage : close_the_transaction_and_mark "$IMAGE" || return 1
function close_the_transaction_and_mark() {
  local -r IMAGE="$1"

  sync
  sleep 3
  # A whole second either side of the mark, the inode timestamps ext4magic
  # compares having a one second resolution
  DELETION_MARK_TIME=$(date +%s)
  sleep 3

  REMOUNTED_AT="$IMAGE.mountpoint"
  export DELETION_MARK_TIME REMOUNTED_AT
  return 0
}

# The tree every recovery test case starts from, written into a mounted image
# and then deleted, which is the only way to get the journal to hold the old
# inode copies ext4magic recovers from.
#
# The originals are kept outside the image, in $ORIGINALS_DIRECTORY, so that a
# recovered file can be compared to the original byte for byte rather than only
# by its size -- a recovery that produces a file of the right name and the right
# length full of zeros is exactly the failure a size check does not see.
#
# Sets, for the caller :
#   ORIGINALS_DIRECTORY   a copy of every file that was written, before deletion
#   DELETION_MARK_TIME    an epoch second strictly between the last write and
#                         the first deletion, which is what the -a option takes
#
# The fixture is built until it holds what it is for, up to three times -- see
# populate_and_delete() below, which wraps this and explains why
#
# Usage : require_loop_mount || return 0 ; IMAGE=$(make_image) ; populate_and_delete "$IMAGE"
function build_the_deleted_tree_once() {
  local -r IMAGE="$1"

  local MOUNT_POINT
  MOUNT_POINT="$(mount_image "$IMAGE")" || return 1

  ORIGINALS_DIRECTORY="$IMAGE.originals"
  rm -rf "$ORIGINALS_DIRECTORY"
  mkdir -p "$ORIGINALS_DIRECTORY"

  mkdir -p "$MOUNT_POINT/documents/reports" "$MOUNT_POINT/pictures" "$MOUNT_POINT/keep"

  make_local_file "$ORIGINALS_DIRECTORY/documents/notes.txt" 4000 1
  make_local_file "$ORIGINALS_DIRECTORY/documents/reports/quarterly.txt" 65536 2
  make_local_file "$ORIGINALS_DIRECTORY/pictures/holiday.dat" 200000 3
  make_local_file "$ORIGINALS_DIRECTORY/keep/kept.txt" 1500 4

  local RELATIVE_PATH
  while IFS= read -r RELATIVE_PATH; do
    mkdir -p "$MOUNT_POINT/$(dirname "$RELATIVE_PATH")"
    cp "$ORIGINALS_DIRECTORY/$RELATIVE_PATH" "$MOUNT_POINT/$RELATIVE_PATH"
  done < <(cd "$ORIGINALS_DIRECTORY" && find . -type f | sed 's|^\./||')

  close_the_transaction_and_mark "$IMAGE" || return 1
  MOUNT_POINT="$REMOUNTED_AT"

  rm -f "$MOUNT_POINT/documents/notes.txt" \
    "$MOUNT_POINT/documents/reports/quarterly.txt" \
    "$MOUNT_POINT/pictures/holiday.dat"
  sync

  unmount_image "$IMAGE"

  export ORIGINALS_DIRECTORY DELETION_MARK_TIME
}

# Whether the journal kept what the fixture is for : a copy of an inode from
# before its file was deleted, AND the copy of the directory block that gives it
# back its name. Answered by recovering into a throwaway directory and looking
# for one known file under its own path, and asserting nothing.
#
# The path matters, not only the content : the test cases built on this fixture
# assert where a recovered file lands, and a run that carved the right bytes out
# under an invented name has not given them anything to assert on
function the_journal_kept_a_copy_from_before_the_deletion() {
  local -r IMAGE="$1"
  local -r PROBE_DIRECTORY="$IMAGE.precondition_probe"
  local -r CANONICAL_PATH="documents/notes.txt"

  rm -rf "$PROBE_DIRECTORY"
  mkdir -p "$PROBE_DIRECTORY"
  "$(ext4magic_binary)" -M -d "$PROBE_DIRECTORY" -a "$DELETION_MARK_TIME" "$IMAGE" \
    > /dev/null 2>&1 || true

  local FOUND=1
  if [ -f "$PROBE_DIRECTORY/$CANONICAL_PATH" ] &&
    cmp -s "$ORIGINALS_DIRECTORY/$CANONICAL_PATH" "$PROBE_DIRECTORY/$CANONICAL_PATH"; then
    FOUND=0
  fi
  rm -rf "$PROBE_DIRECTORY"
  return "$FOUND"
}

# The tree every recovery test case starts from, built until it holds what it is
# for.
#
# Whether the journal still carries a copy of an inode from before its file was
# deleted is not something a fixture can command. jbd2 decides when to
# checkpoint, and once it has, the space holding that copy is free to be
# reused. Everything that can be done from outside is done -- the writes are
# committed by a sync and separated from the deletions by an idle gap at the
# filesystem's own commit interval -- and it still does not hold every time.
#
# So the fixture checks itself, by recovering into a throwaway directory and
# looking for one known file, and builds a fresh image when it did not hold.
# That is setup, not the thing under test : what the test cases assert is what
# the recovery PRODUCES, and none of them can say anything about that from an
# image whose journal has nothing in it.
#
# Three attempts, and then a failure rather than a skip. One miss is jbd2
# checkpointing early ; three independent images all coming up empty is
# ext4magic no longer recovering anything, which is the one thing this fixture
# must not be able to hide
function populate_and_delete() {
  local -r IMAGE="$1"
  local -r TYPE="$(filesystem_type_of "$IMAGE")"
  local ATTEMPT

  # On a filesystem with extents there is nothing to wait for : a recovery comes
  # back with nothing whatever the journal kept, which is what issue #15 is
  # about and what two test cases in cases/80_listing_and_recovery.sh record.
  # Checking the precondition there would retry three times and then report a
  # failure for something already reported
  if [ "$TYPE" == "ext4" ]; then
    build_the_deleted_tree_once "$IMAGE"
    return $?
  fi

  for ATTEMPT in 1 2 3; do
    build_the_deleted_tree_once "$IMAGE" || return 1
    if the_journal_kept_a_copy_from_before_the_deletion "$IMAGE"; then
      return 0
    fi
    # A fresh filesystem, so that the next attempt is independent of this one.
    # The block and inode sizes are kept : several test cases vary them, and a
    # rebuild that reset them would quietly test something else
    mke2fs -q -F -t "$TYPE" -U "$FIXED_FILESYSTEM_UUID" -E root_owner=0:0 \
      -b "$(block_size_of "$IMAGE")" -I "$(inode_size_of "$IMAGE")" \
      "$IMAGE" > /dev/null 2>&1 || return 1
  done

  fail "the journal kept no copy from before the deletion, in three images running" \
    "each was written, synced, left idle and then emptied" \
    "three in a row means the recovery found nothing, not that one image was unlucky"
  return 1
}

# Build a fixture with the given function, until the journal has kept what the
# fixture is for.
#
# Same reasoning as populate_and_delete(), for the test cases that write their
# own tree rather than the shared one : jbd2 decides when to checkpoint, and
# once it has, the copy of the inode from before the deletion is free to be
# overwritten. Nothing outside the filesystem can command that, so the fixture
# checks itself and builds a fresh image when it did not hold.
#
# The builder is a function taking the image's path. It is called with a freshly
# made filesystem each time, and has to leave $DELETION_MARK_TIME behind, which
# close_the_transaction_and_mark() does.
#
# Three attempts, then a failure rather than a skip : one miss is jbd2
# checkpointing early, three independent images all coming up empty is the
# recovery no longer working, which this must not be able to hide
#
# Usage : build_until_recoverable "$IMAGE" "$ORIGINAL_FILE" a_builder_function || return 1
function build_until_recoverable() {
  local -r IMAGE="$1"
  local -r ORIGINAL="$2"
  local -r BUILDER="$3"
  local -r TYPE="$(filesystem_type_of "$IMAGE")"
  local -r BLOCK_SIZE="$(block_size_of "$IMAGE")"
  local -r INODE_SIZE="$(inode_size_of "$IMAGE")"
  local ATTEMPT

  for ATTEMPT in 1 2 3; do
    "$BUILDER" "$IMAGE" || return 1

    local PROBE_DIRECTORY="$IMAGE.precondition_probe"
    rm -rf "$PROBE_DIRECTORY"
    mkdir -p "$PROBE_DIRECTORY"
    "$(ext4magic_binary)" -M -d "$PROBE_DIRECTORY" -a "$DELETION_MARK_TIME" "$IMAGE" \
      > /dev/null 2>&1 || true
    if [ -n "$(recovered_file_matching "$PROBE_DIRECTORY" "$ORIGINAL")" ]; then
      rm -rf "$PROBE_DIRECTORY"
      return 0
    fi
    rm -rf "$PROBE_DIRECTORY"

    mke2fs -q -F -t "$TYPE" -U "$FIXED_FILESYSTEM_UUID" -E root_owner=0:0 \
      -b "$BLOCK_SIZE" -I "$INODE_SIZE" "$IMAGE" > /dev/null 2>&1 || return 1
  done

  fail "the journal kept no copy from before the deletion, in three images running" \
    "the file looked for was: [$ORIGINAL]" \
    "three in a row means the recovery found nothing, not that one image was unlucky"
  return 1
}

# The block size of an existing image, so that a fixture rebuilding one keeps it
function block_size_of() {
  dumpe2fs -h "$1" 2> /dev/null | sed -n 's/^Block size:[[:space:]]*//p' | head -1
}

# The inode size of an existing image, for the same reason
function inode_size_of() {
  dumpe2fs -h "$1" 2> /dev/null | sed -n 's/^Inode size:[[:space:]]*//p' | head -1
}

# The type of an existing image, so that a fixture rebuilding one keeps it
function filesystem_type_of() {
  local -r IMAGE="$1"

  if dumpe2fs -h "$IMAGE" 2> /dev/null | grep -q "has_journal"; then
    if dumpe2fs -h "$IMAGE" 2> /dev/null | grep -q "extent"; then
      printf 'ext4'
    else
      printf 'ext3'
    fi
  else
    printf 'ext2'
  fi
}

# A time window that certainly contains everything the image was built with,
# for the test cases whose subject is not the window itself. ext4magic refuses
# an "after" earlier than 1980-01-01, so the window starts well after that and
# well before any image this suite makes
function wide_open_time_window() {
  printf -- '-a %d -b %d' 1000000000 "$(($(date +%s) + 86400))"
}
