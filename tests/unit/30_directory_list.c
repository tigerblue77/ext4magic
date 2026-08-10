/***************************************************************************
 *   The directory list of src/dir_list.c.                                 *
 *                                                                         *
 *   ext4magic rebuilds a directory out of the old copies of its data       *
 *   blocks that the journal still holds, and this list is what it          *
 *   rebuilds it into. The same name usually turns up several times, from   *
 *   several points in the filesystem's history, so the interesting part of *
 *   this structure is not the adding but clean_up_dir_list(), which        *
 *   decides which of those entries survive into the listing the user sees. *
 ***************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ext2fs/ext2fs.h>

#include "unit_tests.h"
#include "dir_list.h"

/* Whether a name is in the list, and under which inode number. Returns the
   inode number, or 0 when the name is not there */
static ext2_ino_t inode_number_of(struct dir_list_head_t *list, const char *name) {
  struct dir_list_t *entry = GET_FIRST(list);

  while (entry != NULL) {
    if (strcmp(entry->filename, name) == 0) {
      return entry->inode_nr;
    }
    entry = GET_NEXT(list, entry);
  }
  return 0;
}

/* How many entries carry a given name, which is the question every duplicate
   test is really asking */
static int how_many_entries_named(struct dir_list_head_t *list, const char *name) {
  struct dir_list_t *entry = GET_FIRST(list);
  int found = 0;

  while (entry != NULL) {
    if (strcmp(entry->filename, name) == 0) {
      found++;
    }
    entry = GET_NEXT(list, entry);
  }
  return found;
}


UNIT_TEST(test_a_new_directory_list_is_empty) {
  struct dir_list_head_t *list = new_dir_list(2, 12, "/home", "user");

  ASSERT_NOT_NULL(list, "a list should have been allocated");
  if (list == NULL) {
    return;
  }

  ASSERT_EQ_INT(0, list->count, "a new list holds no entry");
  ASSERT_NULL(GET_FIRST(list), "so it has no first entry");
  ASSERT_EQ_ULONG(2UL, (unsigned long) list->path_inode, "it remembers the inode of the path it sits under");
  ASSERT_EQ_ULONG(12UL, (unsigned long) list->dir_inode, "and the inode of the directory itself");

  clear_dir_list(list);
}

UNIT_TEST(test_a_directory_list_joins_its_path_and_its_name_with_one_separator) {
  struct dir_list_head_t *list = new_dir_list(2, 12, "/home", "user");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  ASSERT_EQ_STR("/home/user", list->pathname, "the full path of the directory");
  ASSERT_EQ_STR("user", list->dirname, "and its own name, pointing into that same string");

  clear_dir_list(list);
}

UNIT_TEST(test_the_root_directory_does_not_get_a_second_separator) {
  /* "/" already ends in a separator, and "//home" would be a different path to
     every string comparison the recovery makes afterwards */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "home");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  ASSERT_EQ_STR("/home", list->pathname, "one separator, not two");
  ASSERT_EQ_STR("home", list->dirname, "and the name still points past it");

  clear_dir_list(list);
}

UNIT_TEST(test_an_empty_path_produces_a_relative_name) {
  /* The recovery builds its target tree from paths relative to the directory
     given with -d, so the empty path has to stay empty rather than become "/" */
  struct dir_list_head_t *list = new_dir_list(2, 12, "", "documents");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  ASSERT_EQ_STR("documents", list->pathname, "no separator is put in front");
  ASSERT_EQ_STR("documents", list->dirname, "and the name is the whole path");

  clear_dir_list(list);
}

UNIT_TEST(test_a_deep_path_is_joined_the_same_way) {
  struct dir_list_head_t *list =
    new_dir_list(2, 12, "/var/lib/one/two/three/four", "five");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  ASSERT_EQ_STR("/var/lib/one/two/three/four/five", list->pathname, "the whole path");
  ASSERT_EQ_STR("five", list->dirname, "and the last component");

  clear_dir_list(list);
}

