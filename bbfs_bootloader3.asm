; Bootloader with just enough BBFS code to load a file.

; We don't need to read the free bitmap or anything. All we need to do is follow
; FAT entries for the directory and for the actual boot file.

; Keeps itself at a fixed address, so there's a limit to the amount of code it
; can load.

define BOOTLOADER_BASE 0xd000

; We statically allocate a directory, a direntry, and a file, but don't include
; them in our image. We can't use labels in the defines; they all act like 0.
; Instead we just place it safely one sector after the fixed bootloader address.
define STATIC_DIRECTORY_BL BOOTLOADER_BASE+BBFS_MAX_SECTOR_SIZE
define STATIC_FILE_BL STATIC_DIRECTORY_BL+BBFS_DIRECTORY_SIZEOF
define STATIC_DIRENTRY_BL STATIC_FILE_BL+BBFS_FILE_SIZEOF
define STATIC_DEVICE_BL BOOTLOADER_BASE+BBFS_MAX_SECTOR_SIZE+BBFS_DIRECTORY_SIZEOF+BBFS_FILE_SIZEOF+BBFS_DIRENTRY_SIZEOF

#include "bbos.inc.asm"


; Consele API that we need
; Write Char              0x1003  Char, MoveCursor        None            1.0
; Write String            0x1004  StringZ, NewLine        None            1.0
define WRITE_CHAR 0x1003
define WRITE_STRING 0x1004

;; BBFS DEFINES

define BBFS_VERSION 0xBF56

; What's in a BBFS filesystem header on disk?
; Only the version location and freemask start are predicatble
; BBFS_HEADER: struct for the 3-sector header including bitmap and FAT
define BBFS_HEADER_SIZEOF 1536
define BBFS_HEADER_VERSION 0
define BBFS_HEADER_FREEMASK 6
define BBFS_HEADER_FAT 96

; How big of sectors do we support
define BBFS_MAX_SECTOR_SIZE 512
; And how many? We need a sentinel value for "no sector"
define BBFS_MAX_SECTOR_COUNT 0xFFFF
; Where should the volume info live? Sector(s) before this are bootloader
define BBFS_START_SECTOR 1

; Error codes
define BBFS_ERR_NONE                0x0000
define BBFS_ERR_DRIVE               0x0005
define BBFS_ERR_DISC_FULL           0x0007
define BBFS_ERR_EOF                 0x0008
define BBFS_ERR_UNKNOWN             0x0009
define BBFS_ERR_UNFORMATTED         0x000A
define BBFS_ERR_NOTDIR              0x1001 ; Directory file wasn't a directory
define BBFS_ERR_NOTFOUND            0x1002 ; No file at given sector/name 
define BBFS_ERR_INVALID             0x1003 ; Name or other parameters invalid


; Structures:

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

; BBFS_DIRHEADER: directory header structure
define BBFS_DIRHEADER_SIZEOF 2
define BBFS_DIRHEADER_VERSION 0
define BBFS_DIRHEADER_CHILD_COUNT 1

; BBFS_DIRENTRY: directory entry structure
define BBFS_DIRENTRY_SIZEOF 10
define BBFS_DIRENTRY_TYPE 0
define BBFS_DIRENTRY_SECTOR 1
define BBFS_DIRENTRY_NAME 2 ; Stores 8 words of 16 packed characters

; BBFS_DIRECTORY: handle for an open directory (which contains a file handle)
define BBFS_DIRECTORY_SIZEOF 1+BBFS_FILE_SIZEOF
define BBFS_DIRECTORY_CHILDREN_LEFT 0
define BBFS_DIRECTORY_FILE 1

define GET_DRIVE_COUNT 0x2000
define CHECK_DRIVE_STATUS 0x2001
define GET_DRIVE_PARAMETERS 0x2002
define READ_DRIVE_SECTOR 0x2003
define WRITE_DRIVE_SECTOR 0x2004


; This code starts at 0 and is just smart enough to copy the rest to the bootloader base address.
.org 0

; Save the drive to load off of
SET PUSH, A
SET A, payload_measure_end_bl-payload_measure_start_bl ; How many words to copy
SET I, copy_end_bl ; Source
SET J, BOOTLOADER_BASE ; Destination
copy_loop_bl:
    SUB A, 1
    STI [J], [I]
    IFN A, 0
        SET PC, copy_loop_bl

; Jump into the bootloader code proper
SET PC, BOOTLOADER_BASE

