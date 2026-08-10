/***************************************************************************
 *   The ring buffer of src/ring_buf.c.                                    *
 *                                                                         *
 *   One of these holds every copy of a single inode that the journal still *
 *   carries, and recovering a deleted file means picking the right copy    *
 *   out of it. So the two things this file pins are the ones the recovery  *
 *   depends on : that the ring keeps every copy that was added, in the     *
 *   order it was added, and that r_begin() lands on the oldest of them.    *
 ***************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ext2fs/ext2fs.h>

#include "unit_tests.h"
#include "ring_buf.h"

/* The size journal.c builds its rings with : a 256 byte inode, which is what
   every filesystem mke2fs makes today has */
#define LARGE_INODE_SIZE 256

/* Add one item carrying a given change time, which is the field r_begin()
   orders the ring by */
static r_item *add_item_with_change_time(struct ring_buf *ring, __u32 change_time) {
  r_item *item = r_item_add(ring);

  if (item == NULL) {
    return NULL;
  }
  memset(item->inode, 0, LARGE_INODE_SIZE);
  item->inode->i_ctime = change_time;
  return item;
}

/* Walk the ring forward from its first item and collect the change times, which
   is how a test states the order it expects without depending on addresses */
static int collect_change_times(struct ring_buf *ring, __u32 *into, int room) {
  r_item *item = r_first(ring);
  int collected = 0;

  while (item != NULL && collected < room) {
    into[collected++] = item->inode->i_ctime;
    item = r_next(item);
    if (item == r_first(ring)) {
      break;
    }
  }
  return collected;
}


UNIT_TEST(test_a_new_ring_is_empty_and_remembers_what_it_was_made_for) {
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 12345);

  ASSERT_NOT_NULL(ring, "a ring should have been allocated");
  if (ring == NULL) {
    return;
  }

  ASSERT_EQ_INT(0, r_get_count(ring), "a new ring holds nothing");
  ASSERT_NULL(r_first(ring), "so it has no first item");
  ASSERT_NULL(r_last(ring), "and no last one either");
  ASSERT_EQ_ULONG(12345UL, (unsigned long) ring->nr, "it carries the inode number it was made for");
  ASSERT_EQ_INT(LARGE_INODE_SIZE, ring->i_size, "and the inode size it will allocate");
  ASSERT_EQ_INT(0, ring->del_flag, "the deleted flag starts clear");
  ASSERT_EQ_INT(0, ring->reuse_flag, "the reuse flag starts clear");

  ring_del(ring);
}

UNIT_TEST(test_a_ring_of_one_item_points_at_itself_in_both_directions) {
  /* It is a ring, not a list : with a single item, going forward and going
     backward both have to come back to it. Every walk in journal.c relies on
     that to know when it has been all the way round */
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 11);
  r_item *only_item;

  if (ring == NULL) {
    FAIL("a ring should have been allocated");
    return;
  }
  only_item = add_item_with_change_time(ring, 1000);
  ASSERT_NOT_NULL(only_item, "an item should have been added");
  if (only_item == NULL) {
    ring_del(ring);
    return;
  }

  ASSERT_EQ_INT(1, r_get_count(ring), "the ring holds one item");
  ASSERT_TRUE(r_first(ring) == only_item, "it is the first item");
  ASSERT_TRUE(r_last(ring) == only_item, "and the last one");
  ASSERT_TRUE(r_next(only_item) == only_item, "going forward comes back to it");
  ASSERT_TRUE(r_prev(only_item) == only_item, "and so does going backward");

  ring_del(ring);
}

UNIT_TEST(test_items_come_back_in_the_order_they_were_added) {
  /* journal.c adds the inode copies in the order it reads the journal, and the
     recovery walks them in that order to choose one. A ring that reordered them
     would hand the recovery an inode from the wrong point in time */
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 11);
  __u32 collected[8];
  int collected_count;

  if (ring == NULL) {
    FAIL("a ring should have been allocated");
    return;
  }

  add_item_with_change_time(ring, 1000);
  add_item_with_change_time(ring, 2000);
  add_item_with_change_time(ring, 3000);
  add_item_with_change_time(ring, 4000);

  ASSERT_EQ_INT(4, r_get_count(ring), "four items were added");

  collected_count = collect_change_times(ring, collected, 8);
  ASSERT_EQ_INT(4, collected_count, "walking forward visits each item once");
  if (collected_count == 4) {
    ASSERT_EQ_ULONG(1000UL, collected[0], "the first added comes first");
    ASSERT_EQ_ULONG(2000UL, collected[1], "then the second");
    ASSERT_EQ_ULONG(3000UL, collected[2], "then the third");
    ASSERT_EQ_ULONG(4000UL, collected[3], "then the fourth");
  }

  ASSERT_EQ_ULONG(1000UL, r_first(ring)->inode->i_ctime, "the first item is the first added");
  ASSERT_EQ_ULONG(4000UL, r_last(ring)->inode->i_ctime, "the last item is the last added");

  ring_del(ring);
}

