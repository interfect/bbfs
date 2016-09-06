; bbfs.inc.asm: defines and constants for BBFS

; BBOS drive API:

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

define BBFS_VERSION 0xBF55 ; This is the filesystem spec version (=bfs512)
define BBFS_COMPAT_VERSION 0xBF56 ; This version is also compatible
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
define BBFS_ERR_DRIVE               0x0005 ; Drive returned an error
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