copy_end_bl:

; This code all happens at the bootloader base address. We set all the labels to
; think they're there, but don't actually sort the sections in the assembler.
.org BOOTLOADER_BASE

payload_measure_start_bl:

; Actual bootloader code begins here.
; On the stack we have our BBOS drive to load from.
; Save that in B
SET B, POP

; Announce ourselves
SET PUSH, str_intro_bl
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2
SET PUSH, str_copyright_bl
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

; Open the device
SET PUSH, STATIC_DEVICE_BL ; Arg 1: device to construct
SET PUSH, B ; Arg 2: drive to work on
JSR bbfs_device_open
SET A, POP
ADD SP, 1

halt_bl:
    SET PC, halt_bl
    

;; REQUIRED LIBRARY FUNCTIONS

; bbfs_device_open(device*, drive_num)
; Initialize a BBFS_DEVICE to cache sectors from the given drive.
; [Z+1]: BBFS_DEVICE to operate on
; [Z]: BBOS drive number to point the device at
; Returns: nothing (TODO: maybe have an error code?)
bbfs_device_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS scratch, and struct pointer
    
    ; Make the BBOS call to get device info
    SET PUSH, [Z+1] ; Arg 1: drive info to populate
    ADD [SP], BBFS_DEVICE_DRIVEINFO
    SET PUSH, [Z] ; Arg 2: device number
    SET A, GET_DRIVE_PARAMETERS
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET A, [Z+1] ; Grab the device pointer
    SET [A+BBFS_DEVICE_DRIVE], [Z] ; Save the drive number
    SET [A+BBFS_DEVICE_SECTOR], BBFS_MAX_SECTOR_COUNT ; Say no sector is currently cached    

    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_device_sector_size(device*)
; Return the sector size of the device, in words.
; [Z]: BBFS_DEVICE to operate on
; Returns: sector size in [Z]
bbfs_device_sector_size:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A

    SET A, [Z] ; Grab the device pointer
    
    ; Go get the sector size
    SET [Z], [A+BBFS_DEVICE_DRIVEINFO+DRIVE_SECT_SIZE]
    
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_device_sector_count(device*)
; Return the sector count of the device (total sectors).
; [Z]: BBFS_DEVICE to operate on
; Returns: sector count in [Z]
bbfs_device_sector_count:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A

    SET A, [Z] ; Grab the device pointer
    
    ; Go get the sector size
    SET [Z], [A+BBFS_DEVICE_DRIVEINFO+DRIVE_SECT_COUNT]
    
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_device_get(device*, word sector)
; Get a pointer to a loaded copy of the given sector.
; [Z+1]: BBFS_DEVICE to operate on
; [Z]: sector number to get
; Returns: sector pointer in [Z], or 0x0000 on error
bbfs_device_get:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS calls
    SET PUSH, B ; Device struct

    SET B, [Z+1] ; Grab the device pointer
    
    IFE [B+BBFS_DEVICE_SECTOR], [Z]
        ; Already loaded!
        SET PC, .skip_load    
    
    IFE [B+BBFS_DEVICE_SECTOR], BBFS_MAX_SECTOR_COUNT
        ; Nothing to save!
        SET PC, .skip_save    
    
    ; Otherwise we need to save the sector

    SET PUSH, [B+BBFS_DEVICE_SECTOR] ; Arg 1: Sector to write
    SET PUSH, B ; Arg 2: Pointer to write from
    ADD [SP], BBFS_DEVICE_BUFFER 
    SET PUSH, [B+BBFS_DEVICE_DRIVE] ; Arg 3: drive number
    SET A, WRITE_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    
    ; Handle error return
    IFE [SP], 1
        SET PC, .save_success
    ADD SP, 3
    SET PC, .error
.save_success:
    ; Clean up stack
    ADD SP, 3
    
