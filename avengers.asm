; Self-hosting DCPU Assembler

; Idea: the assembler is based on a finite state automaton that accepts each source character in turn.
; Each state is represented by an address, and has a table of transitions.
; Each transition has an associated hook that is called when the transition ahppens, and which works on global state.
; Characters not matching a transition are ignored, so you stay in the same state.
; TODO: support a default transition and hook?

; Layout:
;
;
; +-------------------
; | Start Character (nonzero)
; +-------------------
; | End Character (inclusive)
; +-------------------
; | Next State
; +-------------------
; | Hook
; +-------------------
; | Start Character (nonzero)
; +-------------------
; | End Character (inclusive)
; +-------------------
; | Next State
; +-------------------
; | Hook
; +-------------------
; ...
; +-------------------
; | NULL
; +-------------------
;
;
;

; Defines
.define BBOS_WRITE_CHAR, 0x1003
.define BBOS_WRITE_STRING, 0x1004
.define BBOS_IRQ_MAGIC, 0x4743

; Main entry point

:main
    ; Assemble a program
    SET PUSH, program
    SET PUSH, output
    JSR assemble_instruction
    ADD SP, 2
    
    ; Print it
    SET PUSH, [output]
    JSR write_hex
    ADD SP, 1
    SET PUSH, [output+1]
    JSR write_hex
    ADD SP, 1
    SET PUSH, [output+2]
    JSR write_hex
    ADD SP, 1
    SET PUSH, [output+3]
    JSR write_hex
    ADD SP, 1

:halt
    SET PC, halt



:program
.dat "SET A, 1"
.dat 0x0000
:output
.dat 0x0000
.dat 0x0000
.dat 0x0000
.dat 0x0000

; write_hex(value)
; Print a value as hex on a line
; [Z]: value to write
; Returns: nothing
:write_hex
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS scratch
    SET PUSH, B ; itoh scratch
    SET PUSH, C ; character count
    
    ; Print "0x"
    SET PUSH, write_hex_lead ; String
    SET PUSH, 0 ; Newline
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; We have 4 digit numbers
    SET C, 4
    
:write_hex_do_digit
    IFE C, 0
        SET PC, write_hex_done
    
    SET B, [Z] ; Load the value
    AND B, 0xF000 ; Grab the first nibble
    SHR B, 12 ; Shift it down
    
    ; We need two different ASCII base points to make hex work
    IFG B, 9
        SET PC, write_hex_is_high

    ADD B, 0x0030 ; '0'
    SET PC, write_hex_print_it
:write_hex_is_high
    ADD B, 0x0037 ; 'A' - 10
:write_hex_print_it
    ; Display the character
    SET PUSH, B ; Char
    SET PUSH, 1 ; Move cursor
    SET A, BBOS_WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Shift out what we just showed
    SHL [Z], 4
    
    ; Say we printed a character
    SUB C, 1
    SET PC, write_hex_do_digit
:write_hex_done

    ; Print newline
    SET PUSH, write_hex_tail ; String
    SET PUSH, 1 ; Newline
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2

    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
:write_hex_lead
    .asciiz "0x"
:write_hex_tail
    .dat 0x0000

; assemble_instruction(*line, *dest)
; Assemble a single statement in a null-terminated string.
; [Z+1]: string to assemble
; [Z]: location to write assembled code at
; Returns: location after written assembled data
:assemble_instruction
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Character pointer
    SET PUSH, B ; Index into state table
    SET PUSH, C ; Character scratch
    
    ; Start at the start of the source
    SET [source_pointer], [Z+1]
    ; And put output at the place alloted for it
    SET [binary_pointer], [Z]
    
    ; Set up the FSM
    SET [current_state], state_start
    
    ; Now do the FSM
:fsm_loop
    ; Stop on null
    SET A, [source_pointer]
    IFE [A], 0
        SET PC, fsm_done
        
    ; Otherwise, scan our table
    SET B, [current_state]

:transition_loop
    IFE [B], 0
        ; Ran out of entries without taking a transition. Feed the next character to this state.
        SET PC, fsm_next
        
    ; Otherwise, see if we match this transition
    
    IFL [A], [B]
        ; Character is < min character
        SET PC, transition_next
    IFG [A], [B+1]
        ; Character is > max character
        SET PC, transition_next
   
    ; Otherwise, this is the transition to take.
    ; Call the hook
    IFN [B+3], 0x0000
        JSR [B+3]
    
    ; Move to designated next state
    SET [current_state], [B+2]
    
    ; Do the next character
    SET PC, fsm_next
        
:transition_next
    ; Try the next transition
    ADD B, 4
    SET PC, transition_loop
        
:fsm_next
    ; Advance a character and feed it to the current state
    ADD [source_pointer], 1
    SET PC, fsm_loop
    
:fsm_done
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

    
; hook_instruction_done()
; Handle the end of the instruction. Look it up in the opcode table and emit its assembled version.
; Returns: nothing
:hook_instruction_done
    ; TODO: implement
    SET PUSH, A ; Indexing scratch
    SET A, [source_pointer]
    SET [A], 0xDEAD
    ADD [source_pointer], 1
    SET A, POP
    SET PC, POP
    
; Here's the FSM globals
; What state are we in?
:current_state
.dat 0
; Where are we in the source?
; This points to the character driving the current transition, when a hook is running.
:source_pointer
.dat 0
; Where should we write our next word?
:binary_pointer
.dat 0
    
; Here's the state table

; We start lines in this state
:state_start
; Semicolons start a comment
.dat ";"
.dat ";"
.dat state_comment
.dat 0
; Capital letters introduce an instruction
.dat "A"
.dat "Z"
.dat state_instruction1
.dat 0
.dat 0

; Instructions take a second character
:state_instruction1
.dat "A"
.dat "Z"
.dat state_instruction2
.dat 0
.dat 0
; And a third
:state_instruction2
.dat "A"
.dat "Z"
.dat state_instruction3
.dat 0
.dat 0

; After 3 letters we have a hook that reads the instruction and emits its word
:state_instruction3
.dat " "
.dat " "
.dat state_start
.dat 0
.dat 0

; We have comments
:state_comment
; Comments are terminated by newlines
.dat "\n"
.dat "\n"
.dat state_start
.dat 0
.dat 0


