UNIT_TEST(test_entries_come_back_in_the_order_they_were_added) {
  /* A directory block is read front to back, and the listing prints what was
     read in that order */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");
  struct dir_list_t *entry;

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  add_list_item(list, 11, "first.txt", DIRENT_OTHER_FILE);
  add_list_item(list, 12, "second.txt", DIRENT_OTHER_FILE);
  add_list_item(list, 13, "third.txt", DIRENT_OTHER_FILE);

  ASSERT_EQ_INT(3, list->count, "three entries were added");

  entry = GET_FIRST(list);
  ASSERT_NOT_NULL(entry, "there is a first entry");
  if (entry == NULL) {
    clear_dir_list(list);
    return;
  }
  ASSERT_EQ_STR("first.txt", entry->filename, "the first added comes first");
  ASSERT_EQ_ULONG(11UL, (unsigned long) entry->inode_nr, "with its inode number");

  entry = GET_NEXT(list, entry);
  ASSERT_NOT_NULL(entry, "there is a second entry");
  if (entry != NULL) {
    ASSERT_EQ_STR("second.txt", entry->filename, "then the second");
  }

  entry = GET_NEXT(list, entry);
  ASSERT_NOT_NULL(entry, "there is a third entry");
  if (entry != NULL) {
    ASSERT_EQ_STR("third.txt", entry->filename, "then the third");
    ASSERT_NULL(GET_NEXT(list, entry), "and nothing after it");
  }

  clear_dir_list(list);
}

UNIT_TEST(test_an_entry_keeps_a_copy_of_the_name_it_was_given) {
  /* The name comes out of a block buffer that is reused for the next block, so
     an entry holding a pointer into it would be reading someone else's
     directory a moment later */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");
  char name_in_a_buffer[32];
  struct dir_list_t *entry;

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  strcpy(name_in_a_buffer, "report.txt");
  add_list_item(list, 11, name_in_a_buffer, DIRENT_OTHER_FILE);
  memset(name_in_a_buffer, 'X', sizeof(name_in_a_buffer) - 1);
  name_in_a_buffer[sizeof(name_in_a_buffer) - 1] = 0;

  entry = GET_FIRST(list);
  ASSERT_NOT_NULL(entry, "the entry is there");
  if (entry != NULL) {
    ASSERT_EQ_STR("report.txt", entry->filename, "and still holds the name it was given");
    ASSERT_TRUE(entry->filename != name_in_a_buffer, "in its own allocation");
  }

  clear_dir_list(list);
}

UNIT_TEST(test_an_entry_keeps_the_kind_of_directory_entry_it_came_from) {
  /* Whether an entry was live, deleted, or one of the two dots is what
     clean_up_dir_list() and the "-l" listing both work from */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");
  struct dir_list_t *entry;

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  add_list_item(list, 12, ".", DIRENT_DOT_FILE);
  add_list_item(list, 2, "..", DIRENT_DOT_DOT_FILE);
  add_list_item(list, 13, "live.txt", DIRENT_OTHER_FILE);
  add_list_item(list, 14, "gone.txt", DIRENT_DELETED_FILE);

  ASSERT_EQ_INT(4, list->count, "all four were added");

  entry = GET_FIRST(list);
  ASSERT_EQ_INT(DIRENT_DOT_FILE, entry->entry, "the dot entry");
  entry = GET_NEXT(list, entry);
  ASSERT_EQ_INT(DIRENT_DOT_DOT_FILE, entry->entry, "the dot dot entry");
  entry = GET_NEXT(list, entry);
  ASSERT_EQ_INT(DIRENT_OTHER_FILE, entry->entry, "a live entry");
  entry = GET_NEXT(list, entry);
  ASSERT_EQ_INT(DIRENT_DELETED_FILE, entry->entry, "a deleted entry");

  clear_dir_list(list);
}

