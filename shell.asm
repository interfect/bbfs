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

; How long can a shell command be? This includes the trailing null.
define SHELL_COMMAND_LENGTH 128

start:

    ; Print the intro
    SET PUSH, str_ready ; Arg 1: string to print
    SET PUSH, 1 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
command_loop:
    SET PUSH, str_prompt ; Arg 1: string to print
    SET PUSH, 0 ; Arg 2: whether to print a newline
    SET A, WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2

    ; Read a command
    SET PUSH, command_buffer
    SET PUSH, SHELL_COMMAND_LENGTH
    JSR shell_readline
    ADD SP, 2
    
    SET PC, command_loop


; Functions

; shell_readline(*buffer, length)
;   Read a line into the buffer. Allow arrow keys to move left/right for insert,
;   and backspace for backspace. Returns when enter is pressed.

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
    SET X, POP ; Save the width. TODO: if BBOS updates, this may be the height.
    ADD SP, 1
    
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

; We depend on bbfs
#include <bbfs.asm>

; Strings
str_ready:
    ASCIIZ "BB-DOS 1.0 Ready"
str_prompt:
    ASCIIZ ":/> "
str_newline:
    ASCIIZ ""

; Global vars
; Current disk number
disk:
    RESERVE 1
; File for loading things
file:
    RESERVE BBFS_FILE_SIZEOF
; Directory for scanning through
directory:
    RESERVE BBFS_DIRECTORY_SIZEOF
; String buffer for commands
command_buffer:
    RESERVE SHELL_COMMAND_LENGTH
; Packed filename for looking through directories
packed_filename:
    RESERVE BBFS_FILENAME_PACKED
    
