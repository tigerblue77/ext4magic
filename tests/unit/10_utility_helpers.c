/***************************************************************************
 *   The helpers in src/util.c that need no open filesystem.               *
 *                                                                         *
 *   They are small and they are called from everywhere : the command line  *
 *   parser reads its numbers through parse_ulong(), every listing prints   *
 *   its times through time_to_string() and its file types through          *
 *   get_inode_mode_type(), and the magic scan decides what a block holds   *
 *   with zero_space() and is_unicode(). What each one accepts and refuses  *
 *   is a contract the rest of the program is written against, and this     *
 *   file is where that contract is written down.                           *
 ***************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <limits.h>

#include <ext2fs/ext2fs.h>

#include "unit_tests.h"
#include "util.h"

/* The open filesystem ext4magic keeps in a global, defined by tests/unit/stubs.c */
extern ext2_filsys current_fs;

/* zero_space() reads current_fs->blocksize, and nothing else of the filesystem.
   A bare struct with that one field set is therefore the whole environment it
   needs, and it lets the block size be varied, which is what the function's
   rounding is about */
static void open_a_filesystem_with_block_size(unsigned int block_size) {
  static struct struct_ext2_filsys filesystem;

  memset(&filesystem, 0, sizeof(filesystem));
  filesystem.blocksize = block_size;
  current_fs = &filesystem;
}

/* Run a call in a child process and return how it ended, for the paths that are
   specified to end the program rather than to return. Returns the exit status
   as waitpid reports it, or -1 when the fork failed */
static int exit_status_of_forked_call(void (*call)(void)) {
  pid_t child;
  int status = 0;

  fflush(stdout);
  child = fork();
  if (child < 0) {
    return -1;
  }
  if (child == 0) {
    call();
    _exit(0);
  }
  if (waitpid(child, &status, 0) < 0) {
    return -1;
  }
  return status;
}

static void call_parse_ulong_on_garbage_without_an_error_pointer(void) {
  /* stderr is where the message goes ; the test is about the exit, not the text */
  freopen("/dev/null", "w", stderr);
  parse_ulong("not a number", "ext4magic", "block size", 0);
}


/* ------------------------------------------------------------------ */
/* parse_ulong                                                        */
/* ------------------------------------------------------------------ */

UNIT_TEST(test_parse_ulong_reads_a_plain_decimal_number) {
  int error = 1;

  ASSERT_EQ_ULONG(0UL, parse_ulong("0", "ext4magic", "number", &error), "zero is a number");
  ASSERT_EQ_INT(0, error, "zero is not an error");

  error = 1;
  ASSERT_EQ_ULONG(42UL, parse_ulong("42", "ext4magic", "number", &error), "42 should parse");
  ASSERT_EQ_INT(0, error, "a well formed number is not an error");

  error = 1;
  ASSERT_EQ_ULONG(4096UL, parse_ulong("4096", "ext4magic", "block size", &error), "4096 should parse");
  ASSERT_EQ_INT(0, error, "a well formed number is not an error");
}

UNIT_TEST(test_parse_ulong_reads_the_base_off_the_prefix) {
  /* strtoul is called with base 0, so the caller of "-s" or "-n" may write a
     block or superblock number in hexadecimal or in octal. Undocumented, and
     load bearing : "010" is eight here, not ten */
  int error = 1;

  ASSERT_EQ_ULONG(16UL, parse_ulong("0x10", "ext4magic", "number", &error), "0x prefix is hexadecimal");
  ASSERT_EQ_INT(0, error, "hexadecimal is accepted");

  error = 1;
  ASSERT_EQ_ULONG(8UL, parse_ulong("010", "ext4magic", "number", &error), "a leading zero is octal");
  ASSERT_EQ_INT(0, error, "octal is accepted");

  error = 1;
  ASSERT_EQ_ULONG(255UL, parse_ulong("0xFF", "ext4magic", "number", &error), "uppercase hexadecimal too");
  ASSERT_EQ_INT(0, error, "uppercase hexadecimal is accepted");
}

