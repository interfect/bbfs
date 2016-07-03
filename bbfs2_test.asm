; bbfs2_test.asm
; Test the new resizeable BBFS implementation

; Consele API that we need
; Write Char              0x1003  Char, MoveCursor        None            1.0
; Write String            0x1004  StringZ, NewLine        None            1.0
define WRITE_CHAR 0x1003
define WRITE_STRING 0x1004

; What's the BBOS bootloader magic number?
define BBOS_BOOTLOADER_MAGIC 0x55AA
define BBOS_BOOTLOADER_MAGIC_POSITION 511

.org 0

; On start, drive number we loaded from is in A. Put it in B.
SET B, A

start:
    ; Say we're opening a device
    SET PUSH, str_device_open
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Open the device
    SET PUSH, device ; Arg 1: device to construct
    SET PUSH, B ; Arg 2: drive to work on
    JSR bbfs_device_open
    SET A, POP
    ADD SP, 1
    
    ; TODO: no error return code provided
        
    SET PUSH, str_sector_count
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Check sector count
    SET PUSH, device
    JSR bbfs_device_sector_count
    SET A, POP
    
    ; Should be 1440 sectors on a floppy, and 5120 on an HDD
    IFN A, 1440
        IFN A, 5120
            SET PC, fail
    
    SET PUSH, str_sector_size
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Check sector size
    SET PUSH, device
    JSR bbfs_device_sector_size
    SET A, POP
    
    ; Should be 512 words on a floppy or an HDD
    IFN A, 512
        SET PC, fail
        
    SET PUSH, str_device_get
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
        
    ; Grab sector 0
    SET PUSH, device
    SET PUSH, 0
    JSR bbfs_device_get
    SET A, POP
    ADD SP, 1
    
    IFE A, 0x0000
        ; Couldn't get it
        SET PC, fail
    
    IFN [A+511], 0x55AA
        ; Not a real bootloader
        SET PC, fail
        
    SET PUSH, str_device_sync
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Commit changes, if any
    SET PUSH, device
    JSR bbfs_device_sync
    SET A, POP
        
    IFN A, BBFS_ERR_NONE
        ; It didn't work
        SET PC, fail
        
    ; Say we're making an array
    SET PUSH, str_array_open
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Make it
    SET PUSH, array ; Arg 1: array
    SET PUSH, device ; Arg 2: device
    SET PUSH, 1000 ; Arg 3: base sector
    JSR bbfs_array_open
    ADD SP, 3
    ; Can't fail
    
    ; Now write some words
    SET PUSH, str_array_set
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Try 0
    SET PUSH, array ; Arg 1: array
    SET PUSH, 0 ; Arg 2: offset to write to
    SET PUSH, 0xF00 ; Arg 3: value to set
    JSR bbfs_array_set
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; And 1
    SET PUSH, array ; Arg 1: array
    SET PUSH, 1 ; Arg 2: offset to write to
    SET PUSH, 0xCAFE ; Arg 3: value to set
    JSR bbfs_array_set
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; And 512
    SET PUSH, array ; Arg 1: array
    SET PUSH, 512 ; Arg 2: offset to write to
    SET PUSH, 0xBABE ; Arg 3: value to set
    JSR bbfs_array_set
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; And 1000
    SET PUSH, array ; Arg 1: array
    SET PUSH, 1000 ; Arg 2: offset to write to
    SET PUSH, 0xCCCC ; Arg 3: value to set
    JSR bbfs_array_set
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Then check them
    SET PUSH, str_array_get
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Read 0
    SET PUSH, array ; Arg 1: array
    SET PUSH, 0 ; Arg 2: offset to read from
    JSR bbfs_array_get
    SET A, POP ; value
    SET B, POP ; error code

    IFN B, BBFS_ERR_NONE
        SET PC, fail
    IFN A, 0xF00
        SET PC, fail
        
     ; And 1
    SET PUSH, array ; Arg 1: array
    SET PUSH, 1 ; Arg 2: offset to read from
    JSR bbfs_array_get
    SET A, POP ; value
    SET B, POP ; error code

    IFN B, BBFS_ERR_NONE
        SET PC, fail
    IFN A, 0xCAFE
        SET PC, fail
        
    ; And 512
    SET PUSH, array ; Arg 1: array
    SET PUSH, 512 ; Arg 2: offset to read from
    JSR bbfs_array_get
    SET A, POP ; value
    SET B, POP ; error code

    IFN B, BBFS_ERR_NONE
        SET PC, fail
    IFN A, 0xBABE
        SET PC, fail
        
    ; And 1000
    SET PUSH, array ; Arg 1: array
    SET PUSH, 1000 ; Arg 2: offset to read from
    JSR bbfs_array_get
    SET A, POP ; value
    SET B, POP ; error code

    IFN B, BBFS_ERR_NONE
        SET PC, fail
    IFN A, 0xCCCC
        SET PC, fail
    
    ; Open up the disk as a volume
    SET PUSH, str_volume_open
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Do it
    SET PUSH, volume ; Arg 1: volume
    SET PUSH, device ; Arg 2: device
    JSR bbfs_volume_open
    SET A, POP
    ADD SP, 1
    
    ; It should be unformatted but otherwise OK.
    IFN A, BBFS_ERR_UNFORMATTED
        SET PC, fail
        
    ; We should have gotten the right parameters for a floppy
    ; Should be compatible with old implementation
    IFN [volume+BBFS_VOLUME_FREEMASK_START], 6
        SET PC, fail
    IFN [volume+BBFS_VOLUME_FAT_START], 96
        SET PC, fail
    IFN [volume+BBFS_VOLUME_FIRST_USABLE_SECTOR], 4
        SET PC, fail
        
    ; Now format the disk
    SET PUSH, str_volume_format
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Do it
    SET PUSH, volume ; Arg 1: volume
    JSR bbfs_volume_format
    SET A, POP
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Now find a free sector
    SET PUSH, str_volume_find_free
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, volume ; Arg 1: volume
    JSR bbfs_volume_find_free_sector
    SET A, POP
    
    IFN A, 4 ; First free sector on a floppy should be 4
        SET PC, fail
        
    ; Now set something in the FAT
    SET PUSH, str_volume_fat_set
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, volume ; Arg 1: volume
    SET PUSH, 1 ; Arg 2: sector
    SET PUSH, 0xFACE ; Arg 3: FAT value
    JSR bbfs_volume_fat_set
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Now get it back
    SET PUSH, str_volume_fat_get
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, volume ; Arg 1: volume
    SET PUSH, 1 ; Arg 2: sector
    JSR bbfs_volume_fat_get
    SET A, POP
    SET B, POP
    
    IFN B, BBFS_ERR_NONE
        SET PC, fail
        
    IFN A, 0xFACE
        ; We didn't get what we put
        SET PC, fail

    ; Make sure we can get a volume's device
    SET PUSH, str_volume_device
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, volume ; Arg 1: volume
    JSR bbfs_volume_get_device
    SET A, POP
    
    IFN A, device
        SET PC, fail
        
    ; Say we're making a file
    SET PUSH, str_file_create
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Make a file
    SET PUSH, file
    SET PUSH, volume
    JSR bbfs_file_create
    SET A, POP
    ADD SP, 1
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Write to it
    SET PUSH, str_file_write
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, file ; Arg 1: BBFS_FILE to write to
    SET PUSH, str_file_contents ; Arg 2: Address to get data from
    SET PUSH, file_contents_end-str_file_contents ; Arg 3: number of words to write
    ; Returns: error code in [Z]
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
     ; Say we're flushing it
    SET PUSH, str_file_flush
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Flush
    SET PUSH, file
    JSR bbfs_file_flush
    SET A, POP
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Repoen it
    SET PUSH, str_file_reopen
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, file
    JSR bbfs_file_reopen
    SET A, POP
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Seek ahead
    SET PUSH, str_file_seek
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, file ; Arg 1: file
    SET PUSH, 177 ; Arg 2: distance
    JSR bbfs_file_seek
    SET A, POP
    ADD SP, 1
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Read from it
    SET PUSH, str_file_read
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, file ; Arg 1: file
    SET PUSH, read_buffer ; Arg 2: buffer
    SET PUSH, 131 ; Arg 3: characters
    JSR bbfs_file_read 
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Null-terminate string
    SET [read_buffer+132], 0
    
    ; Print it
    SET PUSH, read_buffer
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
        
    ; Delete it
    SET PUSH, str_file_delete
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Delete
    SET PUSH, file
    JSR bbfs_file_delete
    SET A, POP
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail

close:
    ; Now close up
    SET PUSH, str_device_sync
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    
    ; Commit changes, if any
    SET PUSH, device
    JSR bbfs_device_sync
    SET A, POP
        
    IFN A, BBFS_ERR_NONE
        ; It didn't work
        SET PC, fail
       
done:
        
    ; Say we're done
    SET PUSH, str_done
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
halt:
    SET PC, halt
    
fail:
    ; Say we failed something
    SET PUSH, str_fail
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, halt
    
#include "bbfs.asm"

; Strings
str_device_open:
    .asciiz "Opening device..."
str_sector_count:
    .asciiz "Checking sector count..."
str_sector_size:
    .asciiz "Checking sector size..."
str_device_get:
    .asciiz "Load sector..."
str_device_sync:
    .asciiz "Syncing to disk..."
str_array_open:
    .asciiz "Making disk-backed array..."
str_array_set:
    .asciiz "Setting array values..."
str_array_get:
    .asciiz "Getting array values..."
str_volume_open:
    .asciiz "Opening volume..."
str_volume_format:
    .asciiz "Formatting volume..."
str_volume_find_free:
    .asciiz "Find free sector..."
str_volume_fat_set:
    .asciiz "Setting FAT entry..."
str_volume_fat_get:
    .asciiz "Getting FAT entry..."
str_volume_device:
    .asciiz "Getting volume device..."
str_file_create:
    .asciiz "Creating file..."
str_file_write:
    .asciiz "Writing to file..."
str_file_flush:
    .asciiz "Flushing..."
str_file_reopen:
    .asciiz "Re-opening file..."
str_file_seek:
    .asciiz "Seeking..."
str_file_read:
    .asciiz "Reading..."
str_file_delete:
    .asciiz "Deleting file..."
str_done:
    .asciiz "Done!"
str_fail:
    .asciiz "Failed!"

str_file_contents:
    .asciiz "Four score and seven years ago our fathers brought forth on this continent, a new nation, conceived in Liberty, and dedicated to the proposition that all men are created equal. Now we are engaged in a great civil war, testing whether that nation, or any nation so conceived and so dedicated, can long endure. We are met on a great battle-field of that war. We have come to dedicate a portion of that field, as a final resting place for those who here gave their lives that that nation might live. It is altogether fitting and proper that we should do this."
file_contents_end:

; Mark the end of the program data
program_end:

; Reserve space for the filesystem header
device:
.reserve BBFS_DEVICE_SIZEOF
array:
.reserve BBFS_ARRAY_SIZEOF
volume:
.reserve BBFS_VOLUME_SIZEOF
file:
.reserve BBFS_FILE_SIZEOF
read_buffer:
.reserve 512

bootloader_code:
; Include the BBFS bootloader assembled code. On the final disk the bootloader
; code will still be sitting around in an unallocated sector
#include "bbfs_bootloader.asm"

