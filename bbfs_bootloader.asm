; Bootloader with just enough BBFS code to load a file.

; Keeps itself at a fixed address, so there's a limit to the amount of code it
; can load.

define BOOTLOADER_BASE 0xd000

#include "bbos.inc.asm"

; Consele API that we need
; Write Char              0x1003  Char, MoveCursor        None            1.0
; Write String            0x1004  StringZ, NewLine        None            1.0
define WRITE_CHAR 0x1003
define WRITE_STRING 0x1004

define GET_DRIVE_COUNT 0x2000
define CHECK_DRIVE_STATUS 0x2001
define GET_DRIVE_PARAMETERS 0x2002
define READ_DRIVE_SECTOR 0x2003
define WRITE_DRIVE_SECTOR 0x2004

; BBFS_HEADER: struct for the 3-sector header including bitmap and FAT
define BBFS_HEADER_SIZEOF 1536
define BBFS_HEADER_VERSION 0
define BBFS_HEADER_FREEMASK 6
define BBFS_HEADER_FAT 96

; BFFS_FILE: file handle structure
define BBFS_FILE_SIZEOF 517
define BBFS_FILE_DRIVE 0 ; BBOS Disk drive number that the file is on
define BBFS_FILE_FILESYSTEM_HEADER 1 ; Address of the BFFS_HEADER for the file
define BBFS_FILE_START_SECTOR 2 ; Sector that the file starts at
define BBFS_FILE_SECTOR 3 ; Sector currently in buffer
define BBFS_FILE_OFFSET 4 ; Offset in the sector (in words)
define BBFS_FILE_BUFFER 5 ; 512-word buffer for file data for the current sector

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

; Parameters

define BBFS_VERSION 0xBF56
define BBFS_SECTORS 1440
define BBFS_WORDS_PER_SECTOR 512
define BBFS_SECTOR_WORDS 90 ; Words for one sector per bit
define BBFS_FILENAME_BUFSIZE 17 ; Characters plus trailing null
define BBFS_FILENAME_PACKED 8 ; Packed 2 per word internally

; Error codes
define BBFS_ERR_NONE                0x0000
define BBFS_ERR_DRIVE               0x0005
define BBFS_ERR_DISC_FULL           0x0007
define BBFS_ERR_EOF                 0x0008
define BBFS_ERR_UNKNOWN             0x0009
define BBFS_ERR_NOTDIR              0x1001

; Directory constants
define BBFS_TYPE_DIRECTORY 0
define BBFS_TYPE_FILE 1


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

; Read the header
SET PUSH, B ; Arg 1: drive number
SET PUSH, STATIC_HEADER_BL ; Arg 2: BBFS_HEADER
JSR bbfs_drive_load_bl
ADD SP, 2

; Open the directory
SET PUSH, STATIC_DIRECTORY_BL ; Arg 1: BBFS_DIRECTORY
SET PUSH, STATIC_HEADER_BL ; Arg 2: BBFS_HEADER
SET PUSH, B ; Arg 3: drive number
SET PUSH, 4 ; Arg 4: directory start sector (4 for root dir)
JSR bbfs_directory_open_bl
ADD SP, 4

dir_entry_loop_bl:
    ; Load an entry
    SET PUSH, STATIC_DIRECTORY_BL
    SET PUSH, STATIC_DIRENTRY_BL
    JSR bbfs_directory_next_bl
    SET A, POP
    ADD SP, 1
    IFE A, BBFS_ERR_EOF
        ; We didn't find our file to boot
        SET PC, file_not_found_bl
        
    ; Call the comparison routine
    SET PUSH, STATIC_DIRENTRY_BL ; Arg 1: first packed filename
    ADD [SP], BBFS_DIRENTRY_NAME
    SET PUSH, packed_filename_bl ; Arg 2: second packed filename
    JSR bbfs_filename_compare_bl
    SET A, POP
    ADD SP, 1
    
    IFE A, 0
        ; This wasn't a match. Loop until found.
        SET PC, dir_entry_loop_bl
        
; If we get here, we just need to read until EOF.

; Say we found the file
SET PUSH, str_found_bl
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

; Save the sector that the file starts at in C
SET C, [STATIC_DIRENTRY_BL+BBFS_DIRENTRY_SECTOR]

; Open the file
SET PUSH, STATIC_FILE_BL ; Arg 1: file to open into
SET PUSH, STATIC_HEADER_BL ; Arg 2: FS header
SET PUSH, B ; Arg 3: drive to read from
SET PUSH, C ; Arg 4: sector to start at
JSR bbfs_file_open_bl
ADD SP, 4

SET C, 0 ; This will now be the address we're reading to
    
