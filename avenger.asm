;   __   _  _  ____  __ _   ___  ____  ____             
;  / _\ / )( \(  __)(  ( \ / __)(  __)(  _ \            
; /    \\ \/ / ) _) /    /( (_ \ ) _)  )   /            
; \_/\_/ \__/ (____)\_)__) \___/(____)(__\_)            
;   __   ____  ____  ____  _  _  ____  __    ____  ____ 
;  / _\ / ___)/ ___)(  __)( \/ )(  _ \(  )  (  __)/ ___)
; /    \\___ \\___ \ ) _) / \/ \ ) _ (/ (_/\ ) _) \___ \
; \_/\_/(____/(____/(____)\_)(_/(____/\____/(____)(____/
;
; AVENGER: A self-hosting assembler for DCPU-16

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
; | Child 2 (or null) (always null if child1 is null)
; +---------------------
; | String start
; +---------------------
; | String end
; +---------------------
;
; Nodes with only one child have itas child 1, with child 2 null

.define NODE_SIZEOF, 5
.define NODE_TYPE, 0
.define NODE_CHILD1, 1
.define NODE_CHILD2, 2
.define NODE_START, 3
.define NODE_END, 4

; For the parsing step, we have a table of parsing rules which are executed in
; order. Each parsing rule looks like this:
;
; +--------------------
; | Left child type required (if two children are required) or null
; +--------------------
; | Hook (returning true or false) to check left child
; +--------------------
; | Right child type required (if any node is to be created)
; +--------------------
; | Hook (returning true or false) to check right child
; +--------------------
; | Type that next token must match (or null)
; +--------------------
; | Type of new node to reduce from the left and right children (or null)
; +--------------------
; | Flag for whether to shift in the next token after any reduce
; +--------------------
;
; Note that rules with only a child 2 will create nodes with only a child *1*.

.define RULE_SIZEOF, 7
.define RULE_CHILD1, 0
.define RULE_FILTER1, 1
.define RULE_CHILD2, 2
.define RULE_FILTER2, 3
.define RULE_TOKEN, 4
.define RULE_REDUCE, 5
.define RULE_SHIFT, 6

; Here are the node types

; Node type 0 is reserved as a null marker
.define NODE_TYPE_NULL, 0x0000

; Tokens for bottom level lexemes (tokens)

; Identifier, which can be a register name, label name, constant name, or
; instruction
.define NODE_TYPE_TOKEN_ID, 0x0001
; Hexadecimal number
.define NODE_TYPE_TOKEN_HEX, 0x0002
; Decimal number
.define NODE_TYPE_TOKEN_DEC, 0x0003
; String constant ""
.define NODE_TYPE_TOKEN_STRING, 0x0004
; Char constant ''
.define NODE_TYPE_TOKEN_CHAR, 0x0005
; Comment
.define NODE_TYPE_TOKEN_COMMENT, 0x0006
; Comma character, for separating arguments
.define NODE_TYPE_TOKEN_COMMA, 0x0007
; Colon character, for creating labels
.define NODE_TYPE_TOKEN_COLON, 0x0008
; Open bracket, for starting dereferences
.define NODE_TYPE_TOKEN_OPENBRACKET, 0x0009
; Close bracket, for ending dereferences
.define NODE_TYPE_TOKEN_CLOSEBRACKET, 0x000A
; Addition operator
.define NODE_TYPE_TOKEN_PLUS, 0x000B
; Subtraction operator
.define NODE_TYPE_TOKEN_MINUS, 0x000C

; Higher-level syntax tree nodes

; A register identifier
.define NODE_TYPE_REGISTER, 0x1000

; And some error codes
.define ASM_ERR_NONE, 0x0000
.define ASM_ERR_LEX_BAD_TOKEN, 0x0001 ; Found something that's not a real token
.define ASM_ERR_MEMORY, 0x0002 ; Ran out of heap space for syntax tree nodes
.define ASM_ERR_STACK, 0x0003 ; Ran out of space on the parsing stack(s)
.define ASM_ERR_UNTERMINATED, 0x0004 ; Unterminated string or char literal
.define ASM_ERR_SYNTAX, 0x0005 ; Syntax error: no rule found to apply


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
    
     ; Print the lex label
    SET PUSH, str_lexed
    SET PUSH, 1
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
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
    
    ; Dump the parser stack
    JSR dump_stack
    
    ; Move everything to the token stack
    JSR unshift_all
    
    ; Parse everything
    ADD SP, 1
    JSR parse_step
    SET B, POP
    
     ; Print the parse label
    SET PUSH, str_parsed
    SET PUSH, 1
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
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
    
    ; Dump the parser stack again
    JSR dump_stack
    
    ; Parse everything again
    ADD SP, 1
    JSR parse_step
    SET B, POP
    
     ; Print the parse label
    SET PUSH, str_parsed
    SET PUSH, 1
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
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
    
    ; Dump the parser stack again
    JSR dump_stack

:halt
    SET PC, halt

; Strings
:str_error
.asciiz "Error: "
:str_lexed
.asciiz "Lex:"
:str_parsed
.asciiz "Parse:"

; Assembler input/output for testing
:program
.asciiz "A"
;.asciiz ":thing SET A, '1' ; Cool beans"
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
    SET PUSH, C ; Return scratch and scratch for each parsing case
    
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
        
    ; If we see a 0x, start a hex number
    IFE [A], 0x30 ; '0'
        IFE [A+1], 0x78 ; 'x'
            SET PC, lex_line_parse_hex
    IFE [A], 0x30 ; '0'
        IFE [A+1], 0x58 ; 'X'
            SET PC, lex_line_parse_hex
    
    ; If we see a digit, start a decimal number
    IFG [A], 0x2F ; '0' - 1
        IFL [A], 0x3A ; '9' + 1
            SET PC, lex_line_parse_dec
            
    ; If we see a quote, parse a string
    IFE [A], 0x22 ; '"'
        SET PC, lex_line_parse_string
        
    ; If we see a single quote, parse a char
    IFE [A], 0x27 ; '\''
        SET PC, lex_line_parse_char
        
    ; If we see a semicolon, parse a comment
    IFE [A], 0x3B ; ';'
        SET PC, lex_line_parse_comment
        
    ; Try a bunch of single-character tokens
    IFE [A], 0x2C ; ','
        SET PC, lex_line_parse_comma
    IFE [A], 0x3A ; ':'
        SET PC, lex_line_parse_colon
    IFE [A], 0x5B ; '['
        SET PC, lex_line_parse_openbracket
    IFE [A], 0x5D ; ']'
        SET PC, lex_line_parse_closebracket
    IFE [A], 0x2B ; '+'
        SET PC, lex_line_parse_plus
    IFE [A], 0x2D ; '-'
        SET PC, lex_line_parse_minus
    
    ; Otherwise, have an error
    SET [Z], ASM_ERR_LEX_BAD_TOKEN
    SET PC, lex_line_done
    
:lex_line_parse_id
    ; Parse an identifier (const name, register name, instruction name, etc.)
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
    SET PC, lex_line_push_and_finish
    
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
    SET PC, lex_line_push_and_finish
    
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
    SET PC, lex_line_push_and_finish
    
:lex_line_parse_string
    ; Parse a string, correctly skipping escaped quotes
    SET B, A ; Save the start
    ADD A, 1 ; Look after the open quote
    SET C, 0 ; Here we use C for tracking escapes
:lex_line_parse_string_loop
    IFE C, 0
        IFE [A], 0x22 ; '"'
            ; We found an unescaped quote, so finish the constant
            SET PC, lex_line_parse_string_done
    SET C, 0 ; Go back to unescaped
    IFE [A], 0x5C ; '\\'
        SET C, 1 ; Turn on escape
    IFE [A], 0
        ; We hit the line-ending null without a close quote
        SET PC, lex_line_err_unterminated
    ADD A, 1 ; Look at the next character
    SET PC, lex_line_parse_string_loop
:lex_line_parse_string_done
    ADD A, 1 ; Include the close quote
    SET PUSH, NODE_TYPE_TOKEN_STRING ; Arg 1 - token type
    SET PUSH, B ; Arg 2 - token start
    SET PUSH, A ; Arg 3 - token past end
    SET PC, lex_line_push_and_finish
    
:lex_line_parse_char
    ; Parse a char, correctly skipping escaped quotes
    SET B, A ; Save the start
    ADD A, 1 ; Look after the open quote
    SET C, 0 ; Here we use C for tracking escapes
:lex_line_parse_char_loop
    IFE C, 0
        IFE [A], 0x27 ; '\''
            ; We found an unescaped quote, so finish the constant
            SET PC, lex_line_parse_char_done
    SET C, 0 ; Go back to unescaped
    IFE [A], 0x5C ; '\\'
        SET C, 1 ; Turn on escape
    IFE [A], 0
        ; We hit the line-ending null without a close quote
        SET PC, lex_line_err_unterminated
    ADD A, 1 ; Look at the next character
    SET PC, lex_line_parse_char_loop
:lex_line_parse_char_done
    ADD A, 1 ; Include the close quote
    SET PUSH, NODE_TYPE_TOKEN_CHAR ; Arg 1 - token type
    SET PUSH, B ; Arg 2 - token start
    SET PUSH, A ; Arg 3 - token past end
    SET PC, lex_line_push_and_finish
    
:lex_line_parse_comment
    ; Handle a comment to the trailing null
    SET B, A ; Save the start
:lex_line_parse_comment_loop
    ; Until we find the null at the end of the line
    IFE [A], 0
        SET PC, lex_line_parse_comment_done
    ADD A, 1 ; Look at the next character
    SET PC, lex_line_parse_comment_loop
:lex_line_parse_comment_done
    SET PUSH, NODE_TYPE_TOKEN_COMMENT ; Arg 1 - token type
    SET PUSH, B ; Arg 2 - token start
    SET PUSH, A ; Arg 3 - token past end
    SET PC, lex_line_push_and_finish
    
    ; Here are all the single character tokens
:lex_line_parse_comma
    SET PUSH, NODE_TYPE_TOKEN_COMMA ; Arg 1 - type
    SET PC, lex_line_single_char_token
:lex_line_parse_colon
    SET PUSH, NODE_TYPE_TOKEN_COLON ; Arg 1 - type
    SET PC, lex_line_single_char_token
:lex_line_parse_openbracket
    SET PUSH, NODE_TYPE_TOKEN_OPENBRACKET ; Arg 1 - type
    SET PC, lex_line_single_char_token
:lex_line_parse_closebracket
    SET PUSH, NODE_TYPE_TOKEN_CLOSEBRACKET ; Arg 1 - type
    SET PC, lex_line_single_char_token
:lex_line_parse_plus
    SET PUSH, NODE_TYPE_TOKEN_PLUS ; Arg 1 - type
    SET PC, lex_line_single_char_token
:lex_line_parse_minus
    SET PUSH, NODE_TYPE_TOKEN_MINUS ; Arg 1 - type
    SET PC, lex_line_single_char_token
    
:lex_line_single_char_token
    ; All the single character tokens finish the same way
    SET PUSH, A ; Arg 2 - string start
    ADD A, 1
    SET PUSH, A ; Arg 3 - string past end
    SET PC, lex_line_push_and_finish
    
:lex_line_push_and_finish
    ; We already put the arguments for the token push on the stack.
    ; Push them, handle any error, and parse the next token
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

:lex_line_err_unterminated
    ; We had a run-on string
    SET [Z], ASM_ERR_UNTERMINATED
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

; parse_step()
; Apply a parser rule to the parser and token stacks if one can be found.
; [Z]: caller-allocated return space
; Returns: error code
:parse_step
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Rule pointer
    SET PUSH, B ; Parser stack top pointer
    SET PUSH, C ; Token stack top pointer
    SET PUSH, X ; Parser stack node, or child node
    SET PUSH, Y ; Token stack node
    SET PUSH, I ; Return value scratch, newly allocated node
    
    ; Get the address of the next unused slot in the parser stack
    SET B, [parser_stack_top]
    
    ; And the next unused slot in the token stack
    SET C, [token_stack_top]
    
    ; Scan the rules table, looking for the first matching rule to apply
    SET A, parser_rules
:parse_step_rule_loop
    ; If there's a rule that says don't do anything, we assume it's the all-null rule.
    IFE [A+RULE_SHIFT], 0
        IFE [A+RULE_REDUCE], 0
            SET PC, parse_step_rule_end
            
    IFE [A+RULE_CHILD1], 0
        ; Don't check the first child if one isn't used
        SET PC, parse_step_child1_ok
        
    ; Find the next-to-top item on the parser stack
    SET X, B
    SUB X, 2
    IFL X, parser_stack_start
        ; We need a next-to-top item for this rule and there isn't one
        SET PC, parse_step_rule_next
    SET X, [X] ; Dereference and get node's address
    IFN [X+NODE_TYPE], [A+RULE_CHILD1]
        ; This node isn't the right type for this rule
        SET PC, parse_step_rule_next
        
    IFE [A+RULE_FILTER1], 0
        ; No function to filter the first child, so just take it
        SET PC, parse_step_child1_ok
        
    ; Call the filter function on the node address
    SET PUSH, X
    JSR [A+RULE_FILTER1]
    SET I, POP
    
    IFE I, 0
        ; This child didn't validate for this rule
        SET PC, parse_step_rule_next
    ; Otherwise, fall through to the child 1 valid case
        
:parse_step_child1_ok
    ; We know child 1 is OK or not used. Check child 2
    
    IFE [A+RULE_CHILD2], 0
        ; Don't check the second/only child if one isn't used
        SET PC, parse_step_child2_ok
        
    ; Find the top item on the parser stack
    SET X, B
    SUB X, 1
    IFL X, parser_stack_start
        ; We need a top item for this rule and there isn't one
        SET PC, parse_step_rule_next
    SET X, [X] ; Dereference and get node's address
    IFN [X+NODE_TYPE], [A+RULE_CHILD2]
        ; This node isn't the right type for this rule
        SET PC, parse_step_rule_next
        
    IFE [A+RULE_FILTER2], 0
        ; No function to filter the first child, so just take it
        SET PC, parse_step_child2_ok
        
    ; Call the filter function on the node address
    SET PUSH, X
    JSR [A+RULE_FILTER2]
    SET I, POP
    
    IFE I, 0
        ; This child didn't validate for this rule
        SET PC, parse_step_rule_next
    ; Otherwise, fall through to the child 2 valid case
    
:parse_step_child2_ok
    ; We know child2 is also OK or not used. Check the incoming token.
    
    IFE [A+RULE_TOKEN], 0
        ; Don't check the next token if one isn't used
        SET PC, parse_step_token_ok
    
    SET Y, C
    SUB Y, 1
    IFL Y, token_stack_start
        ; We need a next token for this rule and there isn't one
        SET PC, parse_step_rule_next
    SET Y, [Y] ; Dereference and get node's address
    IFN [Y+NODE_TYPE], [A+RULE_TOKEN]
        ; This token isn't the right type for this rule
        SET PC, parse_step_rule_next
        
    ; Tokens don't have filter functions, so matching the type is enough
    
:parse_step_token_ok
    ; We know the token is also OK or not used.
    ; That means we need to apply this rule!
    ; First, see if we need to reduce
    IFE [A+RULE_REDUCE], 0
        ; No reduce needed. Maybe we need to shift?
        SET PC, parse_step_try_shift 
    
    ; We definitely need to reduce
    
    ; Allocate a new node
    SET PUSH, NODE_SIZEOF
    JSR malloc
    SET I, POP
    
    IFE I, 0x0000
        ; Out of memory
        SET PC, parse_step_err_memory
        
    ; Zero out right child, which might not get filled
    SET [I+NODE_CHILD2], 0
    
    ; Set its type to the type we project
    SET [I+NODE_TYPE], [A+RULE_REDUCE]
    
    IFE [A+RULE_CHILD1], 0
        ; No second child needed
        SET PC, parse_step_single_child
    ; Pop a right child from the top of the parser stack
    SUB B, 1
    SET [I+NODE_CHILD2], [B]
:parse_step_single_child ; If the rule has only one child, make it the left child
    ; Pop a left child from the top of the parser stack
    SUB B, 1
    SET [I+NODE_CHILD1], [B]
    
    ; Push the node to the stack
    SET [B], I
    ADD B, 1
    
    ; Update the stack top in memory
    SET [parser_stack_top], B
    
    ; Propagate up the string bounds from the children
    ; We always start where the left child starts
    SET X, [I+NODE_CHILD1]
    SET [I+NODE_START], [X+NODE_START]
    SET [I+NODE_END], [X+NODE_END]
    SET X, [I+NODE_CHILD2]
    IFN X, 0
        ; We have a right child, so end where it ends instead
        SET [I+NODE_END], [X+NODE_END]
    
    ; Then fall through to considering a shift
    
:parse_step_try_shift
    ; Maybe we need to shift a token in
    
    IFE [A+RULE_SHIFT], 0
        ; No shift needed. So rule is applied!
        SET PC, parse_step_rule_applied
    
    ; Knock the node off the token stack
    SUB C, 1
    ; Copy the value
    SET [B], [C]
    ; Update the next location on the parser stack
    ADD B, 1
    
    ; Commit stack changes
    SET [parser_stack_top], B
    SET [token_stack_top], C
    
    ; Shift accomplished!
    SET PC, parse_step_rule_applied
    
:parse_step_rule_next
    ; Try the next rule
    ADD A, RULE_SIZEOF
    SET PC, parse_step_rule_loop

:parse_step_rule_applied
    ; We have successfully applied a rule
    SET [Z], ASM_ERR_NONE
    SET PC, parse_step_return

:parse_step_rule_end
    ; We ran out of rules! That's an error
    SET [Z], ASM_ERR_SYNTAX
    SET PC, parse_step_return
:parse_step_err_memory
    ; We ran out of memory on our heap
    SET [Z], ASM_ERR_MEMORY
    SET PC, parse_step_return
:parse_step_return
    SET I, POP
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; Here are our parser rules, in a null-row-terminated table
:parser_rules
; Structure:
; Child 1 type, Child 1 filter, Child 2 type, Child 2 filter, Next token type, Reduce type, shift flag
; If we see an identifier that can be a register, we should reduce it to a register
.dat 0, 0, NODE_TYPE_TOKEN_ID, filter_is_register, 0, NODE_TYPE_REGISTER, 0
; If there's nothing else to do, shift in an ID
.dat 0, 0, 0, 0, NODE_TYPE_TOKEN_ID, 0, 1
; Terminate the table
.dat 0, 0, 0, 0, 0, 0, 0

; filter_is_register(*token)
; Decide if an ID token is a register name or not.
; Special registers (PC, SP) don't count
; [Z]: address of the ID token node
; Returns: 1 if it is a register name, 0 otherwise
; Set up frame pointer
:filter_is_register
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Node address
    SET PUSH, B ; Length scratch, char value
    SET A, [Z]

    ; Assume it is a register
    SET [Z], 1
    
    ; Get the length of the identifier
    SET B, [A+NODE_END]
    SUB B, [A+NODE_START]
    
    IFN B, 1
        ; If it's not a single letter it can't be a register
        SET [Z], 0
        
    ; Grab the character
    SET B, [A+NODE_START]
    SET B, [B]
    
    ; Convert to upper case
    IFG B, 0x5F
        SUB B, 0x20
        
    IFG B, 0x40 ; 'A' - 1
        IFL B, 0x44 ; 'C' + 1
            ; Can be a register (A, B, C)
            SET PC, filter_is_register_done
            
    IFG B, 0x57 ; 'X' - 1
        IFL B, 0x5B ; 'Z' + 1
            ; Can be a register (X, Y, Z)
            SET PC, filter_is_register_done
            
    IFG B, 0x48 ; 'I' - 1
        IFL B, 0x4B ; 'J' + 1
            ; Can be a register (I, J)
            SET PC, filter_is_register_done
            
    ; If we aren't a string starting with any of those letters, we can't be a
    ; register even if we are the right length.
    SET [Z], 0
    
:filter_is_register_done
    SET B, POP
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

; unshift_all()
; The lexer drops all the tokens on the parse stack in order. This shifts them
; back to the token stack, so they can be gone through left to right by the
; parser.
; Returns: nothing
:unshift_all
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Parser stack top address
    SET PUSH, B ; Token stack top address
    
    SET A, [parser_stack_top]
    SET B, [token_stack_top]
:unshift_all_loop
    ; Stop when we hit the bottom of the parser stack
    IFE A, parser_stack_start
        SET PC, unshift_all_done
    
    ; TODO: check for token stack overflow. Should never happen if we clear it
    ; out for each line.
    
    ; Move the item
    SUB A, 1
    SET [B], [A]
    ADD B, 1
    
    ; Check the next item
    SET PC, unshift_all_loop    
:unshift_all_done
    ; Commit the stack changes
    SET [parser_stack_top], A
    SET [token_stack_top], B

    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

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



