UNIT_TEST(test_an_entry_without_an_inode_number_is_not_added) {
  /* A directory block read out of the journal is half overwritten as often as
     not : an entry pointing at inode 0 is a hole, not a file */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  add_list_item(list, 0, "orphan.txt", DIRENT_OTHER_FILE);

  ASSERT_EQ_INT(0, list->count, "nothing was added");
  ASSERT_NULL(GET_FIRST(list), "and the list is still empty");

  clear_dir_list(list);
}

UNIT_TEST(test_an_entry_without_a_name_is_not_added) {
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  add_list_item(list, 11, "", DIRENT_OTHER_FILE);

  ASSERT_EQ_INT(0, list->count, "nothing was added");
  ASSERT_NULL(GET_FIRST(list), "and the list is still empty");

  clear_dir_list(list);
}

UNIT_TEST(test_a_refused_entry_still_answers_with_something_other_than_null) {
  /* add_list_item() reports an allocation failure by returning NULL, and every
     caller checks for that. A refused entry is not a failure, so it answers
     with the list's last entry instead -- which is what stops "-l" from
     printing "no free memory" on a directory block holding a hole */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  ASSERT_NOT_NULL(add_list_item(list, 0, "orphan.txt", DIRENT_OTHER_FILE),
                  "an entry with no inode number is refused, not failed");
  ASSERT_NOT_NULL(add_list_item(list, 11, "", DIRENT_OTHER_FILE),
                  "an entry with no name is refused, not failed");
  ASSERT_EQ_INT(0, list->count, "and neither of them was added");

  clear_dir_list(list);
}

UNIT_TEST(test_a_long_name_is_kept_whole) {
  /* ext4 allows a name of 255 bytes, and the recovery writes that name back out
     as a file : one byte lost here is a file recovered under the wrong name */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");
  char long_name[256];
  struct dir_list_t *entry;

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  memset(long_name, 'n', 255);
  long_name[255] = 0;
  add_list_item(list, 11, long_name, DIRENT_OTHER_FILE);

  entry = GET_FIRST(list);
  ASSERT_NOT_NULL(entry, "the entry is there");
  if (entry != NULL) {
    ASSERT_EQ_INT(255, (int) strlen(entry->filename), "all 255 bytes of the name");
    ASSERT_EQ_STR(long_name, entry->filename, "and they are the right ones");
  }

  clear_dir_list(list);
}

UNIT_TEST(test_a_name_holding_bytes_that_are_not_text_is_kept_as_it_is) {
  /* An ext4 name is a byte string, not text : it may hold anything but a
     separator and a zero. The list must not decide it knows better */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");
  const char *awkward_names[] = {
    "a name with spaces.txt",
    "quote\"inside.txt",
    "\xc3\xa9t\xc3\xa9.txt",
    "\xff\xfe\xfd.bin",
    "-",
    "..hidden",
    NULL,
  };
  int index;

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  for (index = 0; awkward_names[index] != NULL; index++) {
    add_list_item(list, (ext2_ino_t) (20 + index), (char *) awkward_names[index], DIRENT_OTHER_FILE);
  }

  ASSERT_EQ_INT(6, list->count, "every one of them was added");
  for (index = 0; awkward_names[index] != NULL; index++) {
    ASSERT_EQ_ULONG((unsigned long) (20 + index),
                    (unsigned long) inode_number_of(list, awkward_names[index]),
                    "the name came back byte for byte");
  }

  clear_dir_list(list);
}