load_loop_bl:
    ; Read a sector
    SET PUSH, STATIC_FILE_BL ; Arg 1: file to read
    SET PUSH, C ; Arg 2: place to read to
    SET PUSH, BBFS_WORDS_PER_SECTOR ; Arg 3: words to read. 
    ; We happen to know a file can't EOF in the middle of a sector.
    JSR bbfs_file_read_bl
    SET A, POP
    ADD SP, 2
    
    ; Else increment destination and loop
    ADD C, BBFS_WORDS_PER_SECTOR
    
    IFE A, BBFS_ERR_EOF
        ; Loop and read another sector
        SET PC, load_done_bl
    IFN A, BBFS_ERR_NONE
        ; We hit some other error
        SET PC, error_bl
    
    ; Keep loading
    SET PC, load_loop_bl
        
load_done_bl:
    ; If we hit EOF, jump to 0
    SET PUSH, str_jump_bl
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, 0

file_not_found_bl:
    SET PUSH, str_not_found_bl
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, halt_bl
    
error_bl:
    SET PUSH, str_error_bl
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
halt_bl:
    SET PC, halt_bl


; bbfs_drive_load(drive_num, header*)
; Load header info from the given drive to the given address.
; [Z+1]: BBOS drive to operate on
; [Z]: BBFS_HEADER to operate on
bbfs_drive_load_bl:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    ; We loop 0, 1, 2 and load sectors 1, 2, 3    
    SET PUSH, A ; BBOS command
    SET PUSH, B ; Loop index
    SET PUSH, C ; offset into header
    
    SET B, 0
.loop:
    ; Calculate offset to write to
    SET C, B
    MUL C, BBFS_WORDS_PER_SECTOR
    ; Then offset from the header start
    ADD C, [Z]
    
    ; Read the sector
    SET PUSH, B ; Arg 1: Sector to read
    ADD [SP], 1
    SET PUSH, C ; Arg 2: Pointer to read to
    SET PUSH, [Z+1] ; Arg 3: drive number
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ; TODO: We assume success
    ADD SP, 3 
    
    ; Loop through 0, 1, and 2
    ADD B, 1
    IFL B, 3
        SET PC, .loop
.loop_break:
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

; bbfs_file_open(*file, *header, drive_num, sector_num)
; Open an existing file at the given sector on the given drive, and populate the
; file handle.
; [Z+3]: BBFS_FILE to populate
; [Z+2]: BBFS_HEADER to use
; [Z+1]: BBOS drive number
; [Z]: Sector at which the file starts
; Returns: error code in [Z]
bbfs_file_open_bl:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Holds the file struct address
    
    ; Grab the file struct
    SET A, [Z+3]

    ; Populate the file struct
    ; Fill in the drive
    SET [A+BBFS_FILE_DRIVE], [Z+1]
    ; And header address
    SET [A+BBFS_FILE_FILESYSTEM_HEADER], [Z+2]
    ; And the sector indexes
    SET [A+BBFS_FILE_START_SECTOR], [Z]
    SET [A+BBFS_FILE_SECTOR], [Z]
    ; And zero the offset
    SET [A+BBFS_FILE_OFFSET], 0
    
    ; Read the right sector into the file struct's buffer. This clobbers A
    SET PUSH, [Z] ; Arg 1: Sector to read
    SET PUSH, A ; Arg 2: Pointer to read to
    ADD [SP], BBFS_FILE_BUFFER
    SET PUSH, [A+BBFS_FILE_DRIVE] ; Arg 3: Drive to read from
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ; TODO: handle drive errors
    ADD SP, 3

    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_read(*file, *data, size)
; Read the given number of words from the given file into the given buffer.
; [Z+2]: BBFS_FILE to read from
; [Z+1]: Buffer to read into
; [Z]: Number of words to read
; Returns: error code in [Z]
bbfs_file_read_bl:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS calls, scratch
    SET PUSH, B ; File struct address
    SET PUSH, C ; Filesystem header struct address
    SET PUSH, I ; Pointer into file buffer
    SET PUSH, J ; Pointer into data
    
    ; We're going to decrement [Z] as we read words until it's 0
    
    ; Load the file struct address
    SET B, [Z+2]
    ; And the FS header struct address
    SET C, [B+BBFS_FILE_FILESYSTEM_HEADER]
    ; Point I at the word in the file buffer to read from
    SET I, B
    ADD I, BBFS_FILE_BUFFER
    ADD I, [B+BBFS_FILE_OFFSET]
    ; Point J at the data word to write
    SET J, [Z+1]
    
.read_until_depleted:
    IFE [Z], 0 ; No more words to read
        SET PC, .done_reading
    IFE [B+BBFS_FILE_OFFSET], BBFS_WORDS_PER_SECTOR
        ; We've filled up our buffered sector
        SET PC, .go_to_next_sector
    
    ; Otherwise read a word from the buffer, and move both pointers
    STI [J], [I]
    ; Consume one word from our to-do list
    SUB [Z], 1
    ; And one word of this sector
    ADD [B+BBFS_FILE_OFFSET], 1
    
    ; Loop around
    SET PC, .read_until_depleted
    
