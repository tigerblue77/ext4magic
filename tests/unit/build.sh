#!/bin/bash

# Build the unit test binary.
#
# The translation units under test are compiled from src/ rather than taken from
# the objects "make" produced, so that the unit tests do not depend on how the
# program happened to be built (automake renames its objects when a target
# carries its own CFLAGS, and that name is not part of anything's contract).
# -D_FILE_OFFSET_BITS=64 is repeated from src/Makefile.am because it changes the
# size of off_t, and therefore the layout of what these functions are handed :
# building the tests without it would test a different program.
#
# Usage : tests/unit/build.sh <output binary>
# It prints the compiler's own diagnostics on failure and nothing on success.

set -u

UNIT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIRECTORY/../.." && pwd)"
SOURCE_DIRECTORY="$REPO_ROOT/src"
OUTPUT_BINARY="${1:-$UNIT_DIRECTORY/unit_tests}"

# The parts of ext4magic these tests link. Everything here is reachable without
# an open filesystem ; the rest of the program needs one, and is covered by the
# shell suite against real images instead
declare -a SOURCES_UNDER_TEST=(
  "$SOURCE_DIRECTORY/util.c"
  "$SOURCE_DIRECTORY/ring_buf.c"
  "$SOURCE_DIRECTORY/dir_list.c"
  "$SOURCE_DIRECTORY/extent_db.c"
  "$SOURCE_DIRECTORY/hard_link_stack.c"
  "$SOURCE_DIRECTORY/file_type.c"
)

declare -a TEST_SOURCES=()
while IFS= read -r TEST_SOURCE; do
  TEST_SOURCES+=("$TEST_SOURCE")
done < <(find "$UNIT_DIRECTORY" -maxdepth 1 -name '*.c' -type f | sort)

if [ "${#TEST_SOURCES[@]}" -eq 0 ]; then
  printf 'No unit test source found in %s\n' "$UNIT_DIRECTORY" >&2
  exit 1
fi

declare -a COMPILER_FLAGS=(
  -std=gnu99
  -g
  -O1
  -D_FILE_OFFSET_BITS=64
  -I"$SOURCE_DIRECTORY"
  -I"$UNIT_DIRECTORY"
)

# config.h only ever guards optional headers here, so the tests build without
# it. When ./configure has produced one, it is used, so that the tests compile
# under exactly the conditions the program does
if [ -f "$REPO_ROOT/config.h" ]; then
  COMPILER_FLAGS+=(-DHAVE_CONFIG_H -I"$REPO_ROOT")
fi

# Warnings the code under test already emits are not this script's business,
# but a warning coming from a test source is a test bug, and is reported
COMPILER_FLAGS+=(-Wall -Wno-unused-result)

mkdir -p "$(dirname "$OUTPUT_BINARY")" || exit 1

exec "${CC:-gcc}" "${COMPILER_FLAGS[@]}" \
  "${SOURCES_UNDER_TEST[@]}" "${TEST_SOURCES[@]}" \
  -o "$OUTPUT_BINARY" \
  -lext2fs -le2p -luuid -lblkid -lmagic -lz -lbz2
