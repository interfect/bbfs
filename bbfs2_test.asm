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
    SET A, [SP]
    ADD SP, 2
    
    ; We should have no error
    IFN A, BBFS_ERR_NONE
        SET PC, fail
    
    ; Check sector count
    
    ; Check sector size

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
str_done:
    ASCIIZ "Done!"
str_fail:
    ASCIIZ "Failed!"

; Mark the end of the program data
program_end:

; Reserve space for the filesystem header
device:
RESERVE BBFS_DEVICE_SIZEOF

bootloader_code:
; Include the BBFS bootloader assembled code. On the final disk the bootloader
; code will still be sitting around in an unallocated sector
#include "bbfs_bootloader.asm"

