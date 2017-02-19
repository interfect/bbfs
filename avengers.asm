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

; Here are the node types
; Tokens for bottom level lexemes
; Identifier, which can be a register name, label name, constant name, or instruction
.define NODE_TYPE_TOKEN_ID, 0x0001
; Comma character, for separating arguments
.define NODE_TYPE_TOKEN_COMMA, 0x0002
; Decimal number
.define NODE_TYPE_TOKEN_DEC, 0x0003
; Hexadecimal number
.define NODE_TYPE_TOKEN_HEX, 0x0004

; And some error codes
.define ASM_ERR_NONE, 0x0000
.define ASM_ERR_LEX_BAD_TOKEN, 0x0001 ; Found something that's not a real token
.define ASM_ERR_MEMORY, 0x0002 ; Ran out of heap space for syntax tree nodes
.define ASM_ERR_STACK, 0x0003 ; Ran out of space on the parsing stack(s)


;  BBOS Defines
.define BBOS_WRITE_CHAR, 0x1003
.define BBOS_WRITE_STRING, 0x1004
.define BBOS_IRQ_MAGIC, 0x4743

; Main entry point

:main
    ; Lex a line
    SET PUSH, program
    JSR lex_line
    SET B, POP ; Get the error code
    
    ; Print the error code label
    SET PUSH, str_error
    SET PUSH, 0
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Print the error code
    SET PUSH, B
    SET PUSH, 1
    JSR write_hex
    ADD SP, 2
    
    ; Dump the stack
    JSR dump_stack

:halt
    SET PC, halt

; Strings
:str_error
.asciiz "Error: "


; Assembler input/output for testing
:program
.asciiz "SET A, 1"
:output
.dat 0x0000
.dat 0x0000
.dat 0x0000
.dat 0x0000

; write_hex(value)
; Print a value as hex on a line
; [Z+1]: value to write
; [Z]: newline flag
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
    
    SET B, [Z+1] ; Load the value
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
    SHL [Z+1], 4
    
    ; Say we printed a character
    SUB C, 1
    SET PC, write_hex_do_digit
:write_hex_done

    ; Print newline
    SET PUSH, write_hex_tail ; String
    SET PUSH, [Z] ; Newline
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

; lex_line(*line)
; Lex a line and put all the tokens on the stack.
; [Z]: Pointer to null-terminated line string.
; Returns: error code
:lex_line
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Pointer into string
    SET PUSH, B ; Scratch pointer into string
    SET PUSH, C ; Return scratch
    
    ; Start at the start of the string
    SET A, [Z]
    
    ; Assume we have no error
    SET [Z], ASM_ERR_NONE
    
    ; Now scan the string
:lex_line_scan_string
    ; Catch a null-terminator
    IFE [A], 0
        SET PC, lex_line_done
    
    ; Skip spaces
:lex_line_skip_spaces
    IFN [A], 0x20 ; Space
        SET PC, lex_line_spaces_done
    ADD A, 1
    SET PC, lex_line_skip_spaces

:lex_line_spaces_done
    
    ; Catch a null-terminator
    IFE [A], 0
        SET PC, lex_line_done
    
    ; If we see a valid ID character, decide we're parsing an ID
    SET PUSH, [A]
    JSR char_valid_for_id
    SET C, POP
    IFE C, 1
        SET PC, lex_line_parse_id
        
    ; If we see a comma, that's a comma token
    IFE [A], 0x2C ; ','
        SET PC, lex_line_parse_comma
        
    ; If we see a 0x, start a hex number
    IFE [A], 0x30 ; '0'
        IFE [A+1], 0x78 ; 'x'
            SET PC, lex_line_parse_hex
    IFE [A], 0x30 ; '0'
        IFE [A+1], 0x58 ; 'X'
            SET PC, lex_line_parse_hex
    
    ; If we see a digit, start a decimal number
    IFG [A], 0x29 ; '0' - 1
        IFL [A], 0x3A ; '9' + 1
            SET PC, lex_line_parse_dec
    
    ; Otherwise, have an error
    SET [Z], ASM_ERR_LEX_BAD_TOKEN
    SET PC, lex_line_done
    
:lex_line_parse_id
    ; Remember the start
    SET B, A
    
:lex_line_parse_id_loop
    ; Scan until the next non-ID character
    SET PUSH, [A]
    JSR char_valid_for_id
    SET C, POP
    IFE C, 0
        SET PC, lex_line_parse_id_done
        
    ADD A, 1
    SET PC, lex_line_parse_id_loop
    