UNIT_TEST(test_walking_backward_visits_the_same_items_in_reverse) {
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 11);
  r_item *item;

  if (ring == NULL) {
    FAIL("a ring should have been allocated");
    return;
  }

  add_item_with_change_time(ring, 100);
  add_item_with_change_time(ring, 200);
  add_item_with_change_time(ring, 300);

  item = r_last(ring);
  ASSERT_EQ_ULONG(300UL, item->inode->i_ctime, "the last item");
  item = r_prev(item);
  ASSERT_EQ_ULONG(200UL, item->inode->i_ctime, "the one before it");
  item = r_prev(item);
  ASSERT_EQ_ULONG(100UL, item->inode->i_ctime, "and the one before that");
  item = r_prev(item);
  ASSERT_EQ_ULONG(300UL, item->inode->i_ctime, "going back once more wraps round");

  ring_del(ring);
}

UNIT_TEST(test_each_item_carries_its_own_inode_and_its_own_transaction_range) {
  /* The items share nothing : two copies of the same inode differ precisely in
     what each carries, and a shared buffer would make them all report the last
     one read */
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 11);
  r_item *first_item;
  r_item *second_item;

  if (ring == NULL) {
    FAIL("a ring should have been allocated");
    return;
  }

  first_item = add_item_with_change_time(ring, 111);
  second_item = add_item_with_change_time(ring, 222);
  if (first_item == NULL || second_item == NULL) {
    FAIL("two items should have been added");
    ring_del(ring);
    return;
  }

  ASSERT_TRUE(first_item->inode != second_item->inode, "the two inodes are separate allocations");
  ASSERT_EQ_ULONG(111UL, first_item->inode->i_ctime, "the first item kept its own change time");
  ASSERT_EQ_ULONG(222UL, second_item->inode->i_ctime, "and the second its own");

  first_item->transaction.start = 10;
  first_item->transaction.end = 20;
  second_item->transaction.start = 30;
  second_item->transaction.end = 40;

  ASSERT_EQ_ULONG(10UL, first_item->transaction.start, "the first transaction range is untouched");
  ASSERT_EQ_ULONG(20UL, first_item->transaction.end, "including its end");
  ASSERT_EQ_ULONG(30UL, second_item->transaction.start, "and the second one is its own");
  ASSERT_EQ_ULONG(40UL, second_item->transaction.end, "including its end");

  ring_del(ring);
}

UNIT_TEST(test_a_new_item_starts_with_an_empty_transaction_range) {
  /* journal.c fills the range after adding the item ; anything it leaves unset
     has to read as zero rather than as whatever the allocator handed back */
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 11);
  r_item *item;

  if (ring == NULL) {
    FAIL("a ring should have been allocated");
    return;
  }
  item = r_item_add(ring);
  if (item == NULL) {
    FAIL("an item should have been added");
    ring_del(ring);
    return;
  }

  ASSERT_EQ_ULONG(0UL, item->transaction.start, "the range starts at zero");
  ASSERT_EQ_ULONG(0UL, item->transaction.end, "and ends at zero");

  ring_del(ring);
}

UNIT_TEST(test_r_begin_moves_the_ring_onto_its_oldest_copy) {
  /* The recovery wants the oldest inode copy the journal still holds, because
     that is the one written before the file was deleted. r_begin() walks
     backward until the change times stop decreasing, and leaves the ring
     starting there */
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 11);
  r_item *oldest;

  if (ring == NULL) {
    FAIL("a ring should have been allocated");
    return;
  }

  /* Added newest first, which is how a journal read backward delivers them */
  add_item_with_change_time(ring, 5000);
  add_item_with_change_time(ring, 4000);
  add_item_with_change_time(ring, 3000);

  oldest = r_begin(ring);
  ASSERT_NOT_NULL(oldest, "r_begin should return an item");
  if (oldest != NULL) {
    ASSERT_EQ_ULONG(3000UL, oldest->inode->i_ctime, "the oldest change time of the three");
  }
  ASSERT_TRUE(r_first(ring) == oldest, "and the ring now starts there");

  ring_del(ring);
}

