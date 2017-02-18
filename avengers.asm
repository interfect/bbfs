; Self-hosting DCPU Assembler

; Idea: the assembler has a lexer which finds identifiers, numbers, operators,
; quoted strings, and so on.
;
; Then a shift-reduce parser comes in with a table of rules. Each rule can match
; the top two nodes on the parsing stack by type, with filter functions on each,
; and the next token in the text, and can decide to merge the top two nodes into
; a new node of a given type, shift in the next token, or both.
;
; Finally, the actual assembler bit turns the parse tree into actual assembled
; code.

; Tokens/syntax tree nodes look like this
;
; +---------------------
; | Type
; +---------------------
; | Child 1 (or null)
; +---------------------
; | Child 2 (or null)
; +---------------------
; | String start
; +---------------------
; | String end
; +---------------------

.define NODE_SIZEOF, 5
.define NODE_TYPE, 0
.define NODE_CHILD1, 1
.define NODE_CHILD2, 2
.define NODE_START, 3
.define NODE_END, 4


;  BBOS Defines
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

; Since we have dynamically instantiated parsing nodes we need a malloc/free

; Heap entries come one after the other and have a used flag and a length
.define HEAP_HEADER_SIZEOF, 2
.define HEAP_HEADER_LENGTH, 0
.define HEAP_HEADER_USED, 1

; malloc(size)
; Allocate a block of memory
; [Z]: size of block to allocate
; Returns: block address, or 0 if none can be allocated
:malloc
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Pointer to each heap header
    SET PUSH, B ; Allocation scratch
    
    SET A, heap_start
:malloc_heap_loop
    
    ; Is this entry used?
    IFE [A+HEAP_HEADER_USED], 1
        ; If so, skip to the next one
        SET PC, malloc_heap_next
    IFE [A+HEAP_HEADER_LENGTH], [Z]
        ; This block is exactly the rigth size
        SET PC, malloc_heap_found
    SET B, [Z]
    ADD B, HEAP_HEADER_SIZEOF
    IFL B, [A+HEAP_HEADER_LENGTH]
        ; We could split this block and have room for our allocation
        SET PC, malloc_heap_split
    ; Otherwise fall through and look at the next block
:malloc_heap_next
    ; Go to the next heap entry, by skipping actual memory words and the header
    ADD A, [A+HEAP_HEADER_LENGTH]
    ADD A, HEAP_HEADER_SIZEOF
    ; If we hit the end of the heap, give up
    IFE A, heap_start + HEAP_SIZE
        SET PC, malloc_heap_not_found
    SET PC, malloc_heap_loop
  
:malloc_heap_split
    ; We need to split the block at A into one of our allocation's size
    ; Find where the B block needs to start
    SET B, A
    ADD B, HEAP_HEADER_SIZEOF
    ADD B, [Z]
    ; Now B is where the next header should be. Initialize it
    ; It is unused
    SET [B+HEAP_HEADER_USED], 0
    ; And it is the size of A's memory, minus the B header, minus the allocation we're doing.
    SET [B+HEAP_HEADER_LENGTH], [A+HEAP_HEADER_LENGTH]
    SUB [B+HEAP_HEADER_LENGTH], HEAP_HEADER_SIZEOF
    SUB [B+HEAP_HEADER_LENGTH], [Z]
    ; Point A at the new header
    SET [A+HEAP_HEADER_LENGTH], [Z]
:malloc_heap_found
    ; This block at A is great! Allocate it!
    SET [A+HEAP_HEADER_USED], 1
    ; Return its memory address
    SET [Z], A
    ADD [Z], HEAP_HEADER_SIZEOF
    SET PC, malloc_return
:malloc_heap_not_found
    ; Return null
    SET [Z], 0x0000
:malloc_return
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; free(address)
; Free a block of memory
; [Z]: address returned from malloc
; Returns: nothing
:free
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Pointer to heap block header
    
    ; Find the heap header
    SET A, [Z]
    SUB A, HEAP_HEADER_SIZEOF
    
    ; Mark it free
    SET [A+HEAP_HEADER_USED], 0
    
    ; TODO: merge freed blocks when possible
    
    SET A, POP
    SET Z, POP
    SET PC, POP

.define HEAP_SIZE, 0x1000
:heap_start
DAT 0



