.skip_save:
    ; Now we saved the existing sector (or don't need to), so load the new one
    
    SET PUSH, [Z] ; Arg 1: Sector to read
    SET PUSH, B ; Arg 2: Pointer to read to
    ADD [SP], BBFS_DEVICE_BUFFER 
    SET PUSH, [B+BBFS_DEVICE_DRIVE] ; Arg 3: drive number
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    
    ; Handle error return
    IFE [SP], 1
        SET PC, .load_success
    ; Otherwise we failed
    ADD SP, 3
    SET PC, .error
.load_success:
    ; Clean up stack
    ADD SP, 3
    
    ; Say we loaded the right thing
    SET [B+BBFS_DEVICE_SECTOR], [Z]
    
.skip_load:
    ; Point the return value at the buffer we loaded into.
    ADD B, BBFS_DEVICE_BUFFER
    SET [Z], B
    SET PC, .done
.error:
    SET [Z], 0x0000
.done:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

; bbfs_array_open(array*, device*, sector)
; Initialize a BBFS_ARRAY starting at the given sector on the given drive
; [Z+2]: BBFS_ARRAY to operate on
; [Z+1]: BBFS_DEVICE backing the array
; [Z]: sector the array starts at
bbfs_array_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Array struct pointer
    
    SET A, [Z+2]
    SET [A+BBFS_ARRAY_DEVICE], [Z+1] ; Set the device
    SET [A+BBFS_ARRAY_START], [Z] ; And the start sector

    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_array_get(array*, offset)
; Get the value at the given offset in the given array
; [Z+1]: BBFS_ARRAY to operate on
; [Z]: word offset to get
; Returns: word value in [Z], error code in [Z+1]
bbfs_array_get:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Array struct pointer
    SET PUSH, B ; Sector to get, then sector pointer
    SET PUSH, C ; Sector offset
    
    SET PUSH, X ; Array's backing device
    SET PUSH, Y ; Sector size
    
    SET A, [Z+1] ; Get the array
    SET X, [A+BBFS_ARRAY_DEVICE] ; And its device
    
    ; Get the device's sector size
    SET PUSH, X ; Arg 1 - device
    JSR bbfs_device_sector_size
    SET Y, POP
    
    ; Divide offset by that to get the sector, and offset by start sector
    SET B, [Z]
    DIV B, Y
    ADD B, [A+BBFS_ARRAY_START]
    ; And mod offset to get the offset in the sector
    SET C, [Z]
    MOD C, Y
    
    ; Get a pointer to that sector
    SET PUSH, X ; Arg 1 - device
    SET PUSH, B ; Arg 2 - sector number
    JSR bbfs_device_get
    SET B, POP
    ADD SP, 1
    
    ; If it's 0 report an error
    IFE B, 0x0000
        SET PC, .error
    
    ; Find the word at this offset and return it
    ADD B, C
    SET [Z], [B]
    SET [Z+1], BBFS_ERR_NONE
    SET PC, .return

.error:
    ; TODO: all the errors are drive errors for now
    SET [Z+1], BBFS_ERR_DRIVE
    
.return:
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

; bbfs_volume_fat_get(volume*, sector_num)
;   Get the FAT entry for the given sector to the given value (either next
;   sector number if high bit is off, or words used in sector if high bit is
;   on). Returns FAT entry, and an error code.
; [Z+1]: BBFS_VOLUME to work on
; [Z]: sector number to mark 
; Returns: FAT entry in [Z], error code in [Z+1]
bbfs_volume_fat_get:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBFS_VOLUME pointer
    
    SET A, [Z+1] ; Grab the volume
    
    SET PUSH, A ; Arg 1: array
    ADD [SP], BBFS_VOLUME_ARRAY
    SET PUSH, [Z] ; Arg 2: offset in the header array to get
    ADD [SP], [A+BBFS_VOLUME_FAT_START]
    JSR bbfs_array_get
    SET [Z], POP ; Grab value
    SET [Z+1], POP ; Grab error code
    
    ; Return
    SET A, POP
    SET Z, POP
    SET PC, POP

; bbfs_volume_get_device(volume*)
;   Method to pull the device out of the volume, for syncing.
; [Z]: BBFS_VOLUME to work on
; Returns: device in [Z]
bbfs_volume_get_device:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBFS_VOLUME pointer
    
    SET A, [Z]
    ; Just go find where the device pointer is and return it
    SET [Z], [A+BBFS_VOLUME_ARRAY+BBFS_ARRAY_DEVICE]
    
    SET A, POP
    SET Z, POP
    SET PC, POP

; bbfs_volume_open(volume*, device*)
;   Set up a new volume backed by the given device. May or may not be formatted
;   yet. Returns an error code, which will be BBFS_ERROR_UNFORMATTED if the
;   volume isn't formatted yet..
; [Z+1]: BBFS_VOLUME to operate on
; [Z]: BBFS_DEVICE that the volume is on
; Returns: error code in [Z]
bbfs_volume_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Pointer to the volume
    SET PUSH, B ; Pointer to the device
    SET PUSH, C ; Math scratch
    SET PUSH, X ; More math scratch
    SET PUSH, Y ; Sector size
    
    SET A, [Z+1]
    SET B, [Z]

    ; Make the array
    SET PUSH, A ; Arg 1: array to open
    ADD [SP], BBFS_VOLUME_ARRAY
    SET PUSH, B ; Arg 2: device
    SET PUSH, BBFS_START_SECTOR ; Arg 3: base sector
    JSR bbfs_array_open
    ADD SP, 3
    
    ; Work out where the freemask should start
    ; TODO: it is always ion the same place...
    SET C, BBFS_HEADER_FREEMASK
    SET [A+BBFS_VOLUME_FREEMASK_START], C
    
    ; And where the FAT begins (AKA past-the-end of the freemask)
    ; Get total sectors
    SET PUSH, B ; Arg 1: device
    JSR bbfs_device_sector_count
    SET X, POP
    ; Divide by 16 to a word
    SET C, X
    DIV C, 16
    SET [A+BBFS_VOLUME_FAT_START], C
    SET C, X
    MOD C, 16
    IFG C, 0
        ; Count a partial last word
        ADD [A+BBFS_VOLUME_FAT_START], 1
    ; Put it after where the freemask started
    ADD [A+BBFS_VOLUME_FAT_START], [A+BBFS_VOLUME_FREEMASK_START]
    
    ; Get the sector size
    SET PUSH, B ; Arg 1: device
    JSR bbfs_device_sector_size
    SET Y, POP
    
    ; How long will the FAT be? Total number of sectors.
    ADD X, [A+BBFS_VOLUME_FAT_START]
    ; Now X is the past-the-end word of the FAT
    SET C, X
    DIV C, Y ; How many sectors is that?
    
    ; Add in the boot record
    ADD C, BBFS_START_SECTOR
    
    MOD X, Y
    IFG X, 0
        ; Use a partial sector if needed
        ADD C, 1
        
    ; Save the number of the first usable sector
    SET [A+BBFS_VOLUME_FIRST_USABLE_SECTOR], C
    
    ; OK now go and actually look at the drive
    SET PUSH, A ; Arg 1: array
    ADD [SP], BBFS_VOLUME_ARRAY
    SET PUSH, BBFS_HEADER_VERSION ; Arg 2: index to look at
    JSR bbfs_array_get
    SET C, POP ; Value
    SET X, POP ; Error code
    
    IFN X, BBFS_ERR_NONE
        ; We couldn't talk to the drive
        SET PC, .error_x
    
    ; If nothing else is wrong, we're successful.
    SET [Z], BBFS_ERR_NONE
        
    IFN C, BBFS_VERSION
        ; This doesn't look like a formatted disk
        SET [Z], BBFS_ERR_UNFORMATTED
        
    SET PC, .return
    
.error_x:
    SET [Z], X
.return:
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

; bbfs_file_open(*file, *volume, drive_num, sector_num)
; Open an existing file at the given sector on the given drive, and populate the
; file handle.
; [Z+2]: BBFS_FILE to populate
; [Z+1]: BBFS_VOLUME to use
; [Z]: Sector at which the file starts
; Returns: error code in [Z]
bbfs_file_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Holds the file struct address
    SET PUSH, B ; Scratch for FAT interrogation
    SET PUSH, C ; Device, words per sector
    
    ; Grab the file struct
    SET A, [Z+2]

    ; Populate the file struct
    ; Fill in the volume address
    SET [A+BBFS_FILE_VOLUME], [Z+1]
    ; And the sector indexes
    SET [A+BBFS_FILE_START_SECTOR], [Z]
    SET [A+BBFS_FILE_SECTOR], [Z]
    ; And zero the offset
    SET [A+BBFS_FILE_OFFSET], 0
    
    ; Load the number of words available to read in the sector, which we get
    ; from the FAT.
    SET PUSH, [Z+1] ; Arg 1: volume
    SET PUSH, [Z] ; Arg 2: sector number
    JSR bbfs_volume_fat_get
    SET B, POP
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
    
    IFL B, 0x8000
        ; The high bit is unset, so this first sector is not also the last and
        ; is guaranteed to be full
        SET PC, .sector_is_full
    SET PC, .sector_not_full
.sector_is_full:
    ; The sector is full, but how many words is that?
    SET PUSH, [A+BBFS_FILE_VOLUME] ; Arg 1: volume to get device for
    JSR bbfs_volume_get_device
    SET C, POP
    
    SET PUSH, C ; Arg 1: device to get sector size for
    JSR bbfs_device_sector_size
    SET B, POP ; Our words remaining is the words per sector of the device
    
.sector_not_full:
    AND B, 0x7FFF ; Take everything but the high bit
    ; And say that that's the current file length within this sector.
    SET [A+BBFS_FILE_MAX_OFFSET], B 
    
    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_stack:
    SET [Z], POP
.return:
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_read(*file, *data, size)
; Read the given number of words from the given file into the given buffer.
; [Z+2]: BBFS_FILE to read from
; [Z+1]: Buffer to read into
; [Z]: Number of words to read
; Returns: error code in [Z], words successfully read in [Z+1]
bbfs_file_read:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS calls, scratch
    SET PUSH, B ; File struct address
    SET PUSH, C ; Filesystem device struct address
    SET PUSH, I ; Pointer into file buffer
    SET PUSH, J ; Pointer into data
    SET PUSH, X ; Words successfully read
    SET PUSH, Y ; Words per sector
    
    ; We're going to decrement [Z] as we read words until it's 0
    
    ; We also increment X
    SET X, 0
    
    ; Load the file struct address
    SET B, [Z+2]
    ; And the FS volume struct address
    SET C, [B+BBFS_FILE_VOLUME]
    
    ; And the device address
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume to get device for
    JSR bbfs_volume_get_device
    SET C, POP
    
    ; And the sector size on the device
    SET PUSH, C ; Arg 1: device
    JSR bbfs_device_sector_size
    SET Y, POP
    
    ; Grab the sector we're supposed to be reading
    SET PUSH, C ; Arg 1: device
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector we want
    JSR bbfs_device_get
    SET I, POP
    ADD SP, 1
    
    IFE I, 0x0000
        ; Couldn't get the sector
        SET PC, .error_drive

    ; Point I at the word in the file buffer to read from
    ADD I, [B+BBFS_FILE_OFFSET]
    
    ; Point J at the data word to write
    SET J, [Z+1]
    
.read_until_depleted:
    IFE [Z], 0 ; No more words to read
        SET PC, .done_reading
    IFE [B+BBFS_FILE_OFFSET], Y
        ; We've used up our buffered sector
        SET PC, .go_to_next_sector
    IFE [B+BBFS_FILE_OFFSET], [B+BBFS_FILE_MAX_OFFSET]
        ; Our max offset isn't a full sector and we've depleted it.
        ; We know this has to be the last sector, so just say EOF.
        SET PC, .error_end_of_file
    
    ; Otherwise read a word from the buffer, and move both pointers
    STI [J], [I]
    ; Consume one word from our to-do list
    SUB [Z], 1
    ; And one word of this sector
    ADD [B+BBFS_FILE_OFFSET], 1
    ; Record that we successfully read a word
    ADD X, 1
    
    ; Loop around
    SET PC, .read_until_depleted
    
.go_to_next_sector:

    ; If we already have a next sector allocated, go to that one
    ; Look in the FAT at the current sector
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector
    JSR bbfs_volume_fat_get
    SET A, POP
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
   
    IFG A, 0x7FFF
        ; If the high bit is set, this was the last sector
        ; Maybe we filled it.
        SET PC, .error_end_of_file

    ; Now A holds the next sector
    ; Point the file at the start of the new sector
    SET [B+BBFS_FILE_SECTOR], A
    SET [B+BBFS_FILE_OFFSET], 0
    
    ; Load the number of words available to read in the sector from its FAT
    ; entry. We need to do this first because otherwise it would touch the
    ; device and invalidate the sector pointer.
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector
    JSR bbfs_volume_fat_get
    SET A, POP
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
    
    IFL A, 0x8000
        ; The high bit is unset, so this sector is not the last and is
        ; guaranteed to be full
        SET A, Y
    
    AND A, 0x7FFF ; Take everything but the high bit
    ; And say that that's the current file length within this sector.
    SET [B+BBFS_FILE_MAX_OFFSET], A 
    
    ; Load the sector from disk
    SET PUSH, C ; Arg 1: device
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector we want
    JSR bbfs_device_get
    SET I, POP
    ADD SP, 1
    
    IFE I, 0x0000
        ; Couldn't get the sector
        SET PC, .error_drive
    
    ; Keep reading
    SET PC, .read_until_depleted
    
.done_reading:
    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_end_of_file:
    ; Return the end of file error
    SET [Z], BBFS_ERR_EOF
    SET PC, .return
 
.error_stack:
    ; Return error on the stack
    SET [Z], POP
    SET PC, .return    
        
.error_drive:
    ; Couldn't get a sector pointer
    SET [Z], BBFS_ERR_DRIVE

.return:
    SET [Z+1], X ; Return words successfully read (before any error)
    SET Y, POP
    SET X, POP
    SET J, POP
    SET I, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

; bbfs_directory_open(*directory, *volume, drive_num, sector_num)
; Open an existing directory on disk,
; [Z+2]: BBFS_DIRECTORY to open into
; [Z+1]: BBFS_VOLUME for the filesystem
; [Z]: sector defining the directory's file.
; Returns: error code in [Z]
bbfs_directory_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBFS_DIRECTORY we're setting up
    SET PUSH, B ; BBFS_FILE for the directory
    SET PUSH, C ; BBFS_DIRHEADER we set up to read out
    
    SET A, [Z+2]
    
    ; Set B to the BBFS_FILE for the directory
    SET B, [Z+2]
    ADD B, BBFS_DIRECTORY_FILE
    
    ; Set C to a BBFS_DIRHEADER on the stack
    SUB SP, BBFS_DIRHEADER_SIZEOF
    SET C, SP
    
    ; Open the file
    SET PUSH, B ; Arg 1: BBFS_FILE to populate
    SET PUSH, [Z+1] ; Arg 2: BBFS_VOLUME for the filesystem
    SET PUSH, [Z] ; Arg 3: sector defining file
    JSR bbfs_file_open
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Read out the BBFS_DIRHEADER
    SET PUSH, B ; Arg 1: file
    SET PUSH, C ; Arg 2: destination
    SET PUSH, BBFS_DIRHEADER_SIZEOF ; Arg 3: word count
    JSR bbfs_file_read
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; Make sure we opened a directory
    IFN [C+BBFS_DIRHEADER_VERSION], BBFS_VERSION
        SET PC, .error_notdir
        
    ; Fill in the number of remaining entries
    SET [A+BBFS_DIRECTORY_CHILDREN_LEFT], [C+BBFS_DIRHEADER_CHILD_COUNT]
    
    ; We succeeded
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
.error_notdir:
    SET [Z], BBFS_ERR_NOTDIR
.return:
    ADD SP, BBFS_DIRHEADER_SIZEOF
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_directory_next(*directory, *entry)
; Get the next directory entry from an opened directory. If no entries are left,
; returns BBFS_ERR_EOF.
; [Z+1]: BBFS_DIRECTORY that has been opened
; [Z]: BBFS_DIRENTRY to populate
; Returns: error code in [Z]
bbfs_directory_next:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBFS_DIRECTORY
    
    SET A, [Z+1]
    
    ; Check to see if entries remain.
    IFE [A+BBFS_DIRECTORY_CHILDREN_LEFT], 0
        SET PC, .error_eof
        
    ; Decrement remaining entries
    SUB [A+BBFS_DIRECTORY_CHILDREN_LEFT], 1
    
    ; Read from the file into the entry struct
    SET PUSH, A ; Arg 1: file to read
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, [Z] ; Arg 2: place to read to
    SET PUSH, BBFS_DIRENTRY_SIZEOF ; Arg 3: words to read
    JSR bbfs_file_read
    SET [Z], POP
    ADD SP, 2
    
    ; Just return whatever error code we got when reading the file.
    SET PC, .return
.error_eof:
    SET [Z], BBFS_ERR_EOF
.return:
    SET A, POP
    SET Z, POP
    SET PC, POP
    
    
    
;; CONSTANTS
    

str_not_found_bl:
    .asciiz "BOOT.IMG not found"
str_found_bl:
    .asciiz "Loading BOOT.IMG"
str_intro_bl:
    .asciiz "UBM Bootloader 2.0"
str_copyright_bl:
    .asciiz "(C) UBM"
str_error_bl:
    .asciiz "Error"
packed_filename_bl:
    ; Packed version of the "BOOT.IMG" filename. 8 words is less than the unpack
    ; routine.
    DAT 0x424f
    DAT 0x4f54
    DAT 0x2e49
    DAT 0x4d47
    DAT 0x0000
    DAT 0x0000
    DAT 0x0000
    
payload_measure_end_bl:

