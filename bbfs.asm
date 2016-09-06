; BBFS: Bootable Bfs512 File System.
; Filesystem and compatible with DCPUB's bfs512.
; http://github.com/Blecki/DCPUB/blob/master/Binaries/techcompliant/bfs512_raw.b
;
; Disk structure (on an M35FD):
;
; --------------+-------------------------------+
; Sector 0      | Bootloader                    |
; --------------+------------+------------------+
; Sector 1      | FS header  | Version          |
;               |            | (1 word)         |
;               |            +------------------+
;               |            | Reserved         |
;               |            | (5 words)        |
;               +------------+------------------+
;               | Free mask                     |
;               | (90 words, 1=free)            |
;               +------------+------------------+
;               | File       | First 416        |
;               | Allocation | FAT words        |
; --------------+ Table      +------------------+
; Sector 2      |            | Next 512         |
;               | (1440      | FAT words        |
; --------------+  words)    +------------------+
; Sector 3      |            | Last 512         |
;               |            | FAT words        |
; --------------+------------+------------------+
; Sector 4      | First sector of file for root |
;               | directory (stored as a file)  |
; --------------+-------------------------------+
; Remaining sectors: file data
;
; On an M535HD, or any other larger disk supported by BBOS, the free mask and
; FAT are extended in order to represent the full number of sectors on the disk,
; and the root directory sector is pushed back accordingly.
;
; Directory structure:
;
; +---------+-----------------------+
; | Header  | Version (1 word)      |
; |         +-----------------------+
; |         | Entry count (1 word)  |
; +---------+-----------------------+
; | Entry 0 | Type (1 word)         |
; |         +-----------------------+
; |         | Start sector (1 word) |
; |         +-----------------------+
; |         | Name (8 words)        |
; +---------+-----------------------+  
; | Additional entries              |
; | ...                             |
; +---------------------------------+
; File names in a directory are packed 2 characters to a word, for a maximum
; length of 16 characters. File types are 0 for a subdirectory entry, and 1 for
; a normal file.
;
;
; The filesystem works around a file allocation table, with (on an M35FD floppy)
; 1440 words in it. Each entry stores the next sector used for the file using
; that sector. Sectors that are the last sectors in their file, have the high
; bit set, with the remaining bits used to give the number of used words in the
; sector. The FAT entries for unused sectors are 0xFFFF.
;
; There is also a free bitmap, storing a 1 for free sectors and a 0 for used
; sectors. Bits are used from words in LSB-first order. The bitmap allows a free
; sector to be found more efficiently, without having to scan the whole FAT.

; Mirroring bfs512, we define a file API that identifies files by their start
; sector, and then a directory API on top of the file API, with the root
; directory being the file starting at sector 4 (on an M35FD).

; The BBFS API differs from the bfs512 API. BBFS implements a cache layer over
; the disk, so only one sector needs to be stored in memory at a time, rather
; than the whole filesystem header. This allows simple scaling of the filesystem
; to the M535HD hard disk. The cacheing design also allows a file handle to be
; stored in only a few words, as the file handle does not need to buffer its own
; data. BBFS also dispensed with the notion of file mode; all open files are
; both readable and writable.
;
; Programming-wise, we're going to use "object oriented assembler". We define
; structs as <TYPENAME>_<FIELD> defines for offsets into the struct, and a
; <TYPENAME>_SIZEOF for the size of the struct.
;

; BBOS dependency:
#include "bbos.inc.asm"

; BBFS constants
#include "bbfs.inc.asm"

#include "bbfs_device.asm"
#include "bbfs_array.asm"
#include "bbfs_volume.asm"
#include "bbfs_files.asm"
#include "bbfs_directories.asm"
