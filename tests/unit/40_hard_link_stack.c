/***************************************************************************
 *   The hard link database of src/hard_link_stack.c.                      *
 *                                                                         *
 *   Several names pointing at one inode have to come back as several names *
 *   pointing at one recovered file, not as several copies of it. This      *
 *   database is what remembers the first name an inode was recovered under *
 *   so that the ones after it become links to that file.                   *
 *                                                                         *
 *   Its state is a single file-static, so every test starts by calling      *
 *   init_link_stack() -- which is also what recover.c does before a run.    *
 ***************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ext2fs/ext2fs.h>

#include "unit_tests.h"
#include "hard_link_stack.h"


UNIT_TEST(test_a_freshly_started_database_knows_no_inode) {
  init_link_stack();

  ASSERT_NULL(check_link_stack(12, 1), "an inode that was never added is not there");
  ASSERT_NULL(check_link_stack(0, 0), "and neither is inode zero");

  clear_link_stack();
}

UNIT_TEST(test_an_inode_is_found_again_under_the_name_it_was_recovered_with) {
  init_link_stack();
  add_link_stack(12, 3, "/target/documents/report.txt", 42);

  ASSERT_EQ_STR("/target/documents/report.txt", check_link_stack(12, 42),
                "the name the inode was first recovered under");

  clear_link_stack();
}

UNIT_TEST(test_an_inode_is_only_found_under_the_generation_it_was_added_with) {
  /* The generation number changes every time an inode is reused for a new
     file. Matching on the inode number alone would link a recovered file to a
     completely unrelated one that happened to reuse its inode */
  init_link_stack();
  add_link_stack(12, 2, "/target/report.txt", 42);

  ASSERT_EQ_STR("/target/report.txt", check_link_stack(12, 42), "the right generation is found");
  ASSERT_NULL(check_link_stack(12, 43), "a later generation of the same inode is not");
  ASSERT_NULL(check_link_stack(12, 0), "and neither is generation zero");

  clear_link_stack();
}

UNIT_TEST(test_several_inodes_are_kept_apart) {
  init_link_stack();
  add_link_stack(12, 2, "/target/one.txt", 100);
  add_link_stack(13, 2, "/target/two.txt", 200);
  add_link_stack(14, 5, "/target/three.txt", 300);

  ASSERT_EQ_STR("/target/one.txt", check_link_stack(12, 100), "the first inode");
  ASSERT_EQ_STR("/target/two.txt", check_link_stack(13, 200), "the second");
  ASSERT_EQ_STR("/target/three.txt", check_link_stack(14, 300), "the third");
  ASSERT_NULL(check_link_stack(15, 400), "and one that was never added is still not there");

  clear_link_stack();
}

UNIT_TEST(test_the_name_is_copied_rather_than_referred_to) {
  /* recover.c builds the path in a buffer it reuses for the next file */
  char path_in_a_buffer[64];

  init_link_stack();
  strcpy(path_in_a_buffer, "/target/documents/report.txt");
  add_link_stack(12, 2, path_in_a_buffer, 42);
  memset(path_in_a_buffer, 'X', sizeof(path_in_a_buffer) - 1);
  path_in_a_buffer[sizeof(path_in_a_buffer) - 1] = 0;

  ASSERT_EQ_STR("/target/documents/report.txt", check_link_stack(12, 42),
                "the database still holds the name it was given");

  clear_link_stack();
}

UNIT_TEST(test_matching_an_inode_the_last_lookup_found_reports_a_match) {
  /* match_link_stack() reads the entry check_link_stack() stopped on, so the
     two are one operation in two calls, and recover.c always makes them in
     that order */
  init_link_stack();
  add_link_stack(12, 3, "/target/report.txt", 42);

  ASSERT_NOT_NULL(check_link_stack(12, 42), "the lookup finds the inode");
  ASSERT_EQ_INT(0, match_link_stack(12, 42), "and the match right after it reports zero");

  clear_link_stack();
}

UNIT_TEST(test_matching_a_different_inode_than_the_last_lookup_found_reports_no_match) {
  init_link_stack();
  add_link_stack(12, 3, "/target/report.txt", 42);
  add_link_stack(13, 2, "/target/other.txt", 43);

  ASSERT_NOT_NULL(check_link_stack(12, 42), "the lookup finds the first inode");
  ASSERT_EQ_INT(1, match_link_stack(13, 43), "matching another one reports no match");
  ASSERT_EQ_INT(1, match_link_stack(12, 99), "and so does the same inode at another generation");

  clear_link_stack();
}

