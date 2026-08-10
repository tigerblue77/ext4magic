/***************************************************************************
 *   The extent cache of src/extent_db.c.                                  *
 *                                                                         *
 *   An ext4 file describes where its data is with a tree of extents. When  *
 *   the file is deleted that tree is taken apart, and the ext4 magic scan  *
 *   puts it back together by collecting every extent block it can still    *
 *   find and asking this cache which of them fit together. What it answers *
 *   decides which blocks are written into the recovered file, so an extent *
 *   that is merged when it should not be, or one that cannot be found      *
 *   again, is data lost or data invented.                                  *
 *                                                                         *
 *   extent_db_add() with a non-zero flag reads the extent block off the    *
 *   filesystem. These tests use flag 0, which is the form that computes    *
 *   the entry from what it is given, and is what magic_block_scan4() uses  *
 *   for every extent it has already read.                                  *
 ***************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ext2fs/ext2fs.h>

#include "unit_tests.h"
#include "extent_db.h"

/* The open filesystem, defined by tests/unit/stubs.c. extent_db.c reads its
   block size to turn a length in blocks into a length in bytes */
extern ext2_filsys current_fs;

static void open_a_filesystem_with_block_size(unsigned int block_size) {
  static struct struct_ext2_filsys filesystem;

  memset(&filesystem, 0, sizeof(filesystem));
  filesystem.blocksize = block_size;
  current_fs = &filesystem;
}

/* Build one extent the way magic_block_scan4() does : a run of "length" blocks
   starting at physical block "physical_start", holding the logical blocks
   "logical_start" to "logical_end" of the file */
static struct extent_area *an_extent(__u16 depth, blk_t logical_start, blk_t logical_end,
                                     blk_t physical_start, __u16 length, blk_t found_in_block) {
  struct extent_area *area = new_extent_area();

  if (area == NULL) {
    return NULL;
  }
  area->depth = depth;
  area->l_start = logical_start;
  area->l_end = logical_end;
  area->start_b = physical_start;
  area->len = length;
  area->blocknr = found_in_block;
  return area;
}


UNIT_TEST(test_a_new_extent_area_starts_wholly_zeroed) {
  /* Every field is read before it is written somewhere in the scan, so the
     allocation has to come back clean rather than carrying the last one's
     numbers */
  struct extent_area *area = new_extent_area();

  ASSERT_NOT_NULL(area, "an extent area should have been allocated");
  if (area == NULL) {
    return;
  }

  ASSERT_EQ_ULONG(0UL, (unsigned long) area->blocknr, "the block it was found in");
  ASSERT_EQ_ULONG(0UL, (unsigned long) area->depth, "its depth in the extent tree");
  ASSERT_EQ_ULONG(0UL, (unsigned long) area->l_start, "the first logical block");
  ASSERT_EQ_ULONG(0UL, (unsigned long) area->l_end, "the last logical block");
  ASSERT_EQ_ULONG(0UL, (unsigned long) area->start_b, "the first physical block");
  ASSERT_EQ_ULONG(0UL, (unsigned long) area->end_b, "the last physical block");
  ASSERT_EQ_ULONG(0UL, (unsigned long) area->len, "the length");
  ASSERT_EQ_ULONG(0UL, (unsigned long) area->size, "the size in bytes");
  ASSERT_EQ_ULONG(0UL, (unsigned long) area->b_count, "and the block count");

  free(area);
}

UNIT_TEST(test_a_new_extent_database_is_empty) {
  struct extent_db_t *database;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);

  ASSERT_NOT_NULL(database, "a database should have been allocated");
  if (database == NULL) {
    return;
  }
  ASSERT_EQ_ULONG(0UL, (unsigned long) database->count, "it holds no extent");
  ASSERT_EQ_ULONG(0UL, (unsigned long) database->max_depth, "and knows of no depth yet");

  extent_db_clear(database);
}

UNIT_TEST(test_adding_an_extent_computes_the_range_of_blocks_it_covers) {
  /* The scan gives the first block and the length ; the last block and the size
     in bytes are what the recovery reads back to know how much to write */
  struct extent_db_t *database;
  struct extent_area *area;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  area = an_extent(0, 0, 9, 1000, 10, 900);
  ASSERT_EQ_INT(1, extent_db_add(database, area, 0), "the first extent is counted");
  ASSERT_EQ_ULONG(1009UL, (unsigned long) area->end_b, "ten blocks from 1000 end at 1009");
  ASSERT_EQ_ULONG(40960UL, (unsigned long) area->size, "which is ten 4096 byte blocks");
  ASSERT_EQ_ULONG(1UL, (unsigned long) database->count, "and the database holds one extent");

  extent_db_clear(database);
}

