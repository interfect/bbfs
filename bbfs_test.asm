; bbfs_test.asm
; Test the BBFS file system

; Consele API that we need
; Write Char              0x1003  Char, MoveCursor        None            1.0
; Write String            0x1004  StringZ, NewLine        None            1.0
define WRITE_CHAR 0x1003
define WRITE_STRING 0x1004

define BUFFER_SIZE 0x100

; What's the BBOS bootloader magic number?
define BBOS_BOOTLOADER_MAGIC 0x55AA
define BBOS_BOOTLOADER_MAGIC_POSITION 511

.org 0

start:
    ; Say we're opening a device
    SET PUSH, str_device_open
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Open the device
    SET PUSH, device ; Arg 1: device to construct
    SET PUSH, 0 ; Arg 2: drive to work on (0)
    JSR bbfs_device_open
    SET A, POP
    ADD SP, 1
    
    ; We should have no error
    IFN A, BBFS_ERR_NONE
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
    
    ; It may be unformatted but otherwise should be OK.
    IFN A, BBFS_ERR_UNFORMATTED
        IFN A, BBFS_ERR_NONE
            SET PC, fail
    
    ; Say we're formatting
    SET PUSH, str_formatting
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Format the volume
    SET PUSH, volume
    JSR bbfs_volume_format
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, fail
    
    ; Say we're looking for a free sector
    SET PUSH, str_find_free
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Find a free sector and keep it in A for debugging
    SET PUSH, volume
    JSR bbfs_volume_find_free_sector
    SET A, POP
    
    ; It should always be sector 4 (after the 4 reserved for boot and FS)
    IFN A, 4
        SET PC, fail
        
    ; Say we're making a file
    SET PUSH, str_creating_file
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
        
    ; Say we're looking for a free sector
    SET PUSH, str_find_free
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Find a free sector and keep it in A for debugging
    SET PUSH, volume
    JSR bbfs_volume_find_free_sector
    SET A, POP
    
    ; It should always be sector 5 (after the 4 reserved for boot and FS and the
    ; 1 just taken)
    IFN A, 5
        SET PC, fail
       
    ; Say we're writing to the file
    SET PUSH, str_write_file
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Write to the file 100 times
    SET B, 100
