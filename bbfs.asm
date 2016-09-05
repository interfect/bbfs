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

; BBOS drive API
; Get Drive Count         0x2000  OUT Drive Count         Drive Count     1.0
; Check Drive Status      0x2001  DriveNum                StatusCode      1.0
; Get Drive Parameters    0x2002  *DriveParams, DriveNum  None            1.0
; Read Drive Sector       0x2003  Sector, Ptr, DriveNum   Success         1.0
; Write Drive Sector      0x2004  Sector, Ptr, DriveNum   Success         1.0
define GET_DRIVE_COUNT 0x2000
define CHECK_DRIVE_STATUS 0x2001
define GET_DRIVE_PARAMETERS 0x2002
define READ_DRIVE_SECTOR 0x2003
define WRITE_DRIVE_SECTOR 0x2004
; States and errors are in bbos.inc.asm
; Drive param struct stuff is also there

; Parameters:

define BBFS_VERSION 0xBF56 ; This is the filesystem spec version
define BBFS_FILENAME_BUFSIZE 17 ; Characters plus trailing null
define BBFS_FILENAME_PACKED 8 ; Packed 2 per word internally
define BBFS_MAX_SECTOR_SIZE 512 ; Support sectors of this size or smaller
define BBFS_MAX_SECTOR_COUNT 0xFFFF ; Support up to this number of sectors
define BBFS_START_SECTOR 1 ; This is the header start sector, after a bootloader

; In-Memory Structures:

; BBFS_DEVICE: sector cache with eviction.
; on.
define BBFS_DEVICE_SIZEOF 2 + DRIVEPARAM_SIZE + BBFS_MAX_SECTOR_SIZE
define BBFS_DEVICE_DRIVE 0 ; What drive is this array on?
define BBFS_DEVICE_SECTOR 1 ; What sector is loaded now?
define BBFS_DEVICE_DRIVEINFO 2 ; Holds the drive info struct: sector size at DRIVE_SECT_SIZE and count at DRIVE_SECT_COUNT
define BBFS_DEVICE_BUFFER 2 + DRIVEPARAM_SIZE ; Where is the sector buffer? Right now holds one sector.

; BBFS_ARRAY: disk-backed array of contiguous sectors
define BBFS_ARRAY_SIZEOF 2
define BBFS_ARRAY_DEVICE 0 ; Pointer to the device being used
define BBFS_ARRAY_START 1 ; Sector at which the array starts

; BBFS_VOLUME: represents a filesystem. Constructed off a device and contains an
; array for the header. Has all the methods to access the FAT.
define BBFS_VOLUME_SIZEOF BBFS_ARRAY_SIZEOF + 3
define BBFS_VOLUME_ARRAY 0 ; Contained array that we use for the header
define BBFS_VOLUME_FREEMASK_START BBFS_ARRAY_SIZEOF ; Offset in the array where the freemask starts
define BBFS_VOLUME_FAT_START BBFS_VOLUME_FREEMASK_START + 1 ; Offset in the array where the FAT starts
define BBFS_VOLUME_FIRST_USABLE_SECTOR BBFS_VOLUME_FAT_START + 1 ; Number of the first usable sector (not used in the array)

; BFFS_FILE: file handle structure
; Now all the cacheing is done by the device.
define BBFS_FILE_SIZEOF 5
define BBFS_FILE_VOLUME 0 ; BBFS_VOLUME that the file is on
define BBFS_FILE_START_SECTOR 1 ; Sector that the file starts at
define BBFS_FILE_SECTOR 2 ; Sector currently being read/written
define BBFS_FILE_OFFSET 3 ; Offset in the sector at which to read/write next
define BBFS_FILE_MAX_OFFSET 4 ; Number of used words in the sector

; BBFS_DIRECTORY: handle for an open directory (which contains a file handle)
define BBFS_DIRECTORY_SIZEOF 1+BBFS_FILE_SIZEOF
define BBFS_DIRECTORY_CHILDREN_LEFT 0
define BBFS_DIRECTORY_FILE 1

; On-Disk Structures:

; BBFS_HEADER: filesystem header structure on disk
define BBFS_HEADER_VERSION 0
define BBFS_HEADER_FREEMASK 6
; Only the version location and freemask start are predicatble
; Other field positions (and total size) depend on sector count.

; BBFS_DIRHEADER: directory header structure
define BBFS_DIRHEADER_SIZEOF 2
define BBFS_DIRHEADER_VERSION 0
define BBFS_DIRHEADER_CHILD_COUNT 1

; BBFS_DIRENTRY: directory entry structure
define BBFS_DIRENTRY_SIZEOF 10
define BBFS_DIRENTRY_TYPE 0
define BBFS_DIRENTRY_SECTOR 1
define BBFS_DIRENTRY_NAME 2 ; Stores 8 words of 16 packed characters