UNIT_TEST(test_a_match_counts_one_of_the_links_down) {
  /* The count starts one below the inode's link count, because the first name
     is the file itself and the rest are the links still to be made. Reaching
     zero is how clear_link_stack() knows every link was resolved */
  init_link_stack();
  add_link_stack(12, 3, "/target/report.txt", 42);

  ASSERT_NOT_NULL(check_link_stack(12, 42), "the inode is there");
  ASSERT_EQ_INT(0, match_link_stack(12, 42), "first link resolved");
  ASSERT_NOT_NULL(check_link_stack(12, 42), "the entry stays after a match");
  ASSERT_EQ_INT(0, match_link_stack(12, 42), "second link resolved");
  ASSERT_EQ_STR("/target/report.txt", check_link_stack(12, 42),
                "and the name is still the one the file was recovered under");

  clear_link_stack();
}

UNIT_TEST(test_the_most_recently_added_inode_is_found_first) {
  /* Entries are pushed on the front, so a lookup walks the newest first. It
     only matters when the same inode and generation are added twice, which a
     journal holding two copies of one directory produces */
  init_link_stack();
  add_link_stack(12, 2, "/target/first_name.txt", 42);
  add_link_stack(12, 2, "/target/second_name.txt", 42);

  ASSERT_EQ_STR("/target/second_name.txt", check_link_stack(12, 42),
                "the entry added last is the one found");

  clear_link_stack();
}

UNIT_TEST(test_renaming_rewrites_the_entry_whose_name_is_the_renamed_path_itself) {
  /* imap_search.c calls this straight after moving a recovered directory to the
     name it finally worked out, so that the database stops pointing at the
     placeholder the directory was recovered under */
  init_link_stack();
  add_link_stack(12, 2, "/target/MAGIC-1/lost_dir", 42);
  add_link_stack(13, 2, "/target/elsewhere", 43);

  ASSERT_EQ_INT(0, rename_hardlink_path("/target/MAGIC-1/lost_dir", "/target/documents"),
                "the rename reports success");

  ASSERT_EQ_STR("/target/documents", check_link_stack(12, 42), "the entry now holds the new path");
  ASSERT_EQ_STR("/target/elsewhere", check_link_stack(13, 43), "and another entry is left alone");

  clear_link_stack();
}

UNIT_TEST(test_renaming_a_path_reports_success_on_an_empty_database) {
  /* The caller does not look at the return value, but it is the only way this
     function reports the one failure it can have, so it has to stay 0 for
     "nothing went wrong" rather than for "nothing matched" */
  init_link_stack();

  ASSERT_EQ_INT(0, rename_hardlink_path("/target/anything", "/target/other"),
                "renaming in an empty database is not a failure");

  clear_link_stack();
}

UNIT_TEST(test_renaming_a_path_nothing_sits_under_changes_nothing) {
  init_link_stack();
  add_link_stack(12, 2, "/target/documents/report.txt", 42);

  ASSERT_EQ_INT(0, rename_hardlink_path("/target/pictures", "/target/photos"),
                "the rename still reports success");
  ASSERT_EQ_STR("/target/documents/report.txt", check_link_stack(12, 42),
                "and the entry is untouched");

  clear_link_stack();
}

UNIT_TEST(test_renaming_matches_a_whole_path_and_not_a_prefix_of_a_name) {
  /* The old path is compared with strcmp against the whole stored name, so an
     entry is only rewritten when the two are equal. A directory whose name
     merely starts with the same letters keeps its own */
  init_link_stack();
  add_link_stack(12, 2, "/target/documents", 42);
  add_link_stack(13, 2, "/target/documents_old", 43);

  ASSERT_EQ_INT(0, rename_hardlink_path("/target/documents", "/target/papers"), "the rename succeeds");

  ASSERT_EQ_STR("/target/papers", check_link_stack(12, 42), "the exact match was rewritten");
  ASSERT_EQ_STR("/target/documents_old", check_link_stack(13, 43),
                "the name that merely starts the same was not");

  clear_link_stack();
}

UNIT_TEST(test_the_database_holds_as_many_inodes_as_a_recovery_produces) {
  /* A recovery of a whole tree records one entry per multiply linked inode, and
     every lookup walks the list, so this is where a broken link would show */
  const int how_many = 1000;
  int index;

  init_link_stack();
  for (index = 0; index < how_many; index++) {
    char name[64];
    sprintf(name, "/target/file_%04d.txt", index);
    add_link_stack((ext2_ino_t) (1000 + index), 2, name, (__u32) (index + 1));
  }

  for (index = 0; index < how_many; index += 137) {
    char expected[64];
    sprintf(expected, "/target/file_%04d.txt", index);
    ASSERT_EQ_STR(expected, check_link_stack((ext2_ino_t) (1000 + index), (__u32) (index + 1)),
                  "an entry from anywhere in the database is found");
  }
  ASSERT_NULL(check_link_stack((ext2_ino_t) (1000 + how_many), 1),
              "and one that was never added is still not there");

  clear_link_stack();
}