write_loop:
    ; Write to the file
    SET PUSH, file
    SET PUSH, str_file_contents
    SET PUSH, 25
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    SUB B, 1
    IFN B, 0
        SET PC, write_loop
        
    ; Say we're flushing to disk
    SET PUSH, str_flush
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
        
    ; Flush the file to disk
    SET PUSH, file
    JSR bbfs_file_flush
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, fail
    
    ; Say we're going to open
    SET PUSH, str_open
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
        
    ; Get the sector the file started at
    SET A, file
    ADD A, BBFS_FILE_START_SECTOR
    SET A, [A]
    ; Open the file again to go back to the start
    SET PUSH, file
    SET PUSH, volume
    SET PUSH, A
    JSR bbfs_file_open
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Say we're going to reoopen
    SET PUSH, str_reopen
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
        
    ; Reopen it just for fun
    SET PUSH, file
    JSR bbfs_file_reopen
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, fail
    
    ; Say we're going to read
    SET PUSH, str_read
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Read some data
    SET PUSH, file
    SET PUSH, buffer
    SET PUSH, BUFFER_SIZE
    JSR bbfs_file_read
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Write it out (until the first null)
    SET PUSH, buffer
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Say we're going to skip
    SET PUSH, str_skip
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Skip ahead
    SET PUSH, file
    SET PUSH, 513
    JSR bbfs_file_seek
    SET A, POP
    ADD SP, 1
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; The offset should now be 0x100 we read plus 1 we skipped, but in the next
    ; sector
    SET A, file
    ADD A, BBFS_FILE_OFFSET
    IFN [A], 257
        SET PC, fail
    SET A, file
    ADD A, BBFS_FILE_SECTOR
    IFN [A], 5
        SET PC, fail
        
    ; Say we're going to truncate
    SET PUSH, str_truncate
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Truncate to this sector
    SET PUSH, file
    JSR bbfs_file_truncate
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Say we're writing to the file
    SET PUSH, str_write_file
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Write in some new data instead.
    SET PUSH, file
    SET PUSH, str_file_contents2
    SET PUSH, 15
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Flush the file to disk
    SET PUSH, file
    JSR bbfs_file_flush
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Say we're deleting the file
    SET PUSH, str_delete_file
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Actually delete it
    SET PUSH, file
    JSR bbfs_file_delete
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Say we're making a directory
    SET PUSH, str_mkdir
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Create a directory
    SET PUSH, directory
    SET PUSH, volume
    JSR bbfs_directory_create
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Make a toy file
    
    ; Say we're making a file
    SET PUSH, str_creating_file
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Make a file
    SET PUSH, file
    SET PUSH, volume
    JSR bbfs_file_create
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Populate an entry for it in the directory
    SET [entry+BBFS_DIRENTRY_TYPE], BBFS_TYPE_FILE
    SET [entry+BBFS_DIRENTRY_SECTOR], [file+BBFS_FILE_START_SECTOR]
    
    ; Pack in a filename
    SET PUSH, str_filename ; Arg 1: string to pack
    SET PUSH, entry ; Arg 2: place to pack it
    ADD [SP], BBFS_DIRENTRY_NAME
    JSR bbfs_filename_pack
    ADD SP, 2
    
    ; Add the entry to the directory
    ; Say we're doing it
    SET PUSH, str_linking_file
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Do it
    SET PUSH, directory
    SET PUSH, entry
    JSR bbfs_directory_append
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
        
    ; Copy the running program into the file with a giant write call
    ; Announce it
    SET PUSH, str_saving_memory
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Make the write call
    SET PUSH, file
    SET PUSH, 0
    SET PUSH, program_end
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; And flush
    SET PUSH, file
    JSR bbfs_file_flush
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, fail
    
    ; Open the directory
    ; Announce it
    SET PUSH, str_opening_directory
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    ; Do it
    SET PUSH, directory ; Arg 1: directory
    SET PUSH, volume ; Arg 2: BBFS_VOLUME
    ; Arg 3: sector
    SET PUSH, [directory+BBFS_DIRECTORY_FILE+BBFS_FILE_START_SECTOR]
    JSR bbfs_directory_open
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Say we're listing the directory
    SET PUSH, str_listing_directory
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    ; Read entries out
dir_entry_loop:
    ; Read the next entry
    SET PUSH, directory
    SET PUSH, entry
    JSR bbfs_directory_next
    SET A, POP
    ADD SP, 1
    IFE A, BBFS_ERR_EOF
        ; If we have run out, stop looping
        SET PC, dir_entry_loop_done
    IFN A, BBFS_ERR_NONE
        ; On any other error, fail
        SET PC, fail
    
    SET PUSH, str_entry
    SET PUSH, 0 ; No newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Unpack the filename
    SET PUSH, filename ; Arg 1: unpacked filename
    SET PUSH, entry ; Arg 2: packed filename
    ADD [SP], BBFS_DIRENTRY_NAME
    JSR bbfs_filename_unpack
    ADD SP, 2
    
    ; Print the filename
    SET PUSH, filename
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Loop until EOF
    SET PC, dir_entry_loop
    
dir_entry_loop_done:

    SET PUSH, str_newline
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Now see if we have the bootloader code
    IFE [bootloader_code], 0
        SET PC, no_bootloader
        
    ; Say we're installing the bootloader
    SET PUSH, str_bootloader
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Install the bootloader
    ; First set its magic word
    SET [bootloader_code+BBOS_BOOTLOADER_MAGIC_POSITION], BBOS_BOOTLOADER_MAGIC
    
    ; Then make a raw BBOS call to stick it as the first sector of drive 0
    SET PUSH, 0 ; Arg 1: sector
    SET PUSH, bootloader_code ; Arg 2: pointer
    SET PUSH, 0 ; Arg 3: drive number
    SET A, WRITE_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ADD SP, 3
        
