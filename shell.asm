; shell.asm: command shell for loading commands off of a BBFS disk.

; BBOS functions
;Set Cursor Pos          0x1001  X, Y                    None            1.0
;Get Cursor Pos          0x1002  OUT X, OUT Y            Y, X            1.0
;Write Char              0x1003  Char, MoveCursor        None            1.0
;Write String            0x1004  StringZ, NewLine        None            1.0
;Scroll Screen           0x1005  Num lines to scroll     None            1.0
;Get Screen Size         0x1006  OUT Width, OUT Height   Height, Width   1.0
define SET_CURSOR_POS   0x1001
define GET_CURSOR_POS   0x1002
define WRITE_CHAR       0x1003
define WRITE_STRING     0x1004
define SCROLL_SCREEN    0x1005
define GET_SCREEN_SIZE  0x1006
;Read Character          0x3001  Blocking                Char            1.0
define READ_CHARACTER   0x3001
; Get Drive Count         0x2000  OUT Drive Count         Drive Count     1.0
; Check Drive Status      0x2001  DriveNum                StatusCode      1.0
define GET_DRIVE_COUNT 0x2000
define CHECK_DRIVE_STATUS 0x2001

; Drive status codes
define STATE_NO_MEDIA 0
define STATE_READY 1
define STATE_READY_WP 2
define STATE_BUSY 3

; Key codes
define KEY_BACKSPACE 0x10
define KEY_RETURN 0x11
define KEY_ARROW_LEFT 0x82
define KEY_ARROW_RIGHT 0x83

define ASCII_MIN 0x20 ; Space character
define ASCII_MAX 0x7f ; ASCII del character, not used itself.

; How long can a shell command line be? This includes the trailing null.
define SHELL_COMMAND_LINE_LENGTH 128

; How long can a command be, including a trailing null? Max file name length
; minus extension.
define SHELL_COMMAND_LENGTH 13

; Where si the root directory on a BBFS disk? TODO: restructure bbfs includes to
; make it so we can just use the bbfs defines.
define BBFS_ROOT_DIRECTORY 4

; What's the BBOS bootloader magic number?
define BBOS_BOOTLOADER_MAGIC 0x55AA
define BBOS_BOOTLOADER_MAGIC_POSITION 511

start:
    ; The drive we loaded off of is in A.
    SET [drive], A

    ; Print the intro
    SET PUSH, str_ready ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
command_loop:
    
    ; Print the prompt
    SET PUSH, [drive] ; Arg 1: drive number
    JSR shell_print_prompt
    ADD SP, 1

    ; Read a command
    SET PUSH, command_buffer
    SET PUSH, SHELL_COMMAND_LINE_LENGTH
    JSR shell_readline
    ADD SP, 2
    
    ; Try and execute it
    SET PUSH, command_buffer
    SET PUSH, [drive]
    JSR shell_exec
    ADD SP, 2
    
    ; Read more commands
    SET PC, command_loop


; Functions

; shell_readline(*buffer, length)
;   Read a line into the buffer. Allow arrow keys to move left/right for insert,
;   and backspace for backspace. Returns when enter is pressed.
; shell_print_prompt(drive_number)
;   Print the prompt, noting the given drive as a letter, starting from A.
; shell_strncmp(*string1, *string2, ignore_case, length)
;   Compare two strings for equality. Returns 1 if they are equal, 0 otherwise.
;   If ignore_case is 1, then case is ignored.
; shell_exec(*command, drive_number)
;   Try executing the command in the given buffer, by first going through
;   builtins and then out to the given disk for .COM files.

; Builtin functions (shell commands)
;
; All of these take one argument: the argument buffer (which has the remainder
; of the typed command after the command name and any whitespace). They may
; access the global [drive], and probably use all the file and directory globals
; for their own purposes.
;
; shell_builtin_ver(*arguments)
;   Print the shell version information.
;
; shell_builtin_format(*arguments)
;   Format the disk in the drive with the given letter as bootable.
;
; shell_builtin_dir(*arguments)
;   List the files in the root directory on the current drive