; Error codes:

define BBFS_ERR_NONE                0x0000 ; No error; operation succeeded
define BBFS_ERR_DRIVE               0x0005 ; Drive number is invalid
define BBFS_ERR_DISK_FULL           0x0007 ; Disk is full
define BBFS_ERR_EOF                 0x0008 ; End of file reached
define BBFS_ERR_UNKNOWN             0x0009 ; An unknown error has occurred
define BBFS_ERR_UNFORMATTED         0x000A ; Disk is not BBFS-formatted
define BBFS_ERR_NOTDIR              0x1001 ; Directory file wasn't a directory
define BBFS_ERR_NOTFOUND            0x1002 ; No file at given sector/name 
define BBFS_ERR_INVALID             0x1003 ; Name or other parameters invalid

; Directory constants:

define BBFS_TYPE_DIRECTORY 0
define BBFS_TYPE_FILE 1

; Functions
;
; API level 0: disk
;
; bbfs_drive_load(drive_num, *header)
;   Load a BBFS_HEADER from the BBOS drive with the given number
;
; bbfs_drive_save(drive_num, *header)
;   Save a BBFS_HEADER to the BBOS drive with the given number
;
; API level 1: header
;
; bbfs_header_allocate_sector(*header, sector_num)
;   Mark the given sector in the BBFS_HEADER as allocated in the bitmap
;
; bbfs_header_free_sector(*header, sector_num)
;   Mark the given sector in the BBFS_HEADER as free in the bitmap
;
; bbfs_header_find_free_sector(*header)
;   Return the first free sector on the disk, or 0xFFFF if no sector is free.
;
; bbfs_header_format(*header)
;   Format the given header as an empty BBFS filesystem, with no files or
;   directories.
;
; API level 2: files
;
; bbfs_file_create(*file, *header, drive_num)
;   Create a new file in a new free sector, using the given filesystem header
;   and the given drive number. First sector may contain garbage. Returns an
;   error code.
;
; bbfs_file_open(*file, *header, drive_num, sector_num)
;   Open the file starting at the given sector on the given drive, using the
;   given filesystem header, and populate the given file handle. Returns an
;   error code.
;
; bbfs_file_reopen(*file)
;   Reset back to the beginning of an opened file. Returns an error code.
;
; bbfs_file_flush(*file)
;   Flush any data written to the file to disk. Responsible for updating the
;   length of the last sector in the FAT if necessary. Returns an error code.
;
; bbfs_file_write(*file, *data, size)
;   Write the given number of words, starting at the given address, to the given
;   file, allocating new sectors as needed. Returns an error code.
;
; bbfs_file_read(*file, *data, size)
;   Read the given number of words to the given address. If the end of the file
;   is hit, words will be read up until there. Returns an error code.
;
; bbfs_file_seek(*file, distance)
;   Skip ahead the given number of words in the file, allocating sectors if
;   necessary. Returns an error code.
;
; bbfs_file_truncate(*file)
;   Deallocate all sectors in the file after the current one, and make the file
;   end at the current position. Returns an error code.
;
; bbfs_file_delete(*file)
;   Deallocate all sectors in the file. Returns an error code. After calling
;   this on a file struct, the struct must be opened again on a different
;   starting sector.
;
; API Level 3: directories
;
; bbfs_directory_create(*directory, *header, drive_num)
;   Make a new empty directory somewhere on the given drive, using the given;
;   filesystem header. Returns an error code.
;
; bbfs_directory_open(*directory, *header, drive_num, sector_num)
;   Open the directory at the given sector on the given drive, using the given
;   filesystem header. Returns an error code.
;
; bbfs_directory_next(*directory, *entry)
;   Populates entry with the next entry from the given directory. Returns an
;   error code, which will be BBFS_ERR_EOF if there was no entry to get.
;
; bbfs_directory_append(*directory, *entry)
;   Append the given entry to the directory. Returns an error code.
;
; bbfs_directory_remove(*directory, index)
;   Delete the entry at the given index from the given directory.
;   Returns an error code.
;
; bbfs_filename_pack(*unpacked, *packed)
;   Pack a null-terminated string of 16 or fewer characters into 8 words in
;   packed.
;
; bbfs_filename_unpack(*unpacked, *packed)
;   Unpack a normal string of length 16 or less from a packed string in 8 words.
;   Unpacked buffer must be 17 words or more, for trailing null.
;
; bbfs_filename_compare(*packed1, *packed2)
;   Compare two 8-word packed filenames. Return 1 if they match, 0 otherwise.
;   Performs case-insensitive comparison.

#include "bbfs_device.asm"
#include "bbfs_array.asm"
#include "bbfs_volume.asm"
#include "bbfs_files.asm"
#include "bbfs_directories.asm"
