; shell.asm: command shell for loading commands off of a BBFS disk.

#include <dcdos_api.inc.asm>

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

; Get BBOS info
define GET_BBOS_INFO    0x0000
; And the offsets to varoious fields
define BBOS_INFO_VERSION        0
define BBOS_INFO_START_ADDR     1
define BBOS_INFO_END_ADDR       2
define BBOS_INFO_INT_HANDLER    3
define BBOS_INFO_API_HANDLER    4

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

; How long can a command binary name be, including a trailing null? Max file
; name length minus extension.
define SHELL_COMMAND_LENGTH 13

; What's the BBOS bootloader magic number?
define BBOS_BOOTLOADER_MAGIC 0x55AA
define BBOS_BOOTLOADER_MAGIC_POSITION 511

; We want to load the shell code into high memory, so that if we want to load
; another binary off of a disk, we can fit one of a decent size before it starts
; to overwrite the routines trying to load it.

; BBOS likes to load at 0xF000. If we could relocate ourselves, we could just
; ask it where to load. Unfortunately, we can't, so we just load at a fixed
; offset.

; This leaves us 12k for code above, and 40k for user/loaded code below.
define SHELL_CODE_START 0xA000 

; This leaves us a bit under 8k for data and BBOS's VRAM.
define SHELL_DATA_START 0xD000

; TODO: develop a bank switching peripheral to swap out 8k banks or something.

zero:
    ; Here we have some simple code to move the rest up to high memory
    
    SET I, moveable_start ; This is where we find the code to move
    SET J, start ; This is where it goes
    ; Calculate (at assembly time) how many words to copy
    SET C, bootloader_code+BBFS_MAX_SECTOR_SIZE-start
    
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
    
    ; Sanity check: make sure the end of our code copied. We expect a set PC, nextword here
    ; If not, jump there and explode
    IFN [halt], 0x7f81
        SET PC, halt

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
    
    ; Configure our interrupt handler. See
    ; <https://github.com/MadMockers/BareBonesOS>
    SET A, GET_BBOS_INFO    ; Get BBOS Info
    SUB SP, 1               ; placeholder for return value
    INT BBOS_IRQ_MAGIC      ; invoke BBOS
    SET A, POP              ; pop address of info struct into A
    
    ; update global bbos_int_addr with the value from the struct
    SET [bbos_int_addr], [A+BBOS_INT_HANDLER]

    IAS dcdos_interrupt_handler ; Set system interrupt handler

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
;   builtins and then out to the given disk for files with executable extension.
; shell_open(*file, *filename, create)
;   Populate a file object by opening the given file object on the appropriate
;   drive (either the current one or one derived from a leading A:\ in the
;   filename). Clobbers the global directory and dirinfo space, and may
;   initialize drive2, device2, and volume2 if needed. If create is specified,
;   creates the file if it can't be found. Returns an error code, and the file
;   index in the global directory if found.
; shell_resolve_drive(character)
;   Turn a drive letter into a drive number, or 0xFFFF if a bad drive letter.
; shell_atoi(*string)
;   Return the decimal number represented by the given string, or 0 if the
;   string is empty or unparseable.

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
;
; shell_builtin_image(*arguments)
;   Images the disk in the drive given as the first argument to the file named
;   with the second argument. Filenames may be prefixed as <DRIVE>:\. Saves
;   complete sectors of the disk, until a sector of all 0s is encountered.
;   Can take an optional sector count argument instead.

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
    SET PUSH, X ; Cursor horizontal scratch
    SET PUSH, Y ; Cursor vertical scratch
    
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
    ; TODO: don't ignore
    SET PC, .key_loop
.key_arrow_right:
    ; TODO: don't ignore
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
    SET Y, POP ; Save the height
    SET X, POP ; Save the width. 
    
    ; Now get the cursor position.
    SUB SP, 2
    SET A, GET_CURSOR_POS
    INT BBOS_IRQ_MAGIC
    SUB Y, POP ; Subtract the cursor row
    SUB X, POP ; Subtract the cursor column.
    
    ; Write the typed character to the screen
    SET PUSH, C ; Arg 1: character to write
    SET PUSH, 1 ; Arg 2: move cursor or not
    SET A, WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    IFN X, 1
        ; We weren't about to fill in the last column, so no scrolling is needed
        SET PC, .no_scroll_needed
    
    IFN Y, 1
        ; We were not on the last row of the terminal, which is really the only
        ; place we need the newline.
        SET PC, .no_scroll_needed
        
    ; Else we're out of room on this line. Print a newline.
    SET PUSH, str_newline
    SET PUSH, 1 ; With newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; We need to update our home position for when we re-print on
    ; backspace.
    SUB [SP], 1
        
.no_scroll_needed:
    SET PC, .key_loop
.return:
    ADD SP, 2 ; Delete the cursor start X and Y
    SET Y, POP
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
; Try the command at the start of the buffer as a builtin, then as a file with
; executable extension on the given disk, then as a file with the executable
; extension appended.
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
    
    ; Save the argument string in case we end up calling a program and it wants
    ; to get it through the interrupt API
    SET [arguments_start], X
    
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
    SUB A, [Z+1] ; Now A is the command length
    
    IFN B, 0
        ; We found an extension in the string.
        SET PC, .try_load_with_extension
    
    ; Otherwise, try adding it on and running that. Filenames are 16 chars, so
    ; we need 12 or fewer for this to work.
    IFL A, 13
        SET PC, .try_load_without_extension
        
    SET PC, .error_bad_command
        
; Try loading the command, appending an executable extension
.try_load_without_extension:
    ; Copy the filename over to our global filename buffer
    SET A, [Z+1]
    SET B, filename
.buffer_loop:
    SET [B], [A]
    IFE [A], 0
        SET PC, .buffer_loop_done
    ADD A, 1
    ADD B, 1
    SET PC, .buffer_loop
.buffer_loop_done:
    ; Append the executable extension
    SET A, str_executable_extension
.ext_loop:
    SET [B], [A]
    IFE [A], 0
        SET PC, .ext_loop_done
    ADD A, 1
    ADD B, 1
    SET PC, .ext_loop
.ext_loop_done:
    ; Load it
    SET PUSH, filename ; Arg 1: filename string
    JSR shell_builtin_load
    SET Y, POP
    
    IFE Y, 0
        ; We didn't load successfully
        SET PC, .error_bad_command
    
    ; Otherwise it ran
    SET PC, .return
    
.try_load_with_extension:
    ; A is the filename length and B is the extension start
    ; See if the extension is executable and if so load from disk.
    
    ; Do we have the executable extension?
    SET PUSH, str_executable_extension ; Arg 1: string 1
    SET PUSH, B ; Arg 2: string 2
    SET PUSH, 1 ; Arg 3: ignore case
    SET PUSH, 4 ; Arg 4: number of characters (".EXT")
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
    
    ; Open the main device on this drive
    SET PUSH, device
    SET PUSH, B
    JSR bbfs_device_open
    ADD SP, 2 ; Can't fail
        
    ; And open the main volume on that device
    SET PUSH, volume
    SET PUSH, device
    JSR bbfs_volume_open
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        IFN A, BBFS_ERR_UNFORMATTED
            SET PC, .error_unknown    
            
    ; Format the volume
    SET PUSH, volume
    JSR bbfs_volume_format
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
    
    ; Make a root directory.
    ; Since it's the first thing on the disk it ends up at the right sector.
    SET PUSH, directory ; Arg 1: directory handle to open
    SET PUSH, volume ; Arg 2: volume to make the directory on
    JSR bbfs_directory_create
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
    
    ; Save a memory image to "BOOT.IMG" that will boot back to this code.
    ; Make a file
    
    SET PUSH, file ; Arg 1: file struct to populate
    SET PUSH, volume ; Arg 2: volume to work in
    JSR bbfs_file_create
    SET A, POP
    ADD SP, 1
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
    SET PUSH, bootloader_code+BBFS_MAX_SECTOR_SIZE-start ; Arg 3: length
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
        
    ; And flush. This syncs the device.
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
    
    SET PC, .say_drive_and_return
    
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
    
    SET PC, .say_drive_and_return
    
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
    
    ; Set up main drive device
    SET PUSH, device
    SET PUSH, B
    JSR bbfs_device_open
    ADD SP, 2 ; Can't fail
        
    ; And main drive volume
    SET PUSH, volume
    SET PUSH, device
    JSR bbfs_volume_open
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, .error_unknown
        
    ; Open the directory
    SET PUSH, directory ; Arg 1: directory
    SET PUSH, volume ; Arg 2: BBFS_VOLUME
    SET PUSH, volume ; Arg 3: find the root directory sector
    JSR bbfs_volume_get_first_usable_sector
    JSR bbfs_directory_open
    SET A, POP
    ADD SP, 2
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
    
    SET PC, .say_drive_and_return
    
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
    SET PUSH, B ; Words successfully read
    SET PUSH, C ; Second file name
    
    

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
    
    ; Set up filesystem globals
    ; Drive2 is currently unused
    SET [drive2], 0xFFFF
    
    ; Set up main drive device
    SET PUSH, device
    SET PUSH, [drive]
    JSR bbfs_device_open
    ADD SP, 2 ; Can't fail
        
    ; And main drive volume
    SET PUSH, volume
    SET PUSH, device
    JSR bbfs_volume_open
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
    
    ; Open the first file, not creating
    ; shell_open(*file, *filename, create)
    SET PUSH, file ; Arg 1: file to populate
    SET PUSH, [Z] ; Arg 2: unpacked filename string
    SET PUSH, 0 ; Arg 3: create flag
    JSR shell_open
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Open the second file, creating
    SET PUSH, file2 ; Arg 1: file to populate
    SET PUSH, C ; Arg 2: unpacked filename string
    SET PUSH, 1 ; Arg 3: create flag
    JSR shell_open
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; TODO: what if the two files are on different, non-main drives? shell_open
    ; will get confused.
        
    IFE [file+BBFS_FILE_VOLUME], [file2+BBFS_FILE_VOLUME]
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
    SET PUSH, copy_buffer ; Arg 2: buffer
    SET PUSH, COPY_BUFFER_SIZE ; Arg 3: length
    JSR bbfs_file_read
    SET A, POP ; Grab error code
    SET B, POP ; And words read
    ADD SP, 1
    IFN A, BBFS_ERR_EOF
        IFN A, BBFS_ERR_NONE
            ; Wasn't an EOF and wasn't success
            SET PC, .error_A
        
    ; Write to file 2
    SET PUSH, file2 ; Arg 1: file
    SET PUSH, copy_buffer ; Arg 2: buffer
    SET PUSH, B ; Arg 3: length
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    IFE B, COPY_BUFFER_SIZE    
        ; We filled the read buffer. Loop around and copy more data.
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
    
    ; Set up filesystem globals
    ; Drive2 is currently unused
    SET [drive2], 0xFFFF
    
    ; Set up main drive device
    SET PUSH, device
    SET PUSH, [drive]
    JSR bbfs_device_open
    ADD SP, 2 ; Can't fail
        
    ; And main drive volume
    SET PUSH, volume
    SET PUSH, device
    JSR bbfs_volume_open
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
    
    ; Open the file, not creating
    ; shell_open(*file, *filename, create)
    SET PUSH, file ; Arg 1: file to populate
    SET PUSH, [Z] ; Arg 2: unpacked filename string
    SET PUSH, 0 ; Arg 3: create flag
    JSR shell_open
    SET A, POP ; Read error code
    SET B, POP ; Read second return value: index file is at in global directory
    ADD SP, 1
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
        
    ; Sync all applicable devices
    SET PUSH, device
    JSR bbfs_device_sync
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
    
    IFE [drive2], 0xFFFF
        SET PC, .no_drive2 
    SET PUSH, device2
    JSR bbfs_device_sync
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
.no_drive2:
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
    
; shell_open(*file, *filename, create)
; Populate the given file by opening the given filename. Get drive
; from filename if possible.
; [Z+2]: BBFS_FILE to populate
; [Z+1]: File name buffer. May have a leading drive like A: or A:\. May be
; modified.
; [Z] Flag for whether to create the file if it does not exist.
; Returns: Error code in [Z], index of file in directory in [Z+1]
; Side effect: leaves global directory open to the file's directory.
; TODO: make it be passed in by argument or something.
;
; PRECONDITION: volume and device must be open for the global [drive], and
; either [drive2] must be 0xFFFF or volume2 and device2 must be open for it.
shell_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls/scratch
    SET PUSH, B ; Drive number to use/scratch for parsing it
    SET PUSH, C ; Actual file name start
    SET PUSH, X ; Index in directory
    SET PUSH, Y ; Volume struct to use
    
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
    
    IFE B, [drive]
        ; We can just use the main drive, which has its volume set up already.
        ; No need for drive2/volume2
        SET PC, .drive_main
    IFE B, [drive2]
        ; We already have this other drive mounted up as device2/volume2
        SET PC, .drive_current
        
    ; Otherwise we need to set up drive2 and volume2
    IFE [drive2], 0xFFFF
        ; No need to sync; drive not initialized yet
        SET PC, .load_new_drive
        
    ; Sync the device #2
    SET PUSH, device2
    JSR bbfs_device_sync
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
.load_new_drive:
    SET [drive2], B

    ; Set up device2 to point to this new drive
    SET PUSH, device2
    SET PUSH, [drive2]
    JSR bbfs_device_open
    ADD SP, 2 ; Can't fail
        
    ; Load volume 2 on top of it
    SET PUSH, volume2
    SET PUSH, device2
    JSR bbfs_volume_open
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Continue on with the current secondary drive
    SET PC, .drive_current
    
.drive_main:
    ; Use the currently selected main drive and its associated filesystem
    SET Y, volume
    SET PC, .drive_ready
    
.drive_current:
    ; Use the current alternate drive
    SET Y, volume2
    SET PC, .drive_ready
    
.drive_ready:
    
    ; Open the root directory
    SET PUSH, directory ; Arg 1: BBFS_DIRECTORY
    SET PUSH, Y ; Arg 2: volume
    ; Drop the first usable sector (where the root lives) on the stack
    SET PUSH, Y
    JSR bbfs_volume_get_first_usable_sector ;  Arg 3: directory start sector
    JSR bbfs_directory_open
    SET A, POP
    ADD SP, 2
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
    SET PUSH, Y ; Arg 2: volume
    JSR bbfs_file_create
    SET A, POP
    ADD SP, 1
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
    SET PUSH, Y ; Arg 2: FS volume
    SET PUSH, [entry+BBFS_DIRENTRY_SECTOR] ; Arg 3: sector to start at
    JSR bbfs_file_open
    SET A, POP
    ADD SP, 2
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
    SET Y, POP
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
    
; shell_atoi(*string)
; Return the decimal parse of the given null-terminated string, or 0 if the
; string cannot be parsed.
; [Z]: null-terminated string
; Returns: parsed decimal value in [Z]

shell_atoi:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Parsed value
    SET PUSH, B ; Cursor
    
    ; Start at the first character
    SET B, [Z]
    
    ; Start with 0 as our value so far
    SET A, 0
    
.loop:
    IFE [B], 0
        ; Null terminator. Return.
        SET PC, .return
        
    IFL [B], 0x30 ; '0'
        ; Too small to be a digit
        SET PC, .return
        
    IFG [B], 0x39 ; '9'
        SET PC, .return
        
    ; Scale what we have by 10 since there's another digit
    MUL A, 10
    
    ; Knock the digit base value off the character we have
    SUB [B], 0x30 ; '0'
    
    ; Add in the numerical value that's left
    ADD A, [B]
    
    ; Look at the next character
    ADD B, 1
    
    SET PC, .loop
    
.return:
    SET [Z], A    
    
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
    SET PUSH, C ; Progress words/scratch
    
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
    
    ; Set up filesystem globals
    ; Drive2 is currently unused
    SET [drive2], 0xFFFF
    
    ; Set up main drive device
    SET PUSH, device
    SET PUSH, [drive]
    JSR bbfs_device_open
    ADD SP, 2 ; Can't fail
        
    ; And main drive volume
    SET PUSH, volume
    SET PUSH, device
    JSR bbfs_volume_open
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
    
    ; Open the file, not creating
    ; shell_open(*file, *filename, create)
    SET PUSH, file ; Arg 1: file to populate
    SET PUSH, [Z] ; Arg 2: unpacked filename string
    SET PUSH, 0 ; Arg 3: create flag
    JSR shell_open
    SET A, POP ; Read error code
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Prepare to load
    SET B, 0 ; Load at 0
    
    ; Mark 0 so we know if we load anything.
    SET [B], 0xFFFF
    
.load_loop:
    ; Read words from the file until EOF. Since we're guaranteed partial read
    ; success when hitting the EOF, we can just read in big chunks.
    SET PUSH, file ; Arg 1: file
    SET PUSH, B ; Arg 2: buffer
    SET PUSH, BBFS_MAX_SECTOR_SIZE ; Arg 3: length
    JSR bbfs_file_read
    SET A, POP ; Read error code
    SET C, POP ; Read words read
    ADD SP, 1
    
    IFE A, BBFS_ERR_EOF
        ; We hit EOF so we're done copying
        SET PC, .load_done
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; If we get here, we succeeded but there's more to do.
    ADD B, BBFS_MAX_SECTOR_SIZE ; Write after what we just loaded
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
    SET A, [file+BBFS_FILE_VOLUME]
    ADD A, BBFS_VOLUME_ARRAY ; This one is just containment
    SET A, [A+BBFS_ARRAY_DEVICE]
    SET A, [A+BBFS_DEVICE_DRIVE]
    
    ; Zero everyone else, for compatibility
    SET B, 0
    SET C, 0
    SET X, 0
    SET Y, 0
    SET Z, 0
    SET I, 0
    set J, 0
    
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
    
    ; TODO: split out the actual loading code from the builtin, so we don't see
    ; this message whenever a binary can't be loaded for a bogus command
    
    SET PUSH, str_load_fail ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, .return
.return:
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; shell_builtin_image(*arguments)
; Copy disk to file, with drive letter support.
; [Z]: argument string
shell_builtin_image:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls/scratch
    SET PUSH, B ; Drive to read from
    SET PUSH, C ; Destination file name
    SET PUSH, X ; Sector being read
    SET PUSH, Y ; Scratch for iterating through sector
    SET PUSH, I ; Device sector size
    SET PUSH, J ; Remaining sectors we need to load due to our argument
    
    ; Parse the command line
    ; Split out the drive letter
    
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
        
    ; Now check to make sure there's a disk
    SET PUSH, B
    SET A, CHECK_DRIVE_STATUS
    INT BBOS_IRQ_MAGIC
    SET A, POP
    
    ; Shift down to have only the high (status) octet
    SHR A, 8
    
    ; Check to make sure we have a ready disk
    IFE A, STATE_NO_MEDIA
        SET PC, .error_no_media
        
    IFN A, STATE_READY_WP
        IFN A, STATE_READY
            SET PC, .error_unknown
            
    ; Now finish parsing the destination filename
    ; Start filename after the drive
    SET C, [Z] 
    ADD C, 1
    
    ; We need a space
    IFN [C], 0x20
        SET PC, .error_usage
        
    ; Null it out
    SET [C], 0
    ADD C, 1
    
    ; Slide over all other spaces
.parse_spaces_loop:
    IFE [C], 0 ; No second filename
        SET PC, .error_usage
    IFN [C], 0x20 ; Found a non-space
        SET PC, .parse_spaces_done
        
    ; Try the next character
    ADD C, 1
    SET PC, .parse_spaces_loop
    
.parse_spaces_done:
    ; Now we found the start of the second filename.
    ; We want to go out and null out the first space after the filename, if any.
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
    
    ; If we already have a 0 here, then there's no 3rd argument. So we can leave
    ; A here and parse the null string and get a 0 sector count
    IFE [A], 0
        SET PC, .parse_more_spaces_done
    
    ; Zero out this character, which may be a space, so the filename string is
    ; terminated
    SET [A], 0
    ; And skip it
    ADD A, 1

    ; Now we want to look for an optional third argument of sector count
    
    ; Slide over all spaces
.parse_more_spaces_loop:
    IFE [A], 0 ; No third argument (null string)
        SET PC, .parse_more_spaces_done
    IFN [A], 0x20 ; Found a non-space
        SET PC, .parse_more_spaces_done
        
    ; Try the next character
    ADD A, 1
    SET PC, .parse_more_spaces_loop
    
.parse_more_spaces_done:
    ; Either [A] is 0 or it is the first character of the third, optional
    ; argument
    
    ; Parse the argument and get either a number or 0 if there's no valid
    ; argument.
    SET PUSH, A
    JSR shell_atoi
    SET J, POP
    
    ; We have now parsed our arguments
    
    ; Set up filesystem globals
    
    ; Set up filesystem globals
    ; Drive2 is currently unused
    SET [drive2], 0xFFFF
    
    ; Set up main drive device
    SET PUSH, device
    SET PUSH, [drive]
    JSR bbfs_device_open
    ADD SP, 2 ; Can't fail
        
    ; And main drive volume
    SET PUSH, volume
    SET PUSH, device
    JSR bbfs_volume_open
    SET A, POP
    ADD SP, 1
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Set up raw drive as the source drive
    SET [drive_raw], B
    SET PUSH, device_raw ; Arg 1: devide to fill
    SET PUSH, [drive_raw] ; Arg 2: drive to open
    JSR bbfs_device_open
    ; Remember, no return code!
    ADD SP, 2
    
    ; Open the destination file, creating
    ; It may be on either drive, but it will only make a proper consistent image
    ; if we're on not the drive being imaged.
    SET PUSH, file ; Arg 1: file to populate
    SET PUSH, C ; Arg 2: unpacked filename string
    SET PUSH, 1 ; Arg 3: create flag
    JSR shell_open
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Work out what disk it is on
    SET PUSH, [file+BBFS_FILE_VOLUME]
    JSR bbfs_volume_get_device
    SET A, POP

    ; We can't have two devices trying to use the same drive. They'll confuse
    ; each other with caches.    
    IFE [A+BBFS_DEVICE_DRIVE], [drive_raw]
        SET PC, .error_same_drive
    
    ; Truncate the file (in case it existed already)
    SET PUSH, file ; Arg 1: file to truncate
    JSR bbfs_file_truncate
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Decide how long source disk sectors are
    SET PUSH, device_raw ; Arg 1 for argument call: device
    JSR bbfs_device_sector_size ; Get the device sector size
    SET I, POP
    
    ; Until EOF, read a sector from the source disk and write it to the file. 
    SET X, 0
.copy_loop:

    ; Read from the disk
    ; bbfs_device_get(device*, word sector)
    SET PUSH, device_raw ; Arg 1: device to read from
    SET PUSH, X ; Arg 2: Sector to read
    JSR bbfs_device_get
    SET A, POP
    ADD SP, 1
    
    ; If we can't read the sector, something is wrong
    IFE A, 0x0000
        SET PC, .error_unknown
        
    ; We read the sector. Do we have any more sectors we must read?
    IFN J, 0
        ; We read one
        SUB J, 1
    IFN J, 0
        ; There are more to go, so don't look if this one is all 0s
        SET PC, .scan_done
        
    ; Now look for a whole sector of 0s
    SET Y, A
.scan_loop:
    IFN [Y], 0
        SET PC, .scan_done
    ADD Y, 1
    ; Look at how far we are from the start.
    SUB Y, A
    ; If we made it all the way to the end of the sector and saw nothing
    ; nonzero, don't bother writing the sector.
    IFE Y, I
        SET PC, .copy_done
    ; Otherwise keep looping
    ADD Y, A
    SET PC, .scan_loop
    
.scan_done:
    ; Write to file
    SET PUSH, file ; Arg 1: file
    SET PUSH, A ; Arg 2: buffer
    SET PUSH, I ; Arg 3: length to write (a whole sector for source disk)
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; Try the next sector
    ADD X, 1
    
    ; Figure out if we're done due to seeing all the sectors
    SET PUSH, device_raw ; Arg 1 for argument call: device
    JSR bbfs_device_sector_count ; Get the device sector count
    SET A, POP
    
    ; If we're at the past the end sector to do next, stop
    IFE X, A
        SET PC, .copy_done
        
    SET PC, .copy_loop

.copy_done:
    ; We read and wrote all the words.
    
    ; Sync file
    SET PUSH, file ; Arg 1: file to flush
    JSR bbfs_file_flush
    SET A, POP
    IFN A, BBFS_ERR_NONE
        SET PC, .error_A
        
    ; We were successful.
    ; Print success.
    SET PUSH, str_image_imaged ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, [Z] ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, str_image_to ; Arg 1: string to print
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
    
    SET PUSH, str_image_usage ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, .return
    
.error_same_drive:
    ; Can't image a drive to itself
    
    SET PUSH, str_image_same ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, .return
    
.error_unknown:
    ; Something terrible has happened. Probably not being able to read the input
    ; disk...
    
    SET PUSH, str_error_unknown ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, .return
    
.error_bad_drive_letter:
    
    ; Put the error message
    SET PUSH, str_image_usage ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    set PC, .return
    
.error_no_drive:
    
    ; Put the error message
    SET PUSH, str_no_drive ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PC, .say_drive_and_return
    
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
    IFE A, 0x1
        SET B, str_error_busy
        
    ; Print the error
    SET PUSH, B ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
.return:
    SET J, POP
    SET I, POP
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; Handle all the DCDOS interrupts
dcdos_interrupt_handler:
    ; If this isn't a DCDOS interrupt, pass it to BBOS instead
    IFN A, DCDOS_IRQ_MAGIC
        SET PC, [bbos_int_addr]
    
    ; Otherwise handle it here.
    
    ; Fiddle with the stack and interrupt state so we are like we were before
    ; the interrupt.
    SET A, POP
    SET [dcdos_interrupt_ret_addr], POP
    IAQ 0
    
    ; A couple of commands can be handled in just one instruction
    IFE A, DCDOS_HANDLER_GET
        SET [SP], dcdos_interrupt_handler
    IFE A, DCDOS_ARGS_GET
        SET [SP], [arguments_start]
    ; The rest just call the appropriate function, with the args already on the
    ; stack.
    IFE A, DCDOS_SHELL_OPEN
        JSR shell_open
    IFE A, DCDOS_FILE_READ
        JSR bbfs_file_read
    IFE A, DCDOS_FILE_WRITE
        JSR bbfs_file_write
    IFE A, DCDOS_FILE_FLUSH
        JSR bbfs_file_flush
    IFE A, DCDOS_FILE_REOPEN
        JSR bbfs_file_reopen
    IFE A, DCDOS_FILE_SEEK
        JSR bbfs_file_seek
    IFE A, DCDOS_FILE_TRUNCATE
        JSR bbfs_file_truncate
    
    ; Jump from the handler back to the calling code. All registers are intact.
    SET PC, [dcdos_interrupt_ret_addr]
    
halt:
    ; We can jump here for debugging
    SET PC, halt

; We depend on bbfs
#include <bbfs.asm>

; Strings
str_ready:
    .asciiz "DC-DOS 3.1 Ready"
str_prompt:
    .asciiz ":\> "
str_ver_version1:
    .asciiz "DC-DOS Command Interpreter 3.1"
str_ver_version2:
    .asciiz "Copyright (C) UBM Corporation"
str_not_found:
    .asciiz ": Bad command or file name"
str_format_usage:
    .asciiz "Usage: FORMAT <DRIVELETTER>"
str_no_drive:
    .asciiz "No drive "
str_no_media:
    .asciiz "No media in drive "
str_write_protected:
    .asciiz "Write-protected disk in drive "
str_error_unknown:
    .asciiz "Unknown error"
str_colon:
    .asciiz ":"
str_boot_filename:
    .asciiz "BOOT.IMG"
str_format_success:
    .asciiz "Formatted drive "
str_dir_directory:
    .asciiz "Directory listing of "
str_copy_copied:
    .asciiz "Copied "
str_copy_to:
    .asciiz " to "
str_copy_usage:
    .asciiz "Usage: COPY <FILE1> <FILE2>"
str_image_imaged:
    .asciiz "Imaged drive "
str_image_to:
    .asciiz " to "
str_image_usage:
    .asciiz "Usage: IMAGE <DRIVE> <FILE> [<MIN_SECTORS>]"
str_image_same:
    .asciiz "Can't image drive to itself"
str_error_not_found:
    .asciiz "File not found"
str_error_drive:
    .asciiz "Drive invalid"
str_error_busy:
    .asciiz "Drive busy"
str_del_usage:
    .asciiz "Usage: DEL <FILE>"
str_del_deleted:
    .asciiz "Deleted "
str_load_usage:
    .asciiz "Usage: LOAD <FILE>"
str_load_fail:
    .asciiz "Load failed"
str_executable_extension: ; IMG binaries load at 0
    .asciiz ".IMG"
str_com_extension: ; COM binaries will be a bit smarter probably.
    .asciiz ".COM"
    
    
str_newline:
    ; TODO: .asciiz doesn't like empty strings in dasm
    DAT 0
    
; Builtin names:
str_builtin_ver:
    .asciiz "VER"
str_builtin_format:
    .asciiz "FORMAT"
str_builtin_dir:
    .asciiz "DIR"
str_builtin_copy:
    .asciiz "COPY"
str_builtin_del:
    .asciiz "DEL"
str_builtin_load:
    .asciiz "LOAD"
str_builtin_image:
    .asciiz "IMAGE"

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
    ; IMAGE builtin
    DAT str_builtin_image
    DAT shell_builtin_image
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
; Address of the original BBOS interrupt handler
bbos_int_addr:
    .reserve 1
; Interrupts into DCDOS aren't reentrant, so we can fill this in and use it when
; returning.
dcdos_interrupt_ret_addr:
    .reserve 1
; Current drive number
drive:
    .reserve 1
; BBFS structs for the current drive
device:
    .reserve BBFS_DEVICE_SIZEOF
volume:
    .reserve BBFS_VOLUME_SIZEOF
; File for loading things
file:
    .reserve BBFS_FILE_SIZEOF
; Directory for scanning through
directory:
    .reserve BBFS_DIRECTORY_SIZEOF
; Entry struct for accessing directories
entry:
    .reserve BBFS_DIRENTRY_SIZEOF
; String buffer for commands
command_buffer:
    .reserve SHELL_COMMAND_LINE_LENGTH
; Pointer to arguments string (which will be somewhere in the above buffer)
arguments_start:
    .reserve 1
; Packed filename for looking through directories
packed_filename:
    .reserve BBFS_FILENAME_PACKED
; And an unpacked finename
filename:
    .reserve BBFS_FILENAME_BUFSIZE
; We sometimes need two filesystems in play. But we need to make sure they are
; never on the same drive.
drive2:
    ; This gets set to 0xFFFF when not in use.
    .reserve 1
device2:
    .reserve BBFS_DEVICE_SIZEOF
volume2:
    .reserve BBFS_VOLUME_SIZEOF
; And two files (which may be on either drive)
file2:
    .reserve BBFS_FILE_SIZEOF
; We also sometimes need a raw drive with no FS
drive_raw:
    .reserve 1
device_raw:
    .reserve BBFS_DEVICE_SIZEOF
; We need a place to put the code that moves the main code into high memory We
; save it so we can write it out if we need to format a disk. We can't just
; leave it at the front of our code because then we can't get the .orgs to match
; up with the real addresses.
format_copyloader:
    .reserve 32
; We also want a buffer for copy operations
define COPY_BUFFER_SIZE BBFS_MAX_SECTOR_SIZE
copy_buffer:
    .reserve COPY_BUFFER_SIZE
    
