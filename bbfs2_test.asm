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
    
    ; We should have no error
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    SET PUSH, str_sector_count
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Check sector count
    SET PUSH, device
    JSR bbfs_device_sector_count
    SET A, POP
    
    ; Should be 1440 sectors on a floppy
    IFN A, 1440
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
    
    ; Should be 512 words on a floppy
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
    ASCIIZ "Opening device..."
str_sector_count:
    ASCIIZ "Checking sector count..."
str_sector_size:
    ASCIIZ "Checking sector size..."
str_device_get:
    ASCIIZ "Load sector..."
str_device_sync:
    ASCIIZ "Syncing to disk..."
str_array_open:
    ASCIIZ "Making disk-backed array..."
str_array_set:
    ASCIIZ "Setting array values..."
str_array_get:
    ASCIIZ "Getting array values..."
str_volume_open:
    ASCIIZ "Opening volume..."
str_volume_format:
    ASCIIZ "Formatting volume..."
str_done:
    ASCIIZ "Done!"
str_fail:
    ASCIIZ "Failed!"

; Mark the end of the program data
program_end:

; Reserve space for the filesystem header
device:
RESERVE BBFS_DEVICE_SIZEOF
array:
RESERVE BBFS_ARRAY_SIZEOF
volume:
RESERVE BBFS_VOLUME_SIZEOF

bootloader_code:
; Include the BBFS bootloader assembled code. On the final disk the bootloader
; code will still be sitting around in an unallocated sector
#include "bbfs_bootloader.asm"