UNIT_TEST(test_parse_ulong_refuses_anything_with_a_character_left_over) {
  /* The check is that strtoul consumed the whole string, which is what keeps
     "-B 12kB" from silently becoming block 12 */
  const char *rejected[] = {"12abc", "abc", "4096 ", " ", "1.5", "12,3", "0x", "--5", NULL};
  int index;

  for (index = 0; rejected[index] != NULL; index++) {
    int error = 0;
    unsigned long value;

    /* The message goes to stderr, which the runner captures ; silenced so that
       a passing test prints nothing */
    freopen("/dev/null", "w", stderr);
    value = parse_ulong(rejected[index], "ext4magic", "number", &error);

    ASSERT_EQ_INT(1, error, "a string with a character left over is an error");
    ASSERT_EQ_ULONG(0UL, value, "a refused string parses as zero");
  }
}

UNIT_TEST(test_parse_ulong_treats_an_empty_string_as_zero_rather_than_as_an_error) {
  /* strtoul consumes nothing and stops on the terminator, which parse_ulong
     reads as "the whole string was consumed". So "" is accepted, as zero.
     Every caller in ext4magic.c refuses zero on the line after, which is what
     makes this safe -- and is exactly why it is pinned here : the day a caller
     stops checking, this contract is what it will have been relying on */
  int error = 1;

  ASSERT_EQ_ULONG(0UL, parse_ulong("", "ext4magic", "number", &error), "an empty string parses as zero");
  ASSERT_EQ_INT(0, error, "an empty string is not flagged as an error");
}

UNIT_TEST(test_parse_ulong_does_not_report_a_number_too_large_to_hold) {
  /* strtoul saturates at ULONG_MAX and sets ERANGE, which parse_ulong does not
     look at : the saturated value comes back as if it had been asked for.
     Pinned because it is the callers, again, that make it harmless -- a
     saturated block size fails the "% 1024" check and a saturated superblock
     number fails the one below it */
  int error = 1;
  unsigned long value = parse_ulong("99999999999999999999999999", "ext4magic", "number", &error);

  ASSERT_EQ_ULONG(ULONG_MAX, value, "an overflowing number saturates");
  ASSERT_EQ_INT(0, error, "the saturation is not reported through the error flag");
}

UNIT_TEST(test_parse_ulong_lets_a_negative_number_wrap_around) {
  /* strtoul applies the minus sign to the unsigned result, so "-1" is
     ULONG_MAX and not a refusal */
  int error = 1;

  ASSERT_EQ_ULONG(ULONG_MAX, parse_ulong("-1", "ext4magic", "number", &error), "-1 wraps to ULONG_MAX");
  ASSERT_EQ_INT(0, error, "a negative number is not flagged as an error");
}

UNIT_TEST(test_parse_ulong_ends_the_program_when_it_is_given_nowhere_to_report_an_error) {
  /* The error pointer is optional, and a caller passing none is saying "stop if
     this is not a number". ext4magic.c always passes 0, so this exit is the
     actual behaviour of "-s" and "-n" on a malformed value */
  int status = exit_status_of_forked_call(call_parse_ulong_on_garbage_without_an_error_pointer);

  ASSERT_TRUE(status != -1, "the child process should have been created");
  if (status == -1) {
    return;
  }
  ASSERT_TRUE(WIFEXITED(status), "it should exit rather than be killed by a signal");
  if (WIFEXITED(status)) {
    ASSERT_EQ_INT(1, WEXITSTATUS(status), "it should exit with status 1");
  }
}


/* ------------------------------------------------------------------ */
/* time_to_string                                                     */
/* ------------------------------------------------------------------ */