UNIT_TEST(test_r_begin_leaves_an_already_ordered_ring_alone) {
  /* When the copies were added oldest first, the first item already is the
     oldest and nothing has to move */
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 11);
  r_item *first_added;
  r_item *beginning;

  if (ring == NULL) {
    FAIL("a ring should have been allocated");
    return;
  }

  first_added = add_item_with_change_time(ring, 1000);
  add_item_with_change_time(ring, 2000);
  add_item_with_change_time(ring, 3000);

  beginning = r_begin(ring);
  ASSERT_TRUE(beginning == first_added, "the ring already started on its oldest copy");
  ASSERT_EQ_ULONG(1000UL, beginning->inode->i_ctime, "which is the oldest change time");
  ASSERT_EQ_INT(3, r_get_count(ring), "and nothing was added or lost");

  ring_del(ring);
}

UNIT_TEST(test_r_begin_returns_the_only_item_of_a_ring_of_one) {
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 11);
  r_item *only_item;

  if (ring == NULL) {
    FAIL("a ring should have been allocated");
    return;
  }
  only_item = add_item_with_change_time(ring, 777);

  ASSERT_TRUE(r_begin(ring) == only_item, "there is nothing else it could return");
  ASSERT_EQ_INT(1, r_get_count(ring), "and the ring still holds one item");

  ring_del(ring);
}

UNIT_TEST(test_r_begin_terminates_on_copies_that_all_share_a_change_time) {
  /* Several inode copies written inside the same second is the ordinary case
     for a recursive delete, and the comparison r_begin() walks on is strict, so
     equal times have to stop it rather than send it round the ring for ever */
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 11);
  int index;

  if (ring == NULL) {
    FAIL("a ring should have been allocated");
    return;
  }
  for (index = 0; index < 16; index++) {
    add_item_with_change_time(ring, 1700000000U);
  }

  ASSERT_NOT_NULL(r_begin(ring), "r_begin comes back");
  ASSERT_EQ_INT(16, r_get_count(ring), "with the ring intact");

  ring_del(ring);
}

UNIT_TEST(test_a_ring_holds_as_many_copies_as_a_journal_can_carry) {
  /* A journal of a busy filesystem can hold hundreds of copies of one inode.
     The ring is built one malloc per item, so the only thing to check is that
     the links still form a single cycle at that size */
  struct ring_buf *ring = ring_new(LARGE_INODE_SIZE, 11);
  const int how_many = 500;
  int index;
  int steps;
  r_item *item;

  if (ring == NULL) {
    FAIL("a ring should have been allocated");
    return;
  }
  for (index = 0; index < how_many; index++) {
    if (add_item_with_change_time(ring, (__u32) (1000 + index)) == NULL) {
      FAIL("an item could not be added");
      ring_del(ring);
      return;
    }
  }

  ASSERT_EQ_INT(how_many, r_get_count(ring), "every item was counted");

  item = r_first(ring);
  for (steps = 1; steps <= how_many; steps++) {
    item = r_next(item);
    if (item == r_first(ring)) {
      break;
    }
  }
  ASSERT_EQ_INT(how_many, steps, "and going forward comes back to the start after exactly that many steps");

  ring_del(ring);
}

UNIT_TEST(test_the_inode_buffer_is_as_large_as_the_ring_was_told) {
  /* ext4 inodes are 256 bytes and carry a creation time past the 128 byte mark
     that ext2 inodes stop at. The ring allocates whatever size it was given, and
     writing to the end of it is what says the allocation was that size */
  struct ring_buf *small_inode_ring = ring_new(EXT2_GOOD_OLD_INODE_SIZE, 11);
  struct ring_buf *large_inode_ring = ring_new(LARGE_INODE_SIZE, 12);
  r_item *item;
  unsigned char *inode_bytes;

  if (small_inode_ring == NULL || large_inode_ring == NULL) {
    FAIL("both rings should have been allocated");
    return;
  }

  item = r_item_add(small_inode_ring);
  ASSERT_NOT_NULL(item, "an item of a 128 byte ring");
  if (item != NULL) {
    inode_bytes = (unsigned char *) item->inode;
    memset(inode_bytes, 0xAB, EXT2_GOOD_OLD_INODE_SIZE);
    ASSERT_EQ_INT(0xAB, inode_bytes[EXT2_GOOD_OLD_INODE_SIZE - 1], "its last byte is writable");
  }

  item = r_item_add(large_inode_ring);
  ASSERT_NOT_NULL(item, "an item of a 256 byte ring");
  if (item != NULL) {
    inode_bytes = (unsigned char *) item->inode;
    memset(inode_bytes, 0xCD, LARGE_INODE_SIZE);
    ASSERT_EQ_INT(0xCD, inode_bytes[LARGE_INODE_SIZE - 1], "its last byte is writable too");
    ASSERT_EQ_INT(LARGE_INODE_SIZE, large_inode_ring->i_size, "and the ring reports that size");
  }

  ring_del(small_inode_ring);
  ring_del(large_inode_ring);
}
