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

; Where is the root directory on a BBFS disk? TODO: restructure bbfs includes to
; make it so we can just use the bbfs defines.
define BBFS_ROOT_DIRECTORY 4

; What's the BBOS bootloader magic number?
define BBOS_BOOTLOADER_MAGIC 0x55AA
define BBOS_BOOTLOADER_MAGIC_POSITION 511

; We want to load the shell code into high memory, so that if we want to load
; another binary off of a disk, we can fit one of a decent size before it starts
; to overwrite the routines trying to load it.

; BBOS likes to load at 0xF000. If we could relocate ourselves, we could just
; ask it where to load.

; This leaves us 8k for code above, and 45k for user/loaded code below.
define SHELL_CODE_START 0xB000 

; This leaves us a bit under 8k for data and BBOS's VRAM. We have like 5k with
; all those sector buffers.
define SHELL_DATA_START 0xD000

; TODO: develop a bank switching peripheral to swap out 8k banks or something.

zero:
    ; Here we have some simple code to move the rest up to high memory
    
    SET I, moveable_start ; This is where we find the code to move
    SET J, start ; This is where it goes
    ; Calculate (at assembly time) how many words to copy
    SET C, bootloader_code+BBFS_WORDS_PER_SECTOR-start
    
.copy_loop:
    ; Copy all the words up into higher memory
    STI [J], [I]
    SUB C, 1
    IFN C, 0
        SET PC, .copy_loop
        
    ; Jump to the code we just moved into place
    SET PC, start
    
moveable_start: ; This is where we read our real code from
    
.org SHELL_CODE_START

start:
    ; Now we're running in place.

    ; Save the code that just moved us, in case we need it for format.
    SET I, zero
    SET J, format_copyloader
    SET C, moveable_start-zero
.copy_loop:
    STI [J], [I]
    SUB C, 1
    IFN C, 0
        SET PC, .copy_loop

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
; shell_open(*header, *file, *filename, create)
;   Populate a header and a file object by opening the given file object on the
;   appropriate drive (either the current one or one derived from a leading A:\
;   in the filename). Clobbers the global directory and dirinfo space. If create
;   is specified, creates the file if it can't be found. Returns an error code.
; shell_resolve_drive(character)
;   Turn a drive letter into a drive number, or 0xFFFF if a bad drive letter.

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
;   List the files in the root directory on the current or specified drive
;
; shell_builtin_copy(*arguments)
;   Copies the file named with the first argument to the file named with the
;   second argument. Filenames may be prefixed as <DRIVE>:\.
;
; shell_builtin_del(*arguments)
;   Delete file, with drive letter support as in COPY above.
;
; shell_builtin_load(*arguments)
;   Load a file at address 0 and execute it. Loaded code can try returning with
;   a SET PC, POP if it didn't clobber our memory, in which case this function
;   returns 1. If the file could not be loaded, this function returns 0.

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
    
    ; Skip empty commands
    SET A, [Z+1]
    IFE [A], 0
        SET PC, .return
    
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

    SET Y, [Z+1] ; Start at the start of the string
    ADD Y, 1 ; Look at the second character
   
    IFN [Y], 0x3A ; Not a drive if it's not <char>:
        SET PC, .not_a_drive
    IFE [Y+1], 0x20 ; Catch "A: "
        SET PC, .is_a_drive
    IFE [Y+1], 0 ; Catch "A:"
        SET PC, .is_a_drive
    SET PC, .not_a_drive
    
.is_a_drive:
    
    ; They may be asking for a drive
    ; Grab the letter
    SET Y, [Z+1] ; Look at the start of the string again
    SET Y, [Y]
    
    SET PUSH, Y
    JSR shell_resolve_drive
    SET Y, POP
    
    IFE Y, 0xFFFF
        ; We couldn't resolve the drive letter
        SET PC, .error_bad_drive
        
    ; If we could, go to that drive
    SET [drive], Y
    SET PC, .return
    
.not_a_drive:
    
    ; How long is the command?
    SET A, [Z+1]
    
    ; Does this command contain an extension?
    SET B, 0
    
.command_length_loop:
    IFE [A], 0
        SET PC, .command_length_done
    IFE [A], 0x2E ; We found a dot
        SET B, A ; Save its location
    ADD A, 1
    SET PC, .command_length_loop
.command_length_done:
    SUB A, [Z+1]
    
    IFN B, 0
        ; We found an extension in the string.
        SET PC, .try_load_with_extension
    
    ; TODO: try appending an extension and loading with that.
    SET PC, .error_bad_command
    
.try_load_with_extension:
    ; A is the filename length and B is the extension start
    ; See if the extension is executable and if so load from disk.
    
    ; Do we have the .img extension?
    SET PUSH, str_img_extension ; Arg 1: string 1
    SET PUSH, B ; Arg 2: string 2
    SET PUSH, 1 ; Arg 3: ignore case
    SET PUSH, 4 ; Arg 4: number of characters (".IMG")
    JSR shell_strncmp
    SET Y, POP
    ADD SP, 3
    
    IFE Y, 0
        ; Not a loadable binary
        SET PC, .error_bad_command
    
    ; If we get here, we can just load it with the filename in the command
    ; buffer.
    SET PUSH, [Z+1] ; Arg 1: filename string
    JSR shell_builtin_load
    SET Y, POP
    
    IFE Y, 0
        ; We didn't load successfully
        SET PC, .error_bad_command
    
    ; Otherwise we have finished running the program
    SET PC, .return
    
.error_bad_command:
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
    
    SET PC, .return
    
.error_bad_drive:
    ; Say we couldn't find the specified drive
    SET PUSH, str_error_drive ; Arg 1: string to print
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
    SET PUSH, str_ver_version1 ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, str_ver_version2 ; Arg 1: string to print
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
    
    ; If it's in the lower-case ASCII range, upper-case it
    IFL B, 0x7B
        IFG B, 0x60
            SUB B, 32
            
    IFL B, 0x41
        ; 'A' is the first valid drive letter
        SET PC, .error_bad_drive_letter
        
    IFG B, 0x5A
        ; 'Z' is the last possible drive letter
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
    
    ; Save a memory image to "BOOT.IMG" that will boot back to this code.
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
    
    ; Write the copy loader we moved up to high memory, so it can move us back
    ; to high memory when we reload.
    SET PUSH, file ; Arg 1: file pointer to write to
    SET PUSH, format_copyloader ; Arg 2: start address
    SET PUSH, moveable_start-zero ; Arg 3: length
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
    
    ; Write the actual program code
    SET PUSH, file ; Arg 1: file pointer to write to
    SET PUSH, start ; Arg 2: start address
    SET PUSH, bootloader_code+BBFS_WORDS_PER_SECTOR-start ; Arg 3: length
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
    SET PUSH, str_format_usage ; Arg 1: string to print
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
    SET PUSH, str_error_unknown ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
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
    
    ; Try and read a drive number from the argument string
    SET B, [Z]
    SET B, [B]
    
    IFE B, 0
        ; No drive number was specified. Fill in the current drive.
        SET PC, .current_drive
    
    ; If it's in the lower-case ASCII range, upper-case it
    IFL B, 0x7B
        IFG B, 0x60
            SUB B, 32
            
    IFL B, 0x41
        ; 'A' is the first valid drive letter
        SET PC, .error_bad_drive_letter
        
    IFG B, 0x5A
        ; 'Z' is the last possible drive letter
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
        SET PC, .drive_ready
    
    IFE A, STATE_READY
        SET PC, .drive_ready
        
    ; If it's in a bad state, say we have an unknown error.
    SET PC, .error_unknown
    
.current_drive:
    ; Just use the current drive
    SET B, [drive] ; Load the drive number
.drive_ready:
    
    ; Load the header
    SET PUSH, B ; Arg 1: drive number
    SET PUSH, header ; Arg 2: header to populate
    JSR bbfs_drive_load
    ADD SP, 2
    ; Open the directory
    SET PUSH, directory ; Arg 1: directory
    SET PUSH, header ; Arg 2: BBFS_HEADER
    SET PUSH, B ; Arg 3: drive
    SET PUSH, BBFS_ROOT_DIRECTORY ; Arg 4: sector
    JSR bbfs_directory_open
    SET A, POP
    ADD SP, 3
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
        
    ; Say we're listing the directory
    SET PUSH, str_dir_directory
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
        SET PC, .error_unknown
    
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
    
.error_bad_drive_letter:
    
    ; Put the error message
    SET PUSH, str_format_usage ; Arg 1: string to print
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
    ; Put the generic error message
    SET PUSH, str_error_unknown ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2

.return:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; shell_builtin_copy(*arguments)
; Copy file to file, with drive letter support.
; [Z]: argument string
shell_builtin_copy:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls/scratch
    SET PUSH, B ; Address of the 1-word stack buffer
    SET PUSH, C ; Second file name
    SUB SP, 1 ; Allocate a 1-word buffer on the stack
    SET B, SP ; Point to it

    ; Parse the command line
    ; Split out the first filename
    
    SET C, [Z] ; Start at the start of the first filename
    
.parse_nonspaces_loop:
    IFE [C], 0 ; No second filename
        SET PC, .error_usage
    IFE [C], 0x20 ; Found a space
        SET PC, .parse_nonspaces_done
        
    ; Try the next character
    ADD C, 1
    SET PC, .parse_nonspaces_loop
        
.parse_nonspaces_done:
    ; We found a space
    ; Null it out to terminate the first filename.
    SET [C], 0
    ADD C, 1
    ; Slide over all reamining spaces
.parse_spaces_loop:
    IFE [C], 0 ; No second filename
        SET PC, .error_usage
    IFN [C], 0x20 ; Found a space
        SET PC, .parse_spaces_done
        
    ; Try the next character
    ADD C, 1
    SET PC, .parse_spaces_loop
    
.parse_spaces_done:
    ; Now we found the start of the second filename.
    ; But we want to go out and null out the first space after it, if any.
    SET A, C
    
.parse_second_filename_loop:
    IFE [A], 0
        ; We hit the end and found no spaces
        SET PC, .parse_second_filename_done
    IFE [A], 0x20
        ; We found a trailing space
        SET PC, .parse_second_filename_done
    
    ; Try the next character
    ADD A, 1
    SET PC, .parse_second_filename_loop
    
.parse_second_filename_done:
    ; Zero out this character, which may be a space
    SET [A], 0
    
    ; We have now parsed our arguments
    
    ; Open the first file, not creating
    ; shell_open(*header, *file, *filename, create)
    SET PUSH, header ; Arg 1: header to populate
    SET PUSH, file ; Arg 2: file to populate
    SET PUSH, [Z] ; Arg 3: unpacked filename string
    SET PUSH, 0 ; Arg 4: create flag
    JSR shell_open
    SET A, POP
    ADD SP, 3
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Open the second file, creating
    SET PUSH, header2 ; Arg 1: header to populate
    SET PUSH, file2 ; Arg 2: file to populate
    SET PUSH, C ; Arg 3: unpacked filename string
    SET PUSH, 1 ; Arg 4: create flag
    JSR shell_open
    SET A, POP
    ADD SP, 3
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    IFE [file+BBFS_FILE_DRIVE], [file2+BBFS_FILE_DRIVE]
        IFE [file+BBFS_FILE_START_SECTOR], [file2+BBFS_FILE_START_SECTOR]
            ; We've opened the same file twice. We can't truncate it because
            ; it's open. Just declare the copy done.
            SET PC, .copy_done
    
    ; Truncate the second file (in case it existed already)
    SET PUSH, file2 ; Arg 1: file to truncate
    JSR bbfs_file_truncate
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
    
    ; Until EOF, read a word from file 1 and write it to file 2. We do it by
    ; word so we don't accidentally append garbage.
.copy_loop:
    ; Read from file 1
    SET PUSH, file ; Arg 1: file
    SET PUSH, B ; Arg 2: buffer
    SET PUSH, 1 ; Arg 3: length
    JSR bbfs_file_read
    SET A, POP
    ADD SP, 2
    IFE A, BBFS_ERR_EOF
        ; We hit EOF so we're done copying
        SET PC, .copy_done
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Write to file 2
    SET PUSH, file2 ; Arg 1: file
    SET PUSH, B ; Arg 2: buffer
    SET PUSH, 1 ; Arg 3: length
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A

    ; Loop around and copy another word
    SET PC, .copy_loop

.copy_done:
    ; We read and wrote all the words.
    
    ; Sync file 2
    SET PUSH, file2 ; Arg 1: file to flush
    JSR bbfs_file_flush
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; We were successful.
    ; Print success.
    SET PUSH, str_copy_copied ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, [Z] ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, str_copy_to ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, C ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Return
    SET PC, .return
        
.error_usage:
    ; The user doesn't know how to run the command
    ; Print usage.
    
    SET PUSH, str_copy_usage ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, .return

.error_A:
    ; We had an error, code is in A
    ; TODO: attribute it to an operand
    
    ; Keep the error message string in B
    SET B, str_error_unknown
    
    ; Override it if we can be more specific
    IFE A, BBFS_ERR_NOTFOUND
        SET B, str_error_not_found
    IFE A, BBFS_ERR_DRIVE
        SET B, str_error_drive
    
    ; Print the error
    SET PUSH, B ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
.return:
    ADD SP, 1 ; Deallocate 1-word buffer
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; shell_builtin_del(*arguments)
; Delete file, with drive letter support.
; [Z]: argument string
shell_builtin_del:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls/scratch
    SET PUSH, B ; Directory entry number of file

    ; Parse the command line
    ; Split out the first filename
    
    SET A, [Z] ; Start at the start of the first filename
    
    IFE [A], 0
        ; They gave no filename at all
        SET PC, .error_usage
    
.parse_nonspaces_loop:
    IFE [A], 0 ; We hit the end of the filename and got a null
        SET PC, .parse_nonspaces_done
    IFE [A], 0x20 ; Found a space
        SET PC, .parse_nonspaces_done
        
    ; Try the next character
    ADD A, 1
    SET PC, .parse_nonspaces_loop
        
.parse_nonspaces_done:
    ; We found what may be a space after the filename
    ; Null it out to terminate the first filename.
    SET [A], 0
    
    ; We have now parsed our arguments
    
    ; Open the file, not creating
    ; shell_open(*header, *file, *filename, create)
    SET PUSH, header ; Arg 1: header to populate
    SET PUSH, file ; Arg 2: file to populate
    SET PUSH, [Z] ; Arg 3: unpacked filename string
    SET PUSH, 0 ; Arg 4: create flag
    JSR shell_open
    SET A, POP ; Read error code
    SET B, POP ; Read second return value: index file is at in global directory
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
    
    ; Delete the file from the disk
    SET PUSH, file
    JSR bbfs_file_delete
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
    
    ; Unlink the file from the global directory
    SET PUSH, directory ; Arg 1: BBFS_DIRECTORY to operate on
    SET PUSH, B ; Arg 2: index of file to remove
    JSR bbfs_directory_remove
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; We were successful.
    ; Print success.
    SET PUSH, str_del_deleted ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, [Z] ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Return
    SET PC, .return
        
.error_usage:
    ; The user doesn't know how to run the command
    ; Print usage.
    
    SET PUSH, str_del_usage ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, .return

.error_A:
    ; We had an error, code is in A

    ; Keep the error message string in B
    SET B, str_error_unknown
    
    ; Override it if we can be more specific
    IFE A, BBFS_ERR_NOTFOUND
        SET B, str_error_not_found
    IFE A, BBFS_ERR_DRIVE
        SET B, str_error_drive
    
    ; Print the error
    SET PUSH, B ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
.return:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; shell_open(*header, *file, *filename, create)
; Populate the given header and file by opening the given filename. Get drive
; from filename if possible.
; [Z+3]: BBFS_HEADER to populate
; [Z+2]: BBFS_FILE to populate
; [Z+1]: File name buffer. May have a leading drive like A: or A:\. May be
; modified.
; [Z] Flag for whether to create the file if it does not exist.
; Returns: Error code in [Z], index of file in directory in [Z+1]
; Side effect: leaves global directory open to the file's directory.
; TODO: make it be passed in by argument or something.
shell_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls/scratch
    SET PUSH, B ; Drive number to use/scratch for parsing it
    SET PUSH, C ; Actual file name start
    SET PUSH, X ; Index in directory
    
    ; Find the actual filename start
    SET C, [Z+1]

.scan_drive_letter:
    IFE [C], 0
        ; We ran out of name too early
        SET PC, .error_out_of_name
    SET B, [C] ; Load up what may be the drive letter.
    ADD C, 1
.scan_colon:
    ; If we had a drive letter, we should have a colon now.
    IFN [C], 0x3A ; No colon
        ; Parse it all as a filename
        SET PC, .rescan_all_name
    ADD C, 1
.scan_slash:
    IFE [C], 0x5C ; There's a backslash
        ADD C, 1 ; Skip it
    
    ; We know we have the drive format, so try to resolve the drive
    SET PUSH, B ; Arg: drive character
    JSR shell_resolve_drive
    SET B, POP ; Result: drive number or 0xFFFF
    
    IFE B, 0xFFFF
        SET PC, .error_drive
    
    ; Read the name
    SET PC, .scan_name
        
.rescan_all_name:
    ; Start at the beginning again
    SET C, [Z+1]
    
    ; Our drive should just be our current drive
    SET B, [drive]
  
.scan_name:
    ; The file name is at C.
    
    ; Make sure it's not empty
    IFE [C], 0
        SET PC, .error_out_of_name
    
    ; Scan it to make sure it's not bogus (no illegal characters, not too long)
    SET A, C
    
.name_loop:
    IFE [A], 0
        ; We scanned the whole name
        SET PC, .name_loop_done
        
    IFE [A], 0x3A ; No colons
        SET PC, .error_bad_character
        
    IFE [A], 0x20 ; No spaces
        SET PC, .error_bad_character
        
    IFE [A], 0x5C ; No backslashes
        SET PC, .error_bad_character
        
    IFE [A], 0x2F ; No forward slashes either
        SET PC, .error_bad_character
        
    ; TODO: ban more characters
        
    ; Check the next character
    ADD A, 1
    SET PC, .name_loop

.name_loop_done:
    ; Check the name length
    SUB A, C
    
    IFL A, BBFS_FILENAME_BUFSIZE
        ; Name will fit in a buffer
        SET PC, .name_ok
    
    ; Otherwise the name is too long
    SET PC, .error_name_too_long
        
.name_ok:
    ; Now we have the drive number in B and an acceptable filename in C.
    
    ; Pack the filename
    SET PUSH, C ; Arg 1: string to pack
    SET PUSH, packed_filename ; Arg 2: place to pack it
    JSR bbfs_filename_pack
    ADD SP, 2
    
    ; Read the header for the drive. TODO: make a table of header addresses by
    ; drive so we can re-use the same header when opening multiple files or
    ; something. Right now you can get multiple headers for a drive and lose
    ; data if you save the wrong one.
    SET PUSH, B ; Arg 1: drive number
    SET PUSH, [Z+3] ; Arg 2: BBFS_HEADER
    JSR bbfs_drive_load
    ADD SP, 2

    ; Open the root directory
    SET PUSH, directory ; Arg 1: BBFS_DIRECTORY
    SET PUSH, [Z+3] ; Arg 2: BBFS_HEADER
    SET PUSH, B ; Arg 3: drive number
    SET PUSH, BBFS_ROOT_DIRECTORY ; Arg 4: directory start sector
    JSR bbfs_directory_open
    SET A, POP
    ADD SP, 3
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    SET X, 0 ; Keep track of the entry we find it in
        
.dir_entry_loop:
    ; Read the next entry
    SET PUSH, directory
    SET PUSH, entry
    JSR bbfs_directory_next
    SET A, POP
    ADD SP, 1
    IFE A, BBFS_ERR_EOF
        ; We didn't find our file
        SET PC, .file_not_found
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Compare filenames
    SET PUSH, entry ; Arg 1: first packed name
    ADD [SP], BBFS_DIRENTRY_NAME
    SET PUSH, packed_filename ; Arg 2: second packed name
    JSR bbfs_filename_compare
    SET A, POP
    ADD SP, 1
    IFE A, 1
        ; We found it
        SET PC, .file_found

    ; Say it's in the next entry (which will be past the current end if we have
    ; to create it)
    ADD X, 1 
        
    ; Otherwise keep looking
    SET PC, .dir_entry_loop

.file_not_found:
    ; The file wasn't found. Should we create it?
    IFE [Z], 0
        ; Don't create it
        SET PC, .error_not_found
    
    ; Otherwise, open it on the disk.
    SET PUSH, [Z+2] ; Arg 1: file
    SET PUSH, [Z+3] ; Arg 2: header
    SET PUSH, B ; Arg 3: drive
    JSR bbfs_file_create
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
    
    ; Prepare a directory entry for it
    SET [entry+BBFS_DIRENTRY_TYPE], BBFS_TYPE_FILE
    SET A, [Z+2]
    SET [entry+BBFS_DIRENTRY_SECTOR], [A+BBFS_FILE_START_SECTOR]
    ; Pack in the filename again (easier than copying)
    SET PUSH, C ; Arg 1: string to pack
    SET PUSH, entry ; Arg 2: place to pack it
    ADD [SP], BBFS_DIRENTRY_NAME
    JSR bbfs_filename_pack
    ADD SP, 2
        
    ; Add it to the directory
    SET PUSH, directory
    SET PUSH, entry
    JSR bbfs_directory_append
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; We succeeded
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.file_found:
    ; We found the file's directory entry. Open the file.
    SET PUSH, [Z+2] ; Arg 1: file to open into
    SET PUSH, [Z+3] ; Arg 2: FS header
    SET PUSH, B ; Arg 3: drive to read from
    SET PUSH, [entry+BBFS_DIRENTRY_SECTOR] ; Arg 4: sector to start at
    JSR bbfs_file_open
    SET A, POP
    ADD SP, 3
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A 

    ; We succeeded
    SET [Z], BBFS_ERR_NONE
    SET PC, .return

.error_out_of_name:
    ; Name string was empty
    SET [Z], BBFS_ERR_INVALID
    SET PC, .return
.error_bad_character:
    ; Illegal character in filename
    SET [Z], BBFS_ERR_INVALID
    SET PC, .return
.error_name_too_long:
    ; Name was too long to pack
    SET [Z], BBFS_ERR_INVALID
    SET PC, .return
.error_not_found:
    ; File was not found under name
    SET [Z], BBFS_ERR_NOTFOUND
    SET PC, .return
.error_drive:
    ; Drive letter was bad
    SET [Z], BBFS_ERR_DRIVE
    SET PC, .return
.error_A:
    ; Some lower error we're passing up
    SET [Z], A
.return:
    SET [Z+1], X ; Return the index we found, if any
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; shell_resolve_drive(character)
; Turn a character like A or B into a drive number, or 0xFFFF if no drive is
; found.
; [Z]: Drive character
; Returns: BBOS drive number in [Z]
shell_resolve_drive:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls
    SET PUSH, B ; Drive number
    
    SET B, [Z] ; Load the drive number
    
    ; If it's in the lower-case ASCII range, upper-case it
    IFL B, 0x7B
        IFG B, 0x60
            SUB B, 32
            
    IFL B, 0x41
        ; 'A' is the first valid drive letter
        SET PC, .error
        
    IFG B, 0x5A
        ; 'Z' is the last possible drive letter
        SET PC, .error
        
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
        SET PC, .error
        
    ; Now check to make sure there's a writable disk
    SET PUSH, B
    SET A, CHECK_DRIVE_STATUS
    INT BBOS_IRQ_MAGIC
    SET A, POP
    
    ; Shift down to have only the high (status) octet
    SHR A, 8
    
    ; Check to make sure we're status ready
    IFE A, STATE_NO_MEDIA
        SET PC, .error
        
    ; TODO: should we do more checking?
    
    ; Return the drive number
    SET [Z], B
    SET PC, .return
    
.error:
    ; Say we couldn't find the drive
    SET [Z], 0xFFFF
    ; TODO: messages?
.return:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; shell_builtin_load(*arguments)
; Load the file specified at address 0, and JSR there. Returns 1 if it ever
; returns, and 0 if it could not be loaded.
; [Z]: argument string beginning with a file name
; Returns: success flag in [Z]
shell_builtin_load:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls, scratch
    SET PUSH, B ; Cursor for where we're reading to.
    
    ; Parse the command line
    ; Split out the first filename
    
    SET A, [Z] ; Start at the start of the first filename
    
    IFE [A], 0
        ; They gave no filename at all
        SET PC, .error_usage
    
.parse_nonspaces_loop:
    IFE [A], 0 ; We hit the end of the filename and got a null
        SET PC, .parse_nonspaces_done
    IFE [A], 0x20 ; Found a space
        SET PC, .parse_nonspaces_done
        
    ; Try the next character
    ADD A, 1
    SET PC, .parse_nonspaces_loop
        
.parse_nonspaces_done:
    ; We found what may be a space after the filename
    ; Null it out to terminate the first filename.
    SET [A], 0
    
    ; We have now parsed our arguments
    
    ; Open the file, not creating
    ; shell_open(*header, *file, *filename, create)
    SET PUSH, header ; Arg 1: header to populate
    SET PUSH, file ; Arg 2: file to populate
    SET PUSH, [Z] ; Arg 3: unpacked filename string
    SET PUSH, 0 ; Arg 4: create flag
    JSR shell_open
    SET A, POP ; Read error code
    ADD SP, 3
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Prepare to load
    SET B, 0 ; Load at 0
    
.load_loop:
    ; Read words from the file until EOF. Since we're guaranteed partial read
    ; success when hitting the EOF, we can just read in big chunks.
    SET PUSH, file ; Arg 1: file
    SET PUSH, B ; Arg 2: buffer
    SET PUSH, BBFS_WORDS_PER_SECTOR ; Arg 3: length
    JSR bbfs_file_read
    SET A, POP
    ADD SP, 2
    IFE A, BBFS_ERR_EOF
        ; We hit EOF so we're done copying
        SET PC, .load_done
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; If we get here, we succeeded but there's more to do.
    ADD B, BBFS_WORDS_PER_SECTOR ; Write after what we just loaded
    SET PC, .load_loop
        
.load_done:

    ; Now we can save all the registers and then run the code
    SET PUSH, A
    SET PUSH, B
    SET PUSH, C
    SET PUSH, I
    SET PUSH, J
    SET PUSH, X
    SET PUSH, Y
    SET PUSH, Z
    
    ; Load the file's drive into A, just to be like the bootloader
    SET A, [file+BBFS_FILE_DRIVE]
    
    ; Run the loaded code
    JSR 0
    
    ; If we get back here, we know they didn't clobber the stack and actually
    ; returned. Try and restore our state.
    SET Z, POP
    SET Y, POP
    SET X, POP
    SET J, POP
    SET I, POP
    SET C, POP
    SET B, POP
    SET A, POP
    
    SET [Z], 1 ; We succeeded in running a program
    SET PC, .return
 
.error_usage:
    SET PUSH, str_load_usage ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET [Z], 0
    SET PC, .return
.error_A:
    ; We did not successfuly load the file
    SET [Z], 0
    SET PC, .return
.return:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
    

; We depend on bbfs
#include <bbfs.asm>

; Strings
str_ready:
    ASCIIZ "DC-DOS 1.2 Ready"
str_prompt:
    ASCIIZ ":\\> "
str_ver_version1:
    ASCIIZ "DC-DOS Command Interpreter 1.2"
str_ver_version2:
    ASCIIZ "Copyright (C) UBM Corporation"
str_not_found:
    ASCIIZ ": Bad command or file name"
str_format_usage:
    ASCIIZ "Usage: FORMAT <DRIVELETTER>"
str_no_drive:
    ASCIIZ "No drive "
str_no_media:
    ASCIIZ "No media in drive "
str_write_protected:
    ASCIIZ "Write-protected disk in drive "
str_error_unknown:
    ASCIIZ "Unknown error"
str_colon:
    ASCIIZ ":"
str_boot_filename:
    ASCIIZ "BOOT.IMG"
str_format_success:
    ASCIIZ "Formatted drive "
str_dir_directory:
    ASCIIZ "Directory listing of "
str_copy_copied:
    ASCIIZ "Copied "
str_copy_to:
    ASCIIZ " to "
str_copy_usage:
    ASCIIZ "Usage: COPY <FILE1> <FILE2>"
str_error_not_found:
    ASCIIZ "File not found"
str_error_drive:
    ASCIIZ "Drive invalid"
str_del_usage:
    ASCIIZ "Usage: DEL <FILE>"
str_del_deleted:
    ASCIIZ "Deleted "
str_load_usage:
    ASCIIZ "Usage: LOAD <FILE>"
str_img_extension: ; IMG binaries load at 0
    ".IMG"
str_com_extension: ; COM binaries will be a bit smarter probably.
    ".COM"
    
    
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
str_builtin_copy:
    ASCIIZ "COPY"
str_builtin_del:
    ASCIIZ "DEL"
str_builtin_load:
    ASCIIZ "LOAD"

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
    ; COPY builtin
    DAT str_builtin_copy
    DAT shell_builtin_copy
    ; DEL builtin
    DAT str_builtin_del
    DAT shell_builtin_del
    ; LOAD builtin
    DAT str_builtin_load
    DAT shell_builtin_load
    ; No more builtins
    DAT 0
    DAT 0
    
; Code for the bootloader
bootloader_code:
#include <bbfs_bootloader.asm>

; Now our .org has been messed up, so we set non-const data up in high-ish
; memory

.org SHELL_DATA_START

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
header2:
    RESERVE BBFS_HEADER_SIZEOF
file2:
    RESERVE BBFS_FILE_SIZEOF
; We need a place to put the code that moves the main code into high memory We
; save it so we can write it out if we need to format a disk. We can't just
; leave it at the front of our code because then we can't get the .orgs to match
; up with the real addresses.
format_copyloader:
    RESERVE 32
    