no_bootloader:

    ; Add an extra entry to the directory
    ; Say we're doing it
    SET PUSH, str_linking_file
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Populate the entry again
    SET [entry+BBFS_DIRENTRY_TYPE], BBFS_TYPE_FILE
    SET [entry+BBFS_DIRENTRY_SECTOR], [file+BBFS_FILE_START_SECTOR]
    
    ; Pack in a filename
    SET PUSH, str_filename2 ; Arg 1: string to pack
    SET PUSH, entry ; Arg 2: place to pack it
    ADD [SP], BBFS_DIRENTRY_NAME
    JSR bbfs_filename_pack
    ADD SP, 2
    
    ; Put in the entry
    SET PUSH, directory
    SET PUSH, entry
    JSR bbfs_directory_append
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, fail
        
    ; Now remove the old entry
    ; Say we're doing it
    SET PUSH, str_unlinking_file
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Do it
    SET PUSH, directory ; Arg 1: BBFS_DIRECTORY to modify
    SET PUSH, 0 ; Arg 2: entry index to delete
    JSR bbfs_directory_remove
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, fail

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
str_volume_open:
    ASCIIZ "Opening volume..."
str_formatting:
    ASCIIZ "Formatting..."
str_loading:
    ASCIIZ "Loading..."
str_saving:
    ASCIIZ "Saving..."
str_find_free:
    ASCIIZ "Find free sector..."
str_creating_file:
    ASCIIZ "Creating file..."
str_write_file:
    ASCIIZ "Writing to file..."
str_file_contents: 
    ASCIIZ "This goes into the file!"
str_flush:
    ASCIIZ "Flushing to disk..."
str_open:
    ASCIIZ "Opening file..."
str_reopen:
    ASCIIZ "Returning to start..."
str_read:
    ASCIIZ "Reading data..."
str_skip:
    ASCIIZ "Seeking ahead..."
str_truncate:
    ASCIIZ "Truncating..."
str_file_contents2: 
    ASCIIZ "NEWDATANEWDATA"
str_delete_file:
    ASCIIZ "Deleting..."
str_mkdir:
    ASCIIZ "Creating directory..."
str_filename:
    ASCIIZ "IMG.BIN"
str_linking_file:
    ASCIIZ "Adding directory entry..."
str_saving_memory:
    ASCIIZ "Saving program image to disk..."
str_opening_directory:
    ASCIIZ "Opening directory..."
str_listing_directory:
    ASCIIZ "Listing directory..."
str_entry:
    ASCIIZ "Entry: "
str_newline:
    DAT 0
str_bootloader:
    ASCIIZ "Installing bootloader..."
str_filename2:
    ASCIIZ "BOOT.IMG"
str_unlinking_file:
    ASCIIZ "Removing directory entry..."
str_done:
    ASCIIZ "Done!"
str_fail:
    ASCIIZ "Failed!"

; Mark the end of the program data
program_end:

; Reserve space for the filesystem stuff
device:
RESERVE BBFS_DEVICE_SIZEOF
volume:
RESERVE BBFS_VOLUME_SIZEOF
file:
RESERVE BBFS_FILE_SIZEOF
buffer:
RESERVE BUFFER_SIZE
directory:
RESERVE BBFS_DIRECTORY_SIZEOF
entry:
RESERVE BBFS_DIRENTRY_SIZEOF
filename:
RESERVE BBFS_FILENAME_BUFSIZE

bootloader_code:
; Include the BBFS bootloader assembled code. On the final disk the bootloader
; code will still be sitting around in an unallocated sector
#include "bbfs_bootloader.asm"