; shell_readline(*buffer, length)
; Read a line into a buffer.
; [Z+1]: buffer address
; [Z]: Buffer size
shell_readline:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls
    SET PUSH, B ; Cursor position in the buffer
    SET PUSH, C ; Character we're reading
    SET PUSH, X ; Cursor manipulation scratch
    
    ; Set up a cursor position in the buffer
    SET B, [Z+1]
    
    ; Shrink our buffer length in [Z] to just the number of printable characters
    ; we can hold, leaving 1 word for the trailing null.
    SUB [Z], 1
    
    ; Get the cursor position on the screen, and keep it on the stack.
    SUB SP, 2 ; Args 1 and 2: X and Y (output)
    SET A, GET_CURSOR_POS
    INT BBOS_IRQ_MAGIC
    
.key_loop:
    ; Wait for a key press, blocking
    SET PUSH, 1 ; Arg 1: whether to block
    SET A, READ_CHARACTER
    INT BBOS_IRQ_MAGIC
    SET C, POP ; Returns the key code.
    
    IFE C, KEY_RETURN
        ; If it's enter, print a newline and return
        SET PC, .key_return
        
    IFE C, KEY_BACKSPACE
        ; If it's backspace, delete a character.
        SET PC, .key_backspace
        
    IFE C, KEY_ARROW_LEFT
        ; If it's a left arrow, move the cursor left
        SET PC, .key_arrow_left
    
    ; TODO: if it's an arrow key, move the cursor.
    
    IFL C, ASCII_MIN
        ; Other non-printable. Try again
        SET PC, .key_loop
    IFL ASCII_MAX, C
        ; Other non-printable. Try again
        SET PC, .key_loop
        
    ; Otherwise it's printable
    SET PC, .key_printable
    
.key_return:
    ; The user pressed enter.
    
    ; Add a null at the end of the buffer
    SET [B], 0
    
    ; Print a newline
    SET PUSH, str_newline
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Return
    SET PC, .return
.key_backspace:
    ; The user pressed backspace.
    
    IFE B, [Z+1]
        ; We're already at the start of the buffer. Nothing to delete.
        SET PC, .key_loop
        
    ; Move the cursor in the buffer
    SUB B, 1
    ; Add a null so we can print the buffer
    SET [B], 0
    
    ; Move the cursor on the screen back to the start of the string we're
    ; typing. TODO: incrementally shift left and un-word-wrap.
    ; Args are already on the stack from the GET_CURSOR_POS call
    SET A, SET_CURSOR_POS
    INT BBOS_IRQ_MAGIC
    
    ; Now print the now-shorter string
    SET PUSH, [Z+1] ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Print a space in place
    SET PUSH, 0x20 ; Arg 1: character
    SET PUSH, 0 ; Arg 2: move cursor
    SET A, WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Read another key
    SET PC, .key_loop
.key_arrow_left:
    SET PC, .key_arrow_left
    SET PC, .key_loop
.key_arrow_right:
    SET PC, .key_loop
.key_printable:
    ; If it's a printable character, write it to the buffer and the screen.
    ; TODO: move the rest of the characters/manage a gap buffer and update the
    ; screen with everything after the cursor.
    
    SET A, [Z+1]
    ADD A, [Z]
    SUB A, 1
    IFG B, A
        ; We've filled the usable area of the buffer. Drop this character
        SET PC, .key_loop 
    
    ; Save in the buffer
    SET [B], C
    ADD B, 1
    
    ; If the cursor is on the right edge of the screen, print a newline. This
    ; ensures that when we hit the lower right corner of the screen, we don't
    ; just keep overstriking the same character.
    ; First get the screen size
    SUB SP, 2
    SET A, GET_SCREEN_SIZE
    INT BBOS_IRQ_MAGIC
    ADD SP, 1
    SET X, POP ; Save the width. 
    
    ; Now get the cursor position.
    SUB SP, 2
    SET A, GET_CURSOR_POS
    INT BBOS_IRQ_MAGIC
    ADD SP, 1
    SUB X, POP ; Subtract the cursor position.
    
    IFN X, 0
        ; We have some characters left on this line, so no scrolling is
        ; required.
        SET PC, .no_scroll_needed
        
    ; We're out of room on this line. Print a newline.
    SET PUSH, str_newline
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
        
.no_scroll_needed:
    ; Write the typed character to the screen
    SET PUSH, C ; Arg 1: character to write
    SET PUSH, 1 ; Arg 2: move cursor or not
    SET A, WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, .key_loop
.return:
    ADD SP, 2 ; Delete the cursor start X and Y
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

; shell_print_prompt(drive_number) 
; Print the prompt, including drive letter.
; [Z]: drive number
shell_print_prompt:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls
    
    ; Print the drive letter as a character
    SET PUSH, [Z] ; Arg 1: Character to print
    ADD [SP], 0x41 ; Add to 'A'
    SET PUSH, 1 ; Arg 2: move cursor
    SET A, WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Print the rest of the prompt
    SET PUSH, str_prompt ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Return
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; shell_strncmp(*string1, *string2, ignore_case, length)
; Compare two strings for equality
; [Z+3]: string 1 address
; [Z+2]: string 2 address
; [Z+1]: ignore case flag
; [Z]: max length to compare to
; Returns: equality flag in [Z]
shell_strncmp:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; String 1 character
    SET PUSH, B ; String 2 character
    SET PUSH, C ; Remaining length
    
    SET PUSH, I ; String 1 char address
    SET PUSH, J ; String 2 char address
    
    SET I, [Z+3] ; Point to start of first string
    SET J, [Z+2] ; Point to start of second string
    
    SET C, [Z] ; Load up the number of characters to compare
    
.loop:
    IFE C, 0
        ; Ran out of characters without finding a difference
        SET PC, .equal

    ; Load the next characters from the string
    SET A, [I]
    SET B, [J]
    
    IFN [Z+1], 1
        ; They didn't set the ignore case flag, so we shouldn't uppercase
        ; everything.
        SET PC, .no_fix_case
    
    IFG A, 0x60 ; Character is 'a' or greater
        IFL A, 0x7B ; And character is 'z' or less
            SUB A, 32 ; Move down by the offset from A to a
            
    IFG B, 0x60
        IFL B, 0x7B
            SUB B, 32
    
.no_fix_case:
    IFN A, B
        ; We found a difference
        SET PC, .unequal
        
    IFE A, 0
        ; No difference, but they both end here
        SET PC, .equal
        
    ; Otherwise keep going
    ; Advanc ein the strings
    ADD I, 1
    ADD J, 1
    ; Knock a character off the reamining count
    SUB C, 1
    SET PC, .loop
    
.equal:
    SET [Z], 1
    SET PC, .return
    
.unequal:
    SET [Z], 0
    
.return:
    SET J, POP
    SET I, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; shell_exec(*command, drive_number)
; Try the command at the start of the buffer as a builtin, then as a .COM on the
; given disk.
; [Z+1]: command string buffer
; [Z]: drive number to search
shell_exec:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS and pointer into builtins table
    SET PUSH, B ; Pointer to builtin name
    SET PUSH, C ; Pointer to builtin function
    SET PUSH, X ; Pointer to where args start in command string
    SET PUSH, Y ; Scratch
    
    ; First find where in the command string the command ends and the args start
    SET X, [Z+1]
    
.args_loop:
    IFE [X], 0
        ; We hit the trailing null, so the args are empty
        SET PC, .args_done
    
    IFE [X], 0x20 ; We found a space character.
        SET PC, .scan_spaces
    
    ; Otherwise it's more command name
    ADD X, 1
    SET PC, .args_loop
    
.scan_spaces:
    ; We found spaces.
    ; Replace the first one with a null to terminate the command name string.
    SET [X], 0
    
.space_loop:
    ; Advance
    ADD X, 1
    
    IFE [X], 0x20
        ; Advance to the first non-space character.
        SET PC, .space_loop
.args_done:
    ; Now [Z+1] is the null-terminated command name, and X points to the null-
    ; terminated argument string.
    
    ; Compare command name against our builtin table.
    SET A, builtins_table
    
.builtins_loop:
    SET B, [A] ; Load the command
    SET C, [A+1] ; And the function
    
    IFE B, 0
        IFE C, 0
            ; We are out of builtins. This is the null terminator
            SET PC, .not_a_builtin
            
    ; Call string comparison
    SET PUSH, B ; Arg 1: builtin name
    SET PUSH, [Z+1] ; Arg 2: typed command
    SET PUSH, 1 ; Arg 3: ignore case
    SET PUSH, SHELL_COMMAND_LENGTH ; Arg 4: max length
    JSR shell_strncmp
    SET Y, POP ; Save the equality flag
    ADD SP, 3
    
    IFE Y, 1
        ; This is the right builtin
        SET PC, .builtin_found
    
    ; Otherwise move on. This is the size of one of these table records. TODO:
    ; define a proper struct.
    ADD A, 2
    SET PC, .builtins_loop
    
.builtin_found:

    ; We found the right builtin table entry. Call the builtin.
    SET PUSH, X ; Arg 1: null-terminated argument string
    JSR C ; Call the function address we found in the table.
    ADD SP, 1 ; Ignore anything returned
    SET PC, .return
            
.not_a_builtin:
    ; TODO: see if we said "B:" and if so switch to that drive.

    ; TODO: search the disk.
    
    ; Say we couldn't find the command.
    ; Start with the parsed command name
    SET PUSH, [Z+1] ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Then say we couldn't find it
    SET PUSH, str_not_found ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2

.return:
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; shell_builtin_ver(*arguments)
; Print shell version info.
; [Z]: argument string
shell_builtin_ver:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls
    
    ; Ignore the arguments
    
    ; Print the version strings
    SET PUSH, str_version1 ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, str_version2 ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Return
    SET A, POP
    SET Z, POP
    SET PC, POP

; shell_builtin_format(*arguments)
; Format the disk in the drive with the given letter.  
; [Z]: argument string, with first letter being drive to format.  
shell_builtin_format:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls
    SET PUSH, B ; Drive number
    
    ; Try and read a drive number from the argument string
    SET B, [Z]
    SET B, [B]
    
    ; If it's in the upper-case ASCII range, lower-case it
    IFL B, 0x7B
        IFG B, 0x60
            SUB B, 32
            
    IFL B, 0x41
        ; 'A' is the first valid drive letter
        SET PC, .error_bad_drive_letter
        
    IFG B, 0x5A
        ; 'Z' is the first possible drive letter
        SET PC, .error_bad_drive_letter
        
    ; Convert from drive letter to drive number.
    SUB B, 0x41
    
    ; Get the drive count from BBOS
    SUB SP, 1
    SET A, GET_DRIVE_COUNT
    INT BBOS_IRQ_MAGIC
    SET A, POP
    
    SUB A, 1 ; We know we have 1 drive, so knock this down to (probably) 7
    IFG B, A
        ; We're out of bounds wrt the drives installed
        SET PC, .error_no_drive
        
    ; Now check to make sure there's a writable disk
    SET PUSH, B
    SET A, CHECK_DRIVE_STATUS
    INT BBOS_IRQ_MAGIC
    SET A, POP
    
    ; Shift down to have only the high (status) octet
    SHR A, 8
    
    ; Check to make sure we're status ready
    IFE A, STATE_NO_MEDIA
        SET PC, .error_no_media
        
    IFE A, STATE_READY_WP
        SET PC, .error_write_protected
    
    IFN A, STATE_READY
        SET PC, .error_unknown
        
    ; Now we can actually do the work.
    
    ; Make a filesystem
    
    ; Format the header
    SET PUSH, header ; Arg 1: header pointer
    JSR bbfs_header_format
    ADD SP, 1
    
    ; Save the header to the disk
    SET PUSH, B ; Arg 1: drive number
    SET PUSH, header ; Arg 2: header pointer
    JSR bbfs_drive_save
    ADD SP, 2
    
    ; Make a root directory.
    ; Since it's the first thing on the disk it ends up at the right sector.
    SET PUSH, directory ; Arg 1: directory handle to open
    SET PUSH, header ; Arg 2: header to make the directory in
    SET PUSH, B ; Arg 3: drive to work on
    JSR bbfs_directory_create
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
    
    ; Save a memory image to "BOOT.IMG"
    ; Make a file
    
    SET PUSH, file ; Arg 1: file struct to populate
    SET PUSH, header ; Arg 2: header to work in
    SET PUSH, B ; Arg 3: drive to work on
    JSR bbfs_file_create
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
        
    ; Stick it in the directory
    
    ; Populate an entry for it in the directory
    SET [entry+BBFS_DIRENTRY_TYPE], BBFS_TYPE_FILE
    SET [entry+BBFS_DIRENTRY_SECTOR], [file+BBFS_FILE_START_SECTOR]
    
    ; Pack in a filename
    SET PUSH, str_boot_filename ; Arg 1: string to pack
    SET PUSH, entry ; Arg 2: place to pack it
    ADD [SP], BBFS_DIRENTRY_NAME
    JSR bbfs_filename_pack
    ADD SP, 2
    
    ; Add the entry to the directory (which saves it to disk)
    SET PUSH, directory
    SET PUSH, entry
    JSR bbfs_directory_append
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
    
    ; Write the whole running program to the file.
    SET PUSH, file ; Arg 1: file pointer to write to
    SET PUSH, 0 ; Arg 2: start address (start of memory)
    SET PUSH, bootloader_code ; Arg 3: words to write
    ADD [SP], BBFS_WORDS_PER_SECTOR ; Add on the length of the bootloader.
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
        
    ; And flush
    SET PUSH, file
    JSR bbfs_file_flush
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
        
    ; Now all we have to do is install the bootloader.
    ; First set its magic word
    SET [bootloader_code+BBOS_BOOTLOADER_MAGIC_POSITION], BBOS_BOOTLOADER_MAGIC
    
    ; Then make a raw BBOS call to stick it as the first sector of the drive
    SET PUSH, 0 ; Arg 1: sector
    SET PUSH, bootloader_code ; Arg 2: pointer
    SET PUSH, B ; Arg 3: drive number
    SET A, WRITE_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ADD SP, 3
    
    ; Put back the magic word so we don't change our image
    SET [bootloader_code+BBOS_BOOTLOADER_MAGIC_POSITION], 0
    
    ; Say we succeeded
    SET PUSH, str_format_success ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    set PC, .say_drive_and_return
    
.error_bad_drive_letter:
    
    ; Put the error message
    SET PUSH, str_bad_drive_letter ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Don't try and say the bad drive letter.
    set PC, .return
    
.error_no_drive:
    
    ; Put the error message
    SET PUSH, str_no_drive ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    set PC, .say_drive_and_return
    
.error_no_media:

    ; Put the error message
    SET PUSH, str_no_media ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, .say_drive_and_return

.error_write_protected:

    ; Put the error message
    SET PUSH, str_write_protected ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, .say_drive_and_return

.say_drive_and_return:
    ; Put the drive letter
    SET PUSH, B ; Arg 1: Character to print
    ADD [SP], 0x41 ; Add to 'A'
    SET PUSH, 1 ; Arg 2: move cursor
    SET A, WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Put a colon and a newline
    SET PUSH, str_colon ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Return
    SET PC, .return

.error_unknown:

    ; Put the error message
    SET PUSH, str_unknown ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
.return:
    ; Return
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

; shell_builtin_dir(*arguments)
; List the files on the current drive
; [Z]: argument string
shell_builtin_dir:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls/scratch
    SET PUSH, B ; Drive number
    
    SET B, [drive] ; Load the drive number

    ; Load the header
    SET PUSH, B ; Arg 1: drive number
    SET PUSH, header ; Arg 2: header to populate
    JSR bbfs_drive_load
    ADD SP, 2
    ; Open the directory
    SET PUSH, directory ; Arg 1: directory
    SET PUSH, header ; Arg 2: BBFS_HEADER
    SET PUSH, B ; Arg 3: drive
    ; Arg 4: sector
    SET PUSH, [directory+BBFS_DIRECTORY_FILE+BBFS_FILE_START_SECTOR]
    JSR bbfs_directory_open
    SET A, POP
    ADD SP, 3
    IFN A, BBFS_ERR_NONE
        SET PC, .error
        
    ; Say we're listing the directory
    SET PUSH, str_listing_directory
    SET PUSH, 0 ; No newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Put the drive letter
    SET PUSH, B ; Arg 1: Character to print
    ADD [SP], 0x41 ; Add to 'A'
    SET PUSH, 1 ; Arg 2: move cursor
    SET A, WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Put a colon and a newline
    SET PUSH, str_colon ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Read entries out
.dir_entry_loop:
    ; Read the next entry
    SET PUSH, directory
    SET PUSH, entry
    JSR bbfs_directory_next
    SET A, POP
    ADD SP, 1
    IFE A, BBFS_ERR_EOF
        ; If we have run out, stop looping
        SET PC, .dir_entry_loop_done
    IFN A, BBFS_ERR_NONE
        ; On any other error, fail
        SET PC, .error
    
    ; Unpack the filename
    SET PUSH, filename ; Arg 1: unpacked filename
    SET PUSH, entry ; Arg 2: packed filename
    ADD [SP], BBFS_DIRENTRY_NAME
    JSR bbfs_filename_unpack
    ADD SP, 2
    
    ; TODO: split into name and extension
    
    ; TODO: lay out nicely
    
    ; TODO:Destinguish directories
    
    ; Print the filename
    SET PUSH, filename
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Loop until EOF
    SET PC, .dir_entry_loop
    
.dir_entry_loop_done:
    ; We listed all the files.
    
    ; TODO: print totals here
    
    SET PC, .return

.error:
    ; Print a message
    SET PUSH, str_unknown
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2

.return:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    

; We depend on bbfs
#include <bbfs.asm>

; Strings
str_ready:
    ASCIIZ "DC-DOS 1.0 Ready"
str_prompt:
    ASCIIZ ":\\> "
str_version1:
    ASCIIZ "DC-DOS Command Interpreter 1.0"
str_version2:
    ASCIIZ "Copyright (C) UBM Corporation"
str_not_found:
    ASCIIZ ": Bad command or file name"
str_bad_drive_letter:
    ASCIIZ "Usage: FORMAT <DRIVELETTER>"
str_no_drive:
    ASCIIZ "No drive "
str_no_media:
    ASCIIZ "No media in drive "
str_write_protected:
    ASCIIZ "Write-protected disk in drive "
str_unknown:
    ASCIIZ "Unknown error"
str_colon:
    ASCIIZ ":"
str_boot_filename:
    ASCIIZ "BOOT.IMG"
str_format_success:
    ASCIIZ "Formatted drive "
str_listing_directory:
    ASCIIZ "Directory listing of "
    
str_newline:
    ; TODO: ASCIIZ doesn't like empty strings in dasm
    DAT 0
    
; Builtin names:
str_builtin_ver:
    ASCIIZ "VER"
str_builtin_format:
    ASCIIZ "FORMAT"
str_builtin_dir:
    ASCIIZ "DIR"

; Builtins table
;
; Each record is a pointer to a string and the address of a function to call
; when that command is run. Terminates with a record of all 0s.
builtins_table:
    ; VER builtin
    DAT str_builtin_ver
    DAT shell_builtin_ver
    ; FORMAT builtin
    DAT str_builtin_format
    DAT shell_builtin_format
    ; DIR builtin
    DAT str_builtin_dir
    DAT shell_builtin_dir
    ; No more builtins
    DAT 0
    DAT 0
    
; Code for the bootloader
bootloader_code:
#include <bbfs_bootloader.asm>

; Now our .org has been messed up, so we set non-const data up in high-ish
; memory

.org 0xd000

; Global vars
; Current drive number
drive:
    RESERVE 1
; File for loading things
file:
    RESERVE BBFS_FILE_SIZEOF
; Directory for scanning through
directory:
    RESERVE BBFS_DIRECTORY_SIZEOF
; Entry struct for accessing directories
entry:
    RESERVE BBFS_DIRENTRY_SIZEOF
; Header for the filesystem
header:
    RESERVE BBFS_HEADER_SIZEOF
; String buffer for commands
command_buffer:
    RESERVE SHELL_COMMAND_LINE_LENGTH
; Packed filename for looking through directories
packed_filename:
    RESERVE BBFS_FILENAME_PACKED
; And an unpacked finename
filename:
    RESERVE BBFS_FILENAME_BUFSIZE
; We sometimes need two files
file2:
    RESERVE BBFS_FILE_SIZEOF
    