UNIT_TEST(test_time_to_string_formats_the_epoch_in_gmt) {
  /* The GMT decision is read from the environment once, on the first call, and
     cached in a static. Every unit test runs in its own process, so setting TZ
     here is enough for that first call to see it */
  setenv("TZ", "GMT", 1);

  ASSERT_EQ_STR("Thu Jan  1 00:00:00 1970\n", time_to_string(0), "the epoch itself");
  ASSERT_EQ_STR("Sat Feb 19 00:31:30 2039\n", time_to_string(2181688290U), "a time past 2038");
}

UNIT_TEST(test_time_to_string_covers_the_whole_unsigned_32_bit_range) {
  /* The timestamps come from a filesystem, so they are unsigned 32 bit values
     and they run past the signed 32 bit end of time. A build where time_t is
     32 bits wide would fold the top half of that range back onto the bottom,
     which is what this checks has not happened */
  setenv("TZ", "GMT", 1);

  ASSERT_EQ_STR("Tue Jan 19 03:14:07 2038\n", time_to_string(2147483647U), "the last second of signed 32 bit time");
  ASSERT_EQ_STR("Tue Jan 19 03:14:08 2038\n", time_to_string(2147483648U), "the second after it");
  ASSERT_EQ_STR("Sun Feb  7 06:28:15 2106\n", time_to_string(4294967295U), "the last second of unsigned 32 bit time");
}

UNIT_TEST(test_time_to_string_hands_back_one_buffer_that_the_next_call_overwrites) {
  /* asctime's buffer is static, so the two calls in one printf that this
     program makes in several places print the same time twice. Pinned because
     it is a property of the helper the callers have to know about, not a
     property a test can fix */
  char *first_call;
  char first_result[32];

  setenv("TZ", "GMT", 1);

  first_call = time_to_string(0);
  strncpy(first_result, first_call, sizeof(first_result) - 1);
  first_result[sizeof(first_result) - 1] = 0;

  ASSERT_EQ_STR("Thu Jan  1 00:00:00 1970\n", first_result, "the first call formats the epoch");

  time_to_string(1000000000U);

  ASSERT_EQ_STR("Sun Sep  9 01:46:40 2001\n", first_call,
                "the pointer the first call returned now shows the second call's time");
}


/* ------------------------------------------------------------------ */
/* get_inode_mode_type                                                */
/* ------------------------------------------------------------------ */

UNIT_TEST(test_get_inode_mode_type_names_every_file_type_ext4_can_hold) {
  /* This single character is what the "-l" listing prints in its type column,
     so each of the seven has to keep the letter it has always had */
  ASSERT_EQ_INT('d', get_inode_mode_type(LINUX_S_IFDIR | 0755), "a directory is d");
  ASSERT_EQ_INT('_', get_inode_mode_type(LINUX_S_IFREG | 0644), "a regular file is _");
  ASSERT_EQ_INT('l', get_inode_mode_type(LINUX_S_IFLNK | 0777), "a symbolic link is l");
  ASSERT_EQ_INT('b', get_inode_mode_type(LINUX_S_IFBLK | 0660), "a block device is b");
  ASSERT_EQ_INT('c', get_inode_mode_type(LINUX_S_IFCHR | 0666), "a character device is c");
  ASSERT_EQ_INT('f', get_inode_mode_type(LINUX_S_IFIFO | 0644), "a fifo is f");
  ASSERT_EQ_INT('s', get_inode_mode_type(LINUX_S_IFSOCK | 0777), "a socket is s");
}

UNIT_TEST(test_get_inode_mode_type_reports_a_space_for_a_mode_it_cannot_name) {
  /* An inode read out of the journal may hold anything at all in i_mode. The
     space is how the listing says so, and it must not be mistaken for a type */
  ASSERT_EQ_INT(' ', get_inode_mode_type(0), "a zeroed mode has no type");
  ASSERT_EQ_INT(' ', get_inode_mode_type(0644), "permission bits alone have no type");
  /* The seven types ext4 defines leave 0x3000, 0x5000, 0x7000, 0x9000, 0xb000,
     0xd000, 0xe000 and 0xf000 unassigned in the format nibble */
  ASSERT_EQ_INT(' ', get_inode_mode_type(0x3000), "an unassigned format value has no type");
  ASSERT_EQ_INT(' ', get_inode_mode_type(0x9000), "another unassigned format value");
  ASSERT_EQ_INT(' ', get_inode_mode_type(0xe000), "and the one a wholly corrupted inode reaches");
}

