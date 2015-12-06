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
    SET Z, POP
    SET PC, POP

; We depend on bbfs
#include <bbfs.asm>

; Strings
str_ready:
    ASCIIZ "BB-DOS 1.0 Ready"
str_prompt:
    ASCIIZ ":/> "
str_version1:
    ASCIIZ "BB-DOS Command Interpreter 1.0"
str_version2:
    ASCIIZ "Copyright (C) APIGA AUTONOMICS"
str_not_found:
    ASCIIZ ": Bad command or file name"
    
str_newline:
    ; TODO: ASCIIZ doesn't like empty strings in dasm
    DAT 0
    
; Builtin names:
str_builtin_ver:
    ASCIIZ "VER"

; Builtins table
;
; Each record is a pointer to a string and the address of a function to call
; when that command is run. Terminates with a record of all 0s.
builtins_table:
    ; VER builtin
    DAT str_builtin_ver
    DAT shell_builtin_ver
    ; No more builtins
    DAT 0
    DAT 0

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
; String buffer for commands
command_buffer:
    RESERVE SHELL_COMMAND_LINE_LENGTH
; Packed filename for looking through directories
packed_filename:
    RESERVE BBFS_FILENAME_PACKED
    