.go_to_next_sector:

    ; If we have a next sector allocated, go to that one
    ; Look in the FAT at the current sector
    SET A, C
    ADD A, BBFS_HEADER_FAT
    ADD A, [B+BBFS_FILE_SECTOR]
    
    IFE [A], 0xFFFF
        ; Otherwise, the file is over
        SET PC, .error_end_of_file
    
    ; Now [A] holds the next sector
    ; Point the file at the start of the new sector
    SET [B+BBFS_FILE_SECTOR], [A]
    SET [B+BBFS_FILE_OFFSET], 0
    
    ; Load it from disk
    ; Clobber A with the BBOS call
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 1: Sector to read
    SET PUSH, B ; Arg 2: Pointer to write to
    ADD [SP], BBFS_FILE_BUFFER
    SET PUSH, [B+BBFS_FILE_DRIVE] ; Arg 3: Drive to read from
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    SET A, POP
    ADD SP, 2
    
    ; Handle drive errors
    IFE A, 0
        SET PC, .error_drive
    
    ; Move the cursor back to the start of the buffer
    SET I, B
    ADD I, BBFS_FILE_BUFFER
    ADD I, [B+BBFS_FILE_OFFSET]
    
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
    
.error_drive:
    ; Return drive error
    SET [Z], BBFS_ERR_DRIVE

.return:
    SET J, POP
    SET I, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_directory_open(*directory, *header, drive_num, sector_num)
; Open an existing directory on disk,
; [Z+3]: BBFS_DIRECTORY to open into
; [Z+2]: BBFS_HEADER for the filesystem
; [Z+1]: drive number to open from
; [Z]: sector defining the directory's file.
; Returns: error code in [Z]
bbfs_directory_open_bl:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBFS_DIRECTORY we're setting up
    SET PUSH, B ; BBFS_FILE for the directory
    SET PUSH, C ; BBFS_DIRHEADER we set up to read out
    
    SET A, [Z+3]
    
    ; Set B to the BBFS_FILE for the directory
    SET B, [Z+3]
    ADD B, BBFS_DIRECTORY_FILE
    
    ; Set C to a BBFS_DIRHEADER on the stack
    SUB SP, BBFS_DIRHEADER_SIZEOF
    SET C, SP
    
    ; Open the file
    SET PUSH, B ; Arg 1: BBFS_FILE to populate
    SET PUSH, [Z+2] ; Arg 2: BBFS_HEADER for the filesystem
    SET PUSH, [Z+1] ; Arg 3: drive number
    SET PUSH, [Z] ; Arg 4: sector defining file
    JSR bbfs_file_open_bl
    SET [Z], POP
    ADD SP, 3
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Read out the BBFS_DIRHEADER
    SET PUSH, B ; Arg 1: file
    SET PUSH, C ; Arg 2: destination
    SET PUSH, BBFS_DIRHEADER_SIZEOF ; Arg 3: word count
    JSR bbfs_file_read_bl
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; Make sure we opened a directory
    IFN [C+BBFS_DIRHEADER_VERSION], BBFS_VERSION
        SET PC, .error_notdir
        
    ; Fill in the number of remaining entries
    SET [A+BBFS_DIRECTORY_CHILDREN_LEFT] [C+BBFS_DIRHEADER_CHILD_COUNT]
    
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
bbfs_directory_next_bl:
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
    JSR bbfs_file_read_bl
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
    
; bbfs_filename_compare(*packed1, *packed2)
; Return 1 if the packed filenames match, 0 otherwise.
; [Z+1]: Filename 1
; [Z]: Filename 2
; Return: 1 for match or 0 for mismatch in [Z]
bbfs_filename_compare_bl:
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Filename 1 addressing
    SET PUSH, B ; Filename 2 addressing
    SET PUSH, C ; Character counter
    
    SET A, [Z+1] ; Load string 1
    SET B, [Z] ; And string 2
    
    SET C, 0
.loop:
    IFN [A], [B]
        SET PC, .unequal
    ADD A, 1
    ADD B, 1
    ADD C, 1
    IFL C, BBFS_FILENAME_PACKED
        SET PC, .loop
    
    ; If we get here they're equal
    SET [Z], 1
    SET PC, .return
    
.unequal:
    SET [Z], 0
.return:
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
str_not_found_bl:
    ASCIIZ "BOOT.IMG not found"
str_found_bl:
    ASCIIZ "Loading BOOT.IMG"
str_intro_bl:
    ASCIIZ "BBFSBoot 0.1"
str_copyright_bl:
    ASCIIZ "(C) APIGA AUTONOMICS"
str_jump_bl:
    ASCIIZ "Launching"
str_error_bl:
    ASCIIZ "Error"
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

; We statically allocate a directory, a direntry, and a file, but don't incluse
; them in our image. We can't use labels in the defines; they all act like 0.
; Instead we just place it safely one sector after the fixed bootloader address.
define STATIC_DIRECTORY_BL BOOTLOADER_BASE+BBFS_WORDS_PER_SECTOR
define STATIC_FILE_BL STATIC_DIRECTORY_BL+BBFS_DIRECTORY_SIZEOF
define STATIC_DIRENTRY_BL STATIC_FILE_BL+BBFS_FILE_SIZEOF
define STATIC_HEADER_BL STATIC_DIRENTRY_BL+BBFS_DIRENTRY_SIZEOF