UNIT_TEST(test_the_size_of_an_extent_follows_the_block_size_of_the_filesystem) {
  unsigned int block_size;

  for (block_size = 1024; block_size <= 4096; block_size *= 2) {
    struct extent_db_t *database;
    struct extent_area *area;

    open_a_filesystem_with_block_size(block_size);
    database = extent_db_init(NULL);
    if (database == NULL) {
      FAIL("a database should have been allocated");
      return;
    }

    area = an_extent(0, 0, 7, 2000, 8, 1900);
    extent_db_add(database, area, 0);
    ASSERT_EQ_ULONG((unsigned long) (8 * block_size), (unsigned long) area->size,
                    "eight blocks of the filesystem's own block size");

    extent_db_clear(database);
  }
}

UNIT_TEST(test_an_extent_of_the_largest_length_ext4_allows_does_not_overflow_its_size) {
  /* An ext4 extent covers up to 32768 blocks, and on a 4k filesystem that is
     134 megabytes. The size is a 64 bit field and the multiplication is cast to
     one, which is what keeps a large extent from wrapping */
  struct extent_db_t *database;
  struct extent_area *area;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  area = an_extent(0, 0, 32767, 100000, 32768, 99000);
  extent_db_add(database, area, 0);

  ASSERT_EQ_ULONG(134217728UL, (unsigned long) area->size, "32768 blocks of 4096 bytes");
  ASSERT_EQ_ULONG(132767UL, (unsigned long) area->end_b, "and the last block of the run");

  extent_db_clear(database);
}

UNIT_TEST(test_two_extents_that_are_next_to_each_other_on_disk_are_merged) {
  /* One run of blocks split across two extent records is one run : merging them
     is what lets the recovery write it in one piece. The second extent has to
     start at a logical block other than zero, which is what says it is a
     continuation rather than the start of another file */
  struct extent_db_t *database;
  struct extent_area *first;
  struct extent_area *second;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  first = an_extent(0, 0, 9, 1000, 10, 900);
  extent_db_add(database, first, 0);
  second = an_extent(0, 10, 14, 1010, 5, 900);
  extent_db_add(database, second, 0);

  ASSERT_EQ_ULONG(1UL, (unsigned long) database->count, "the two became one entry");
  ASSERT_EQ_ULONG(15UL, (unsigned long) first->len, "fifteen blocks in total");
  ASSERT_EQ_ULONG(1014UL, (unsigned long) first->end_b, "ending at the second extent's last block");
  ASSERT_EQ_ULONG(61440UL, (unsigned long) first->size, "and fifteen blocks worth of bytes");

  extent_db_clear(database);
}

UNIT_TEST(test_two_extents_with_a_gap_between_them_are_kept_apart) {
  /* A gap means the file is fragmented, or that these are two different files.
     Either way the blocks in between are not this file's, and merging would
     write them into it */
  struct extent_db_t *database;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  extent_db_add(database, an_extent(0, 0, 9, 1000, 10, 900), 0);
  extent_db_add(database, an_extent(0, 10, 14, 2000, 5, 900), 0);

  ASSERT_EQ_ULONG(2UL, (unsigned long) database->count, "they stay two entries");

  extent_db_clear(database);
}

UNIT_TEST(test_an_extent_starting_the_file_is_never_merged_into_the_one_before_it) {
  /* Logical block zero is the start of a file. However well it lines up with
     what came before, it belongs to another file, and merging the two would
     produce one recovered file holding both */
  struct extent_db_t *database;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  extent_db_add(database, an_extent(0, 0, 9, 1000, 10, 900), 0);
  /* Physically adjacent, but it is another file's first extent */
  extent_db_add(database, an_extent(0, 0, 4, 1010, 5, 901), 0);

  ASSERT_EQ_ULONG(2UL, (unsigned long) database->count,
                  "the second file's first extent stayed its own entry");

  extent_db_clear(database);
}

UNIT_TEST(test_a_run_split_into_many_pieces_is_merged_back_into_one) {
  struct extent_db_t *database;
  struct extent_area *first;
  int piece;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  first = an_extent(0, 0, 3, 5000, 4, 4900);
  extent_db_add(database, first, 0);
  for (piece = 1; piece < 20; piece++) {
    extent_db_add(database,
                  an_extent(0, (blk_t) (piece * 4), (blk_t) (piece * 4 + 3),
                            (blk_t) (5000 + piece * 4), 4, 4900),
                  0);
  }

  ASSERT_EQ_ULONG(1UL, (unsigned long) database->count, "twenty pieces became one entry");
  ASSERT_EQ_ULONG(80UL, (unsigned long) first->len, "eighty blocks in total");
  ASSERT_EQ_ULONG(5079UL, (unsigned long) first->end_b, "ending where the last piece ends");

  extent_db_clear(database);
}

UNIT_TEST(test_the_database_remembers_the_deepest_extent_tree_it_was_shown) {
  /* The lookup starts at the deepest level and works its way down, so the depth
     the database reports is where every search begins */
  struct extent_db_t *database;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  extent_db_add(database, an_extent(0, 0, 9, 1000, 10, 900), 0);
  ASSERT_EQ_ULONG(0UL, (unsigned long) database->max_depth, "a leaf extent alone is depth zero");

  extent_db_add(database, an_extent(2, 100, 199, 3000, 100, 2900), 0);
  ASSERT_EQ_ULONG(2UL, (unsigned long) database->max_depth, "an index two levels up raises it");

  extent_db_add(database, an_extent(1, 200, 299, 4000, 100, 3900), 0);
  ASSERT_EQ_ULONG(2UL, (unsigned long) database->max_depth, "a shallower one does not lower it again");

  extent_db_clear(database);
}

UNIT_TEST(test_an_extent_is_found_again_by_the_logical_block_it_starts_at) {
  /* This is the lookup the ext4 scan walks a file with : "what covers the file
     from this logical block on" */
  struct extent_db_t *database;
  struct extent_area found;
  __u32 last_logical_block;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  extent_db_add(database, an_extent(0, 0, 9, 1000, 10, 900), 0);
  extent_db_add(database, an_extent(0, 10, 24, 5000, 15, 900), 0);

  memset(&found, 0, sizeof(found));
  last_logical_block = extentd_db_find(database, 10, &found);

  ASSERT_EQ_ULONG(24UL, (unsigned long) last_logical_block, "it covers up to logical block 24");
  ASSERT_EQ_ULONG(10UL, (unsigned long) found.l_start, "and starts at the one that was asked for");
  ASSERT_EQ_ULONG(5000UL, (unsigned long) found.start_b, "at that physical block");
  ASSERT_EQ_ULONG(15UL, (unsigned long) found.len, "for that many blocks");

  extent_db_clear(database);
}

UNIT_TEST(test_a_logical_block_no_extent_starts_at_is_not_found) {
  struct extent_db_t *database;
  struct extent_area found;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  extent_db_add(database, an_extent(0, 10, 24, 5000, 15, 900), 0);

  memset(&found, 0, sizeof(found));
  ASSERT_EQ_ULONG(0UL, (unsigned long) extentd_db_find(database, 50, &found),
                  "nothing starts at logical block 50");

  extent_db_clear(database);
}

UNIT_TEST(test_the_lookup_prefers_the_deepest_level_that_starts_where_it_was_asked) {
  /* Two records may describe the same logical block, one an index and one the
     leaf under it. The deeper one is the one holding real blocks */
  struct extent_db_t *database;
  struct extent_area found;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  extent_db_add(database, an_extent(0, 32, 63, 7000, 32, 6900), 0);
  extent_db_add(database, an_extent(1, 32, 95, 8000, 64, 6900), 0);

  memset(&found, 0, sizeof(found));
  ASSERT_EQ_ULONG(95UL, (unsigned long) extentd_db_find(database, 32, &found),
                  "the deeper record is the one answered with");
  ASSERT_EQ_ULONG(1UL, (unsigned long) found.depth, "and it is the one at depth 1");

  extent_db_clear(database);
}

UNIT_TEST(test_deleting_an_extent_by_the_block_it_was_found_in_removes_it) {
  /* The scan deletes an extent block from the cache once it has followed it, so
     that the same block is not walked twice */
  struct extent_db_t *database;
  struct extent_area found;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  extent_db_add(database, an_extent(0, 0, 9, 1000, 10, 900), 0);
  extent_db_add(database, an_extent(0, 20, 29, 2000, 10, 901), 0);

  ASSERT_EQ_INT(1, extent_db_del(database, 901), "the second extent is deleted");
  ASSERT_EQ_ULONG(1UL, (unsigned long) database->count, "and the database holds one less");

  memset(&found, 0, sizeof(found));
  ASSERT_EQ_ULONG(0UL, (unsigned long) extentd_db_find(database, 20, &found),
                  "it cannot be found again");
  memset(&found, 0, sizeof(found));
  ASSERT_EQ_ULONG(9UL, (unsigned long) extentd_db_find(database, 0, &found),
                  "while the one that was kept still can");

  extent_db_clear(database);
}

UNIT_TEST(test_deleting_a_block_the_database_does_not_hold_reports_nothing_was_deleted) {
  struct extent_db_t *database;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  extent_db_add(database, an_extent(0, 0, 9, 1000, 10, 900), 0);

  ASSERT_EQ_INT(0, extent_db_del(database, 12345), "a block that is not there");
  ASSERT_EQ_ULONG(1UL, (unsigned long) database->count, "and nothing was removed");

  extent_db_clear(database);
}

UNIT_TEST(test_deleting_from_an_empty_database_reports_nothing_was_deleted) {
  struct extent_db_t *database;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  ASSERT_EQ_INT(0, extent_db_del(database, 900), "there is nothing to delete");
  ASSERT_EQ_ULONG(0UL, (unsigned long) database->count, "and the count stays at zero");

  extent_db_clear(database);
}

UNIT_TEST(test_deleting_the_first_extent_leaves_the_rest_reachable) {
  /* The first entry is the one the header points at, so removing it has to
     rewrite the header's own link. A list walked from a stale head would report
     the deleted extent for ever */
  struct extent_db_t *database;
  struct extent_area found;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  extent_db_add(database, an_extent(0, 0, 9, 1000, 10, 900), 0);
  extent_db_add(database, an_extent(0, 20, 29, 2000, 10, 901), 0);
  extent_db_add(database, an_extent(0, 40, 49, 3000, 10, 902), 0);

  ASSERT_EQ_INT(1, extent_db_del(database, 900), "the first extent is deleted");
  ASSERT_EQ_ULONG(2UL, (unsigned long) database->count, "two are left");

  memset(&found, 0, sizeof(found));
  ASSERT_EQ_ULONG(29UL, (unsigned long) extentd_db_find(database, 20, &found), "the second is still there");
  memset(&found, 0, sizeof(found));
  ASSERT_EQ_ULONG(49UL, (unsigned long) extentd_db_find(database, 40, &found), "and so is the third");

  extent_db_clear(database);
}

UNIT_TEST(test_every_extent_can_be_deleted_one_after_the_other) {
  struct extent_db_t *database;
  int index;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  for (index = 0; index < 10; index++) {
    extent_db_add(database,
                  an_extent(0, (blk_t) (index * 100), (blk_t) (index * 100 + 9),
                            (blk_t) (1000 + index * 100), 10, (blk_t) (900 + index)),
                  0);
  }
  ASSERT_EQ_ULONG(10UL, (unsigned long) database->count, "ten extents were added");

  for (index = 0; index < 10; index++) {
    ASSERT_EQ_INT(1, extent_db_del(database, (blk_t) (900 + index)), "each one is deleted in turn");
  }
  ASSERT_EQ_ULONG(0UL, (unsigned long) database->count, "and the database is empty");

  extent_db_clear(database);
}

UNIT_TEST(test_a_database_holds_the_extents_of_a_heavily_fragmented_file) {
  /* A file written a little at a time over a full filesystem ends up with
     thousands of extents, and the cache is a linked list walked from the front
     for every add and every lookup. This is the size at which a broken link
     shows up */
  struct extent_db_t *database;
  const int how_many = 1000;
  int index;
  struct extent_area found;

  open_a_filesystem_with_block_size(4096);
  database = extent_db_init(NULL);
  if (database == NULL) {
    FAIL("a database should have been allocated");
    return;
  }

  /* Physically apart, so that none of them is merged into the one before */
  for (index = 0; index < how_many; index++) {
    extent_db_add(database,
                  an_extent(0, (blk_t) (index * 10), (blk_t) (index * 10 + 9),
                            (blk_t) (10000 + index * 1000), 10, (blk_t) (5000 + index)),
                  0);
  }

  ASSERT_EQ_ULONG((unsigned long) how_many, (unsigned long) database->count, "every extent was kept");

  memset(&found, 0, sizeof(found));
  ASSERT_EQ_ULONG(9UL, (unsigned long) extentd_db_find(database, 0, &found), "the first is found");
  memset(&found, 0, sizeof(found));
  ASSERT_EQ_ULONG((unsigned long) ((how_many - 1) * 10 + 9),
                  (unsigned long) extentd_db_find(database, (how_many - 1) * 10, &found),
                  "and so is the last");

  extent_db_clear(database);
}