UNIT_TEST(test_get_inode_mode_type_ignores_the_permission_bits) {
  /* The type comes from the top four bits ; the twelve below them are
     permissions and setuid bits, and no combination of them may change it */
  __u16 permissions;

  for (permissions = 0; permissions <= 07777; permissions++) {
    if (get_inode_mode_type((__u16) (LINUX_S_IFREG | permissions)) != '_') {
      FAIL("a regular file stopped being a regular file because of its permission bits");
      printf("  permissions: [0%o]\n", permissions);
      return;
    }
  }
  ASSERT_TRUE(1, "every one of the 4096 permission combinations kept the type");
}


/* ------------------------------------------------------------------ */
/* zero_space                                                         */
/* ------------------------------------------------------------------ */

UNIT_TEST(test_zero_space_reports_a_tail_of_zeros_up_to_the_end_of_the_block) {
  unsigned char block[4096];

  open_a_filesystem_with_block_size(4096);

  memset(block, 0, sizeof(block));
  memset(block, 'x', 100);

  ASSERT_EQ_INT(1, zero_space(block, 100), "everything after byte 100 is zero");
  ASSERT_EQ_INT(1, zero_space(block, 4095), "the last byte alone is zero");
}

UNIT_TEST(test_zero_space_reports_a_tail_that_is_not_all_zeros) {
  unsigned char block[4096];

  open_a_filesystem_with_block_size(4096);

  memset(block, 0, sizeof(block));
  block[4000] = 1;

  ASSERT_EQ_INT(0, zero_space(block, 100), "a single set byte anywhere after the offset is enough");
  ASSERT_EQ_INT(0, zero_space(block, 4000), "the set byte at the offset itself");
  ASSERT_EQ_INT(1, zero_space(block, 4001), "starting past it, the tail is zero again");
}

UNIT_TEST(test_zero_space_rounds_up_to_the_end_of_the_block_the_offset_falls_in) {
  /* The scan stops at the end of the block containing the offset, not at the
     end of the buffer : a caller hands it a whole extent and asks about the
     tail of one block inside it */
  unsigned char buffer[8192];

  open_a_filesystem_with_block_size(4096);

  memset(buffer, 0, sizeof(buffer));
  buffer[5000] = 1; /* in the second block */

  ASSERT_EQ_INT(1, zero_space(buffer, 100),
                "a byte set in the next block does not concern the first one");
  ASSERT_EQ_INT(0, zero_space(buffer, 4200), "it does concern the block it is in");
}

UNIT_TEST(test_zero_space_treats_offset_zero_as_the_whole_first_block) {
  /* Zero is the one offset that is not rounded : it means the whole block */
  unsigned char block[4096];

  open_a_filesystem_with_block_size(4096);

  memset(block, 0, sizeof(block));
  ASSERT_EQ_INT(1, zero_space(block, 0), "a wholly zeroed block");

  block[4095] = 1;
  ASSERT_EQ_INT(0, zero_space(block, 0), "the very last byte of the block still counts");
}

UNIT_TEST(test_zero_space_follows_the_block_size_of_the_open_filesystem) {
  /* ext4magic supports 1k, 2k and 4k filesystems, and the rounding is done
     against whichever is open. A 1k filesystem must not have its blocks read
     four at a time */
  unsigned char buffer[8192];
  unsigned int block_size;

  for (block_size = 1024; block_size <= 4096; block_size *= 2) {
    open_a_filesystem_with_block_size(block_size);

    memset(buffer, 0, sizeof(buffer));
    buffer[block_size + 10] = 1; /* just inside the second block */

    ASSERT_EQ_INT(1, zero_space(buffer, 10),
                  "the first block is zero whatever the second one holds");
    ASSERT_EQ_INT(0, zero_space(buffer, block_size + 1),
                  "the second block is not");
  }
}


