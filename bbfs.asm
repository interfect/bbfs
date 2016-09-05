; BBFS: Bootable Bfs512 File System.
; Filesystem based on FAT and DCPUB's bfs512, with a BBOS boot sector.
; See <https://github.com/Blecki/DCPUB/blob/master/Binaries/bfs512_raw.dc>
;
; Disk structure:
;
; --------------+-------------------------------+
; Sector 0      | Bootloader                    |
; --------------+------------+------------------+
; Sector 1      | FS header  | Version          |
;               |            | (1 word, 0xBF56) |
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
; The filesystem works around a file allocation table, with 1440 words in it.
; Each entry stores the next sector used for the file using that sector. Sectors
; that are the last sectors in their file, have the high bit set, with the
; remaining bits used to give the number of used words in the sector. The FAT
; entries for unused sectors are 0xFFFF.
;
; There is also a free bitmap, storing a 1 for free sectors and a 0 for used
; sectors. Bits are used from words in LSB-first order.
;
; Programming-wise, we're going to use "object oriented assembler". We define
; structs as <TYPENAME>_<FIELD> defines for offsets into the struct, and a
; <TYPENAME>_SIZEOF for the size of the struct.
;
; Operations on the filesystem require a filesystem handle, which gives the FS
; routines space to store drive numbers, FAT stuff, etc.
;
; Operations on open files require a file handle, which keeps track of the file
; in use and buffers the active sector.
;
; Mirroring bfs512, we define a file API that identifies files by their start
; sector, and then a directory API on top of the file API, with the root
; directory being the file starting at sector 4.
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
;
; File names in a directory are packed 2 characters to a word, for a maximum
; length of 16 characters. File types are 0 for a subdirectory entry, and 1 for
; a normal file.
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