UNIT_TEST(test_cleaning_up_keeps_the_two_dot_entries_and_exempts_them_from_every_filter) {
  /* "." and ".." survive the clean up, and they are the only entries that reach
     it without going through the duplicate check or the reserved inode check
     below : ".." on the root directory points at inode 2, which that check
     would otherwise throw away. The two callers in lookup_local.c are the ones
     that skip them, by name, when they walk the list to recurse */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  add_list_item(list, 12, ".", DIRENT_DOT_FILE);
  add_list_item(list, 2, "..", DIRENT_DOT_DOT_FILE);
  add_list_item(list, 13, "report.txt", DIRENT_DELETED_FILE);

  list = clean_up_dir_list(list);
  ASSERT_NOT_NULL(list, "cleaning up gives a list back");
  if (list == NULL) {
    return;
  }

  ASSERT_EQ_INT(3, list->count, "all three entries are kept");
  ASSERT_EQ_ULONG(12UL, (unsigned long) inode_number_of(list, "."), "the directory itself");
  ASSERT_EQ_ULONG(2UL, (unsigned long) inode_number_of(list, ".."),
                  "its parent, on a reserved inode the filter would have dropped");
  ASSERT_EQ_ULONG(13UL, (unsigned long) inode_number_of(list, "report.txt"), "and the file");

  clear_dir_list(list);
}

UNIT_TEST(test_cleaning_up_drops_the_entries_pointing_at_a_reserved_inode) {
  /* The first ten inodes belong to the filesystem itself : the bad block inode,
     the root, the journal, the resize inode. A directory entry naming one of
     them is a misread block, not a file, and following it would have the
     recovery write the journal out as a file */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");
  ext2_ino_t reserved;

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  for (reserved = 1; reserved < EXT2_GOOD_OLD_FIRST_INO; reserved++) {
    char name[32];
    sprintf(name, "reserved_%u.txt", reserved);
    add_list_item(list, reserved, name, DIRENT_DELETED_FILE);
  }
  add_list_item(list, EXT2_GOOD_OLD_FIRST_INO, "the_first_real_one.txt", DIRENT_DELETED_FILE);

  list = clean_up_dir_list(list);
  if (list == NULL) {
    FAIL("cleaning up should give a list back");
    return;
  }

  ASSERT_EQ_INT(1, list->count, "only the entry on a real inode survives");
  ASSERT_EQ_ULONG((unsigned long) EXT2_GOOD_OLD_FIRST_INO,
                  (unsigned long) inode_number_of(list, "the_first_real_one.txt"),
                  "and it is the right one");

  clear_dir_list(list);
}

UNIT_TEST(test_cleaning_up_keeps_one_entry_when_the_same_name_and_inode_were_read_twice) {
  /* The same directory block turns up in several journal transactions, so the
     same entry is read several times over. The listing has to name the file
     once */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  add_list_item(list, 20, "report.txt", DIRENT_DELETED_FILE);
  add_list_item(list, 20, "report.txt", DIRENT_DELETED_FILE);
  add_list_item(list, 20, "report.txt", DIRENT_DELETED_FILE);

  list = clean_up_dir_list(list);
  if (list == NULL) {
    FAIL("cleaning up should give a list back");
    return;
  }

  ASSERT_EQ_INT(1, list->count, "the three copies became one entry");
  ASSERT_EQ_INT(1, how_many_entries_named(list, "report.txt"), "named once");

  clear_dir_list(list);
}

UNIT_TEST(test_cleaning_up_keeps_a_name_that_was_reused_by_another_inode) {
  /* A name written, deleted and written again is two different files that
     happen to share a name. Both are offered, because only the user knows which
     one they are after */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  add_list_item(list, 20, "report.txt", DIRENT_DELETED_FILE);
  add_list_item(list, 21, "report.txt", DIRENT_DELETED_FILE);

  list = clean_up_dir_list(list);
  if (list == NULL) {
    FAIL("cleaning up should give a list back");
    return;
  }

  ASSERT_EQ_INT(2, list->count, "both inodes are kept");
  ASSERT_EQ_INT(2, how_many_entries_named(list, "report.txt"), "under the one name they share");

  clear_dir_list(list);
}