:lex_line_parse_id_done
    
    ; Push an ID token
    
    SET PUSH, NODE_TYPE_TOKEN_ID ; Arg 1 - type
    SET PUSH, B ; Arg 2 - string start
    SET PUSH, A ; Arg 3 - string past end
    JSR push_token
    SET C, POP
    ADD SP, 2
    
    ; If there was an error, return it
    IFN C, ASM_ERR_NONE
        SET [Z], C
    IFN C, ASM_ERR_NONE
        SET PC, lex_line_done
    
    ; Continue with the next token
    SET PC, lex_line_scan_string
    
:lex_line_parse_comma
    ; Make a token for just this character
    
    SET PUSH, NODE_TYPE_TOKEN_COMMA ; Arg 1 - type
    SET PUSH, A ; Arg 2 - string start
    ADD A, 1
    SET PUSH, A ; Arg 3 - string past end
    JSR push_token
    SET C, POP
    ADD SP, 2
    
    ; If there was an error, return it
    IFN C, ASM_ERR_NONE
        SET [Z], C
    IFN C, ASM_ERR_NONE
        SET PC, lex_line_done
    
    ; Continue with the next token. A is already in place
    SET PC, lex_line_scan_string
    
:lex_line_parse_hex
    ; Make a token for the extent of this hex number
    
    SET B, A ; Save the start of the hex number
    ADD A, 2 ; Skip the "0x"
    
:lex_line_parse_hex_loop
    SET C, 0 ; Will note if this is a valid hex character or not
    IFG [A], 0x2F ; '0' - 1
        IFL [A], 0x3A ; '9' + 1
            SET C, 1
    IFG [A], 0x40 ; 'A' - 1
        IFL [A], 0x47 ; 'F' + 1
            SET C, 1
    IFG [A], 0x60 ; 'a' - 1
        IFL [A], 0x67 ; 'f' + 1
            SET C, 1
    IFN C, 1
        ; We are not still looking at hex digits
        SET PC, lex_line_parse_hex_found_end
    ; Otherwise this is a digit, so try the next one
    ADD A, 1
    SET PC, lex_line_parse_hex_loop
:lex_line_parse_hex_found_end
    ; OK, the range from B to A is a hex number
    SET PUSH, NODE_TYPE_TOKEN_HEX ; Arg 1 - token type
    SET PUSH, B ; Arg 2 - token start
    SET PUSH, A ; Arg 3 - token past end
    JSR push_token
    SET C, POP
    ADD SP, 2
    
    ; If there was an error, return it
    IFN C, ASM_ERR_NONE
        SET [Z], C
    IFN C, ASM_ERR_NONE
        SET PC, lex_line_done
    
    ; Continue with the next token
    SET PC, lex_line_scan_string
    
:lex_line_parse_dec
    ; Make a token for the extent of this decimal number
    
    SET B, A ; Save the start of the decimal number
    
:lex_line_parse_dec_loop
    IFL [A], 0x30 ; '0'
        SET PC, lex_line_parse_dec_found_end ; Not a digit
    IFG [A], 0x39 ; '9'
        SET PC, lex_line_parse_dec_found_end ; Not a digit
    ; Otherwise this is a digit, so try the next one
    ADD A, 1
    SET PC, lex_line_parse_dec_loop
:lex_line_parse_dec_found_end
    ; OK, the range from B to A is a decimal number
    SET PUSH, NODE_TYPE_TOKEN_DEC ; Arg 1 - token type
    SET PUSH, B ; Arg 2 - token start
    SET PUSH, A ; Arg 3 - token past end
    JSR push_token
    SET C, POP
    ADD SP, 2
    
    ; If there was an error, return it
    IFN C, ASM_ERR_NONE
        SET [Z], C
    IFN C, ASM_ERR_NONE
        SET PC, lex_line_done
    
    ; Continue with the next token
    SET PC, lex_line_scan_string
:lex_line_done
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
;char_valid_for_id(char)
; Return true if the given character is valid for use in an identifier, and 
; false otherwise.
; [Z]: character value to check
; Returns: validity flag (0 or 1)
:char_valid_for_id
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A; Character register
    SET A, [Z]
    
    ; Default false
    SET [Z], 0
    
    ; Allow capitals
    IFL A, 0x5B ; 'Z'+1
        IFG A, 0x40 ; 'A'-1
            SET [Z], 1
    ; Allow lower case
    IFL A, 0x7B ; 'z'+1
        IFG A, 0x60 ; 'a'-1
            SET [Z], 1
    ; Allow underscore
    IFE A, 0x5F ; '_'
        SET [Z], 1
    ; Allow . (for local labels and directives)
    IFE A, 0x2E ; '.'
        SET [Z], 1

    SET A, POP
    SET Z, POP
    SET PC, POP

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


    SET Z, POP
    SET PC, POP

