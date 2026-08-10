/***************************************************************************
 *   The few symbols the ext4magic translation units under test reference  *
 *   but do not define.                                                    *
 *                                                                         *
 *   ext4magic keeps its open filesystem, its block bitmaps and its inode  *
 *   reader in globals that ext4magic.c, magic_block_scan.c and inode.c    *
 *   own. The unit tests link util.c, file_type.c and the four data        *
 *   structures ; pulling in the three owners as well would drag the whole *
 *   program in, main() included, for helpers that never touch a           *
 *   filesystem.                                                           *
 *                                                                         *
 *   So they are defined here instead, in the state a test starts from :   *
 *   no filesystem open, no bitmap allocated. A unit test that needs one    *
 *   of them set assigns it itself ; a test whose subject reads a real     *
 *   inode belongs in tests/cases, against a real image.                   *
 *                                                                         *
 *   intern_read_inode_full() is the one function among them. It is        *
 *   stubbed as a hard failure rather than as a fake success on purpose :   *
 *   a helper that quietly starts depending on reading an inode should      *
 *   make its test fail here, not pass against invented data.              *
 ***************************************************************************/

#include <ext2fs/ext2fs.h>

ext2_filsys current_fs = NULL;

ext2fs_inode_bitmap imap = NULL;
ext2fs_block_bitmap bmap = NULL;
ext2fs_block_bitmap d_bmap = NULL;

int intern_read_inode_full(ext2_ino_t inode_number, struct ext2_inode *inode, int size) {
  (void) inode_number;
  (void) inode;
  (void) size;
  return -1;
}

/* block.c's reader, for the same reason : linking block.c would pull in the
   bitmaps and the io_channel of an open filesystem. util.c only reaches it from
   the two whole-filesystem walks (read_all_inode_time and get_last_delete_time),
   neither of which is a unit test's subject */
int read_block(ext2_filsys fs, blk_t *block_number, void *buffer) {
  (void) fs;
  (void) block_number;
  (void) buffer;
  return -1;
}