/* ------------------------------------------------------------------ */
/* is_unicode                                                         */
/* ------------------------------------------------------------------ */

UNIT_TEST(test_is_unicode_measures_a_two_byte_sequence) {
  /* The length of the UTF-8 sequence starting at the pointer, or zero when
     there is none. This is what tells the magic scan that a block of bytes is
     text in a language that is not English */
  ASSERT_EQ_INT(2, is_unicode((unsigned char *) "\xc3\xa9"), "e acute");
  ASSERT_EQ_INT(2, is_unicode((unsigned char *) "\xc2\xa0"), "a non breaking space");
  ASSERT_EQ_INT(2, is_unicode((unsigned char *) "\xdf\xbf"), "the last two byte sequence");
}

UNIT_TEST(test_is_unicode_measures_a_three_byte_sequence) {
  ASSERT_EQ_INT(3, is_unicode((unsigned char *) "\xe2\x82\xac"), "the euro sign");
  ASSERT_EQ_INT(3, is_unicode((unsigned char *) "\xe4\xb8\xad"), "a CJK ideograph");
  ASSERT_EQ_INT(3, is_unicode((unsigned char *) "\xef\xbf\xbd"), "the replacement character");
}

UNIT_TEST(test_is_unicode_measures_a_four_byte_sequence) {
  ASSERT_EQ_INT(4, is_unicode((unsigned char *) "\xf0\x9f\x98\x80"), "an emoji");
  ASSERT_EQ_INT(4, is_unicode((unsigned char *) "\xf0\x90\x80\x80"), "the first four byte code point");
  ASSERT_EQ_INT(4, is_unicode((unsigned char *) "\xf4\x8f\xbf\xbf"), "the last code point Unicode defines");
}

UNIT_TEST(test_is_unicode_refuses_a_byte_that_cannot_start_a_sequence) {
  /* Plain ASCII, a continuation byte on its own, and the lead bytes UTF-8
     forbids : none of them starts a sequence */
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "A\x80\x80\x80"), "an ASCII letter");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\x00\x80\x80\x80"), "a zero byte");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\x7f\x80\x80\x80"), "the last ASCII byte");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\x80\x80\x80\x80"), "a continuation byte alone");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xbf\x80\x80\x80"), "the last continuation byte alone");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xc0\x80\x80\x80"), "the overlong two byte lead");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xc1\x80\x80\x80"), "the other overlong two byte lead");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xf5\x80\x80\x80"), "past the last code point");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xff\x80\x80\x80"), "a byte UTF-8 never uses");
}

UNIT_TEST(test_is_unicode_refuses_a_sequence_whose_second_byte_is_not_a_continuation) {
  /* The second byte is checked for every length, which is what stops two
     unrelated bytes from being read as a character */
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xc3\x41"), "an ASCII letter after a two byte lead");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xe2\x41\xac"), "an ASCII letter after a three byte lead");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xf0\x41\x98\x80"), "an ASCII letter after a four byte lead");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xc3\xc3"), "a second lead byte instead of a continuation");
}

UNIT_TEST(test_is_unicode_refuses_a_three_byte_sequence_whose_third_byte_is_not_a_continuation) {
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xe2\x82\x41"), "an ASCII letter as the third byte");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xe2\x82\xe2"), "a lead byte as the third byte");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xe2\x82\x00"), "a zero byte as the third byte");
}

UNIT_TEST(test_is_unicode_refuses_a_four_byte_sequence_whose_fourth_byte_is_not_a_continuation) {
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xf0\x9f\x98\x41"), "an ASCII letter as the fourth byte");
  ASSERT_EQ_INT(0, is_unicode((unsigned char *) "\xf0\x9f\x98\x00"), "a zero byte as the fourth byte");
}