UNIT_TEST(test_cleaning_up_keeps_the_path_the_list_was_made_with) {
  /* The cleaned list is a new allocation, and the path it describes has to
     survive the move : it is what the recovery writes the files under */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/home/user", "documents");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }
  add_list_item(list, 20, "report.txt", DIRENT_DELETED_FILE);

  list = clean_up_dir_list(list);
  if (list == NULL) {
    FAIL("cleaning up should give a list back");
    return;
  }

  ASSERT_EQ_STR("/home/user/documents", list->pathname, "the same full path");
  ASSERT_EQ_STR("documents", list->dirname, "and the same directory name inside it");
  ASSERT_EQ_ULONG(2UL, (unsigned long) list->path_inode, "the inode of the path");
  ASSERT_EQ_ULONG(12UL, (unsigned long) list->dir_inode, "and of the directory");

  clear_dir_list(list);
}

UNIT_TEST(test_cleaning_up_an_empty_list_gives_an_empty_list_back) {
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  list = clean_up_dir_list(list);
  ASSERT_NOT_NULL(list, "an empty list still comes back");
  if (list == NULL) {
    return;
  }
  ASSERT_EQ_INT(0, list->count, "still holding nothing");
  ASSERT_EQ_STR("/documents", list->pathname, "and still describing the same directory");

  clear_dir_list(list);
}

UNIT_TEST(test_cleaning_up_keeps_the_entries_in_the_order_they_were_read) {
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");
  struct dir_list_t *entry;

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  add_list_item(list, 20, "alpha.txt", DIRENT_DELETED_FILE);
  add_list_item(list, 12, ".", DIRENT_DOT_FILE);
  add_list_item(list, 21, "beta.txt", DIRENT_DELETED_FILE);
  add_list_item(list, 1, "dropped.txt", DIRENT_DELETED_FILE);
  add_list_item(list, 22, "gamma.txt", DIRENT_DELETED_FILE);

  list = clean_up_dir_list(list);
  if (list == NULL) {
    FAIL("cleaning up should give a list back");
    return;
  }

  ASSERT_EQ_INT(4, list->count, "the entry on a reserved inode was dropped and the rest kept");
  entry = GET_FIRST(list);
  ASSERT_EQ_STR("alpha.txt", entry->filename, "in the order they were read");
  entry = GET_NEXT(list, entry);
  ASSERT_EQ_STR(".", entry->filename, "second, in its own place rather than pushed to one end");
  entry = GET_NEXT(list, entry);
  ASSERT_EQ_STR("beta.txt", entry->filename, "third");
  entry = GET_NEXT(list, entry);
  ASSERT_EQ_STR("gamma.txt", entry->filename, "and the dropped entry left no gap");

  clear_dir_list(list);
}

UNIT_TEST(test_a_directory_list_holds_a_directory_with_many_entries) {
  /* A directory of a few thousand files is ordinary, and the list is walked
     linearly for every duplicate check, so this is also where a quadratic
     clean up would show */
  struct dir_list_head_t *list = new_dir_list(2, 12, "/", "documents");
  const int how_many = 2000;
  int index;

  if (list == NULL) {
    FAIL("a list should have been allocated");
    return;
  }

  for (index = 0; index < how_many; index++) {
    char name[32];
    sprintf(name, "file_%04d.txt", index);
    if (add_list_item(list, (ext2_ino_t) (100 + index), name, DIRENT_DELETED_FILE) == NULL) {
      FAIL("an entry could not be added");
      clear_dir_list(list);
      return;
    }
  }

  ASSERT_EQ_INT(how_many, list->count, "every entry was added");

  list = clean_up_dir_list(list);
  if (list == NULL) {
    FAIL("cleaning up should give a list back");
    return;
  }
  ASSERT_EQ_INT(how_many, list->count, "and every one of them survived the clean up");
  ASSERT_EQ_ULONG(100UL, (unsigned long) inode_number_of(list, "file_0000.txt"), "the first is there");
  ASSERT_EQ_ULONG((unsigned long) (100 + how_many - 1),
                  (unsigned long) inode_number_of(list, "file_1999.txt"), "and so is the last");

  clear_dir_list(list);
}