; Since we have dynamically instantiated parsing nodes we need a malloc/free

; Heap entries come one after the other and have a used flag and a length
.define HEAP_HEADER_SIZEOF, 2
.define HEAP_HEADER_USED, 0
.define HEAP_HEADER_LENGTH, 1


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
    
; push_token(type, *start, *end)
; Create a new token on top of the parser stack
; We'll make them all on this stack, then move it all to the other stack.
; [Z+2]: type of token
; [Z+1]: start of token's representative string
; [Z]: past-the-end of token's representative string
; Returns: error code
:push_token
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Pointer to malloced token
    SET PUSH, B ; Stack manipulation scratch
    
    ; Allocate a node
    SET PUSH, NODE_SIZEOF
    JSR malloc
    SET A, POP
    
    IFE A, 0x0000
        ; Couldn't malloc
        SET PC, push_token_err_memory
    
    ; Fill in the node
    SET [A+NODE_TYPE], [Z+2]
    SET [A+NODE_CHILD1], 0
    SET [A+NODE_CHILD2], 0
    SET [A+NODE_START], [Z+1]
    SET [A+NODE_END], [Z]
    
    ; Put it on the parser stack
    SET B, [parser_stack_top]
    ; Put the node on the stack
    SET [B], A
    ; And advance the stack
    ADD [parser_stack_top], 1
    
    IFE [parser_stack_top], parser_stack_start + PARSER_STACK_SIZE
        ; We overflowed our stack
        SET PC, push_token_err_stack
    ; Otherwise we succeeded
    SET [Z], ASM_ERR_NONE
    SET PC, push_token_return
    
:push_token_err_memory
    SET [Z], ASM_ERR_MEMORY
    SET PC, push_token_return
:push_token_err_stack
    SET [Z], ASM_ERR_STACK
    SET PC, push_token_return
:push_token_return
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
    
; dump_stack()
; Pop and dump everything on the parser stack
; Returns: nothing
:dump_stack
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS scratch
    SET PUSH, B ; Stack entries
    SET PUSH, C ; Nodes themselves
    SET PUSH, I ; String scratch
    
    SET B, [parser_stack_top]
    
    IFE B, parser_stack_start
        ; No entries
        SET PC, dump_stack_done
    
:dump_stack_loop
    ; Say we are printing a node
    SET PUSH, str_node
    SET PUSH, 0
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Pop a node
    SUB B, 1
    SET C, [B]
    
    ; Say all its parts
    SET PUSH, [C+NODE_TYPE]
    SET PUSH, 0
    JSR write_hex
    ADD SP, 2
    
    SET PUSH, 0x20 ; ' '
    SET PUSH, 1
    SET A, BBOS_WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, [C+NODE_CHILD1]
    SET PUSH, 0
    JSR write_hex
    ADD SP, 2
    
    SET PUSH, 0x20 ; ' '
    SET PUSH, 1
    SET A, BBOS_WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET PUSH, [C+NODE_CHILD2]
    SET PUSH, 0
    JSR write_hex
    ADD SP, 2
    
    SET PUSH, 0x20 ; ' '
    SET PUSH, 1
    SET A, BBOS_WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Now dump all the characters from start to end
    SET I, [C+NODE_START]
:dump_stack_content_loop
    ; If we hit the end of the contents, stop    
    IFE I, [C+NODE_END]
        SET PC, dump_stack_content_done
    
    ; Dump this character    
    SET PUSH, [I]
    SET PUSH, 1
    SET A, BBOS_WRITE_CHAR
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Look for the next character
    ADD I, 1
    SET PC, dump_stack_content_loop
        
:dump_stack_content_done

    ; Print the trailing string for a node (and a newline)
    SET PUSH, str_node_end
    SET PUSH, 1
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    IFN B, parser_stack_start
        ; Still more to do
        SET PC, dump_stack_loop
:dump_stack_done
    SET I, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
:str_node
.asciiz "Node: "
:str_node_end
.dat 0x0000

.define PARSER_STACK_SIZE, 100

; Put a stack for parsing.
; This holds pointers to nodes on the heap.
; The top points tot he next empty space to fill
:parser_stack_top
.dat parser_stack_start
:parser_stack_start
.reserve PARSER_STACK_SIZE

; Put another stack for the tokens not yet parsed.
; This holds pointers to nodes on the heap.
; The top points tot he next empty space to fill
:token_stack_top
.dat token_stack_start
:token_stack_start
.reserve PARSER_STACK_SIZE

; Put the heap at the end
.define HEAP_SIZE, 0x1000
; Set it up as a single entry of the whole size (which actually takes 2 more words)
:heap_start
.dat 0
.dat HEAP_SIZE



























