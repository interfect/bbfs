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
; Any of the normal 8, or SP
.define NODE_TYPE_REGISTER, 0x1000
; A value that can appear anywhere in an expression: decimal, hex, char, or identifier
.define NODE_TYPE_VALUE, 0x1001
; A sum of constants expression
.define NODE_TYPE_SUMS, 0x1002
; A sum of constants expression with a trailing operator
.define NODE_TYPE_SUMSOP, 0x1003

; TODO: implement multiplication
; A product of constants expression
.define NODE_TYPE_PRODUCTS, 0x1004
; A product of constants expression with a trailing operator
.define NODE_TYPE_PRODUCTSOP, 0x1005

; A constant expression
.define NODE_TYPE_CONSTEXP, 0x1006

; An expression involving a register (which may be a sum but not a product)
; The register might actually be SP, or it could be any of the standard 8
.define NODE_TYPE_REGEXP, 0x1007
; An expression involving a register with a trailing +/- operator
.define NODE_TYPE_REGEXPOP, 0x1008

; An expression in an open dereferencing bracket set
.define NODE_TYPE_DEREFOPEN, 0x1009
; A closed dereferencing bracket set
.define NODE_TYPE_DEREF, 0x100A

; The PC or EX registers, which can't be in expressions
.define NODE_TYPE_SPECIALREG, 0x100B

; The special PUSH operand, legal only as b (first arg)
.define NODE_TYPE_PUSH, 0x100C 
; The special POP operand, legal only as a (second arg)
.define NODE_TYPE_POP, 0x100D

; A legal arument
.define NODE_TYPE_ARG, 0x2000
; TODO: can't distinguish between A and B at this level really...

; An ID that refers to a valid basic opcode
.define NODE_TYPE_BASICOPCODE, 0x2002
; An ID that refers to a valid special opcode
.define NODE_TYPE_SPECIALOPCODE, 0x2003

; A basic opcode with it's b argument
.define NODE_TYPE_BASICANDB, 0x2004
; A special opcode, or a basic opcode with its b argument and comma
.define NODE_TYPE_AREADY, 0x2005
; An opcode of either type with all its arguments
.define NODE_TYPE_OPERATION, 0x2006

; A valid directive ID, which takes one or more arguments
.define NODE_TYPE_DIRECTIVE, 0x3000
; A directive with 0 or more arguments, comma separated. Can be a directive and
; an argument, or a directive-phrase-comma and an argument.
.define NODE_TYPE_DIRECTIVEPHRASE, 0x3001
; A directive phrase with a comma, which can take another argument
.define NODE_TYPE_DIRECTIVEPHRASECOMMA, 0x3002

; A label with its colon. The colon can be either child, and the ID will be the other
.define NODE_TYPE_LABEL, 0x4000
; A label as a left child, with an operation or directive or additional labeledphrase as the right child.
; Can also be just a single lable child.
.define NODE_TYPE_LABELEDPHRASE, 0x4002

; An operation, directive, or labeledphrase as a left child, and an optional
; comment as the right child.
.define NODE_TYPE_COMMENTEDPHRASE, 0x5000

; Operators by precedence
.define NODE_TYPE_ADDSUBOP, 0x6000
.define NODE_TYPE_MULDIVOP, 0x6001

; The maximal projection: a whole line
; Child is always a commentedphrase
.define NODE_TYPE_LINE, 0x7000

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
    ; Print the lex label
    SET PUSH, str_lexing
    SET PUSH, 1
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2

    ; Lex a line
    SET PUSH, program
    JSR lex_line
    SET B, POP ; Get the error code
    
    ; Report error if nonzero
    SET PUSH, B
    JSR report_error
    ADD SP, 1
    
    ; Move everything to the token stack
    JSR unshift_all
    
    ; Print the parse label
    SET PUSH, str_parsing
    SET PUSH, 1
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Parse everything
    SUB SP, 1
    JSR parse_stack
    SET B, POP
    
    ; Report error if nonzero
    SET PUSH, B
    JSR report_error
    ADD SP, 1
    
    JSR dump_stack

:halt
    SET PC, halt

; Strings
:str_error
.asciiz "Error: "
:str_lexing
.asciiz "Lex..."
:str_parsing
.asciiz "Parse..."

; Assembler input/output for testing
:program
.asciiz ":thing SET A, B ; Cool beanz"
:output
.dat 0x0000
.dat 0x0000
.dat 0x0000
.dat 0x0000

; report_error(value)
; Print the given error code if it is not ASM_ERR_NONE
; Returns: nothing
:report_error
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS scratch
    
    IFE [Z], ASM_ERR_NONE
        ; No error to report
        SET PC, report_error_return
    
    ; Print the error code label
    SET PUSH, str_error
    SET PUSH, 0
    SET A, BBOS_WRITE_STRING
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    ; Print the error code
    SET PUSH, [Z]
    SET PUSH, 1
    JSR write_hex
    ADD SP, 2
    
    ; Halt here if it was a bad thing
    SET PC, halt
    
:report_error_return
    SET A, POP
    SET Z, POP
    SET PC, POP
    

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

; parse_stack()
; Apply parser steps until there's an error or the parsing is done
; [Z]: caller-allocated return value
; Returns: error code
:parse_stack
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Used for peeking at the parser stack
    
:parse_stack_loop
    IFN [token_stack_top], token_stack_start
        ; If there's stuff on the token stack, keep going
        SET PC, parse_stack_keep_going
    IFN [parser_stack_top], parser_stack_start+1
        ; If there's not exactly one thing on the parser stack, keep going
        SET PC, parse_stack_keep_going

    ; We know there's just one thing.
    ; Find the entry on the stack
    SET A, [parser_stack_top]
    SUB A, 1
    ; Load the address of the heap-allocated node from the stack
    SET A, [A] 
    ; Is it a maximal projection?
    IFN [A+NODE_TYPE], NODE_TYPE_LINE
        ; If it's not, keep going
        SET PC, parse_stack_keep_going
        
    ; Otherwise, we must be done!
    SET [Z], ASM_ERR_NONE
    SET PC, parse_stack_done

:parse_stack_keep_going
    ; We still want to parse. Parse for a step
    SUB SP, 1
    JSR parse_step
    SET [Z], POP
    
    IFE [Z], ASM_ERR_NONE
        ; If nothing bad happened, see if we should do another step
        SET PC, parse_stack_loop
    ; If we had an error, return it

:parse_stack_done
    ; No more parsing can happen
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
; Register names are reserved and can't be labels or other things
.dat 0, 0, NODE_TYPE_TOKEN_ID, filter_is_register, 0, NODE_TYPE_REGISTER, 0
; We also reserve the names of opcodes
.dat 0, 0, NODE_TYPE_TOKEN_ID, filter_is_basic_opcode, 0, NODE_TYPE_BASICOPCODE, 0
.dat 0, 0, NODE_TYPE_TOKEN_ID, filter_is_special_opcode, 0, NODE_TYPE_SPECIALOPCODE, 0
; Otherwise, if we see a colon and an identifier, that's a label
.dat NODE_TYPE_TOKEN_COLON, 0, NODE_TYPE_TOKEN_ID, 0, 0, NODE_TYPE_LABEL, 0
; In either order
.dat NODE_TYPE_TOKEN_ID, 0, NODE_TYPE_TOKEN_COLON, 0, 0, NODE_TYPE_LABEL, 0
; Registers immediately become regexps
.dat 0, 0, NODE_TYPE_REGISTER, 0, 0, NODE_TYPE_REGEXP, 0
; Regexps with operators after them pull in the operators
.dat 0, 0, NODE_TYPE_REGEXP, 0, NODE_TYPE_TOKEN_PLUS, 0, 1
.dat 0, 0, NODE_TYPE_REGEXP, 0, NODE_TYPE_TOKEN_MINUS, 0, 1
; Operators immediately become nodes by precedence
.dat 0, 0, NODE_TYPE_TOKEN_PLUS, 0, 0, NODE_TYPE_ADDSUBOP, 0
.dat 0, 0, NODE_TYPE_TOKEN_MINUS, 0, 0, NODE_TYPE_ADDSUBOP, 0
; Regexps become arguments if they can't do anything else
.dat 0, 0, NODE_TYPE_REGEXP, 0, 0, NODE_TYPE_ARG, 0
; Opcodes grab arguments
; Basic opcode gets first arg
.dat NODE_TYPE_BASICOPCODE, 0, NODE_TYPE_ARG, 0, 0, NODE_TYPE_BASICANDB, 0
; Then it wants a comma
.dat 0, 0, NODE_TYPE_BASICANDB, 0, NODE_TYPE_TOKEN_COMMA, 0, 1
; Then a comma makes it ready for a
.dat NODE_TYPE_BASICANDB, 0, NODE_TYPE_TOKEN_COMMA, 0, 0, NODE_TYPE_AREADY, 0
; Or a special opcode just is ready for a
.dat 0, 0, NODE_TYPE_SPECIALOPCODE, 0, 0, NODE_TYPE_AREADY, 0
; Then something that needs a gets a
.dat NODE_TYPE_AREADY, 0, NODE_TYPE_ARG, 0, 0, NODE_TYPE_OPERATION, 0
; A label and an operation make a labeled phrase
.dat NODE_TYPE_LABEL, 0, NODE_TYPE_OPERATION, 0, 0, NODE_TYPE_LABELEDPHRASE, 0
; A labeled phrase pulls in a comment
.dat 0, 0, NODE_TYPE_LABELEDPHRASE, 0, NODE_TYPE_TOKEN_COMMENT, 0, 1
; A labeled phrase and a comment make a commented phrase
.dat NODE_TYPE_LABELEDPHRASE, 0, NODE_TYPE_TOKEN_COMMENT, 0, 0, NODE_TYPE_COMMENTEDPHRASE, 0
; If there's nothing else to do, shift in an ID
.dat 0, 0, 0, 0, NODE_TYPE_TOKEN_ID, 0, 1
; If there's nothing else to do, a line could start with a colon
.dat 0, 0, 0, 0, NODE_TYPE_TOKEN_COLON, 0, 1
; If there's nothing else to do, a line could even start with a comment
.dat 0, 0, 0, 0, NODE_TYPE_TOKEN_COMMENT, 0, 1
; If there's nothing else to do, pull in add operators
.dat 0, 0, 0, 0, NODE_TYPE_TOKEN_PLUS, 0, 1
; If there's nothing else to do, pull in sub operators
.dat 0, 0, 0, 0, NODE_TYPE_TOKEN_MINUS, 0, 1
; If there's nothing else to do, pull in open brackets
.dat 0, 0, 0, 0, NODE_TYPE_TOKEN_OPENBRACKET, 0, 1
; If there's nothing else to do, pull in close brackets
.dat 0, 0, 0, 0, NODE_TYPE_TOKEN_CLOSEBRACKET, 0, 1
; A commented phrase can become a whole line
.dat 0, 0, NODE_TYPE_COMMENTEDPHRASE, 0, 0, NODE_TYPE_LINE, 0
; Terminate the table
.dat 0, 0, 0, 0, 0, 0, 0

; filter_is_register(*token)
; Decide if an ID token is a register name or not.
; Special registers (PC, EX) don't count, but SP does because it has all the
; indexing modes available.
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
    
    IFE B, 2
        ; Only one 2-letter normal-ish register exists
        SET PC, filter_is_register_check_sp
    
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
    SET PC, filter_is_register_done
    
:filter_is_register_check_sp
    ; Is this ther only 2-letter normal register, SP?
    
    ; Compare the strings
    SET PUSH, [A+NODE_START]
    SET PUSH, str_sp
    JSR strcasecmp
    SET B, POP
    ADD SP, 1
    
    ; If they're not equal, this isn;t a register.
    IFN B, 0
        SET [Z], 0
    
:filter_is_register_done
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; filter_is_basic_opcode(*token)
; Return true if the given ID token matches a known basic opcode
; [Z]: token node pointer
; Returns: 1 if ID is a valid basic opcode, 0 otherwise
:filter_is_basic_opcode
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Node pointer
    SET PUSH, B ; Node string
    
    ; Grab the node
    SET A, [Z]
    
    ; Set the return code for an error
    SET [Z], 0
    
    ; Copy the string of the node to a null-terminated buffer
    SET PUSH, A
    JSR node_to_string
    SET B, POP
    
    IFE B, 0x0000
        ; TODO: handle error
        SET PC, filter_is_basic_opcode_done
    
    ; Get the opcode value
    SET PUSH, opcode_table_basic
    SET PUSH, B
    JSR lookup_string
    SET [Z], POP
    ADD SP, 1
    
    ; Free the buffer
    SET PUSH, B
    JSR free
    ADD SP, 1
    
    ; If the value is nonzero, return true
    IFG [Z], 0
        SET Z, 1
    ; Otherwise, leave it as 0 (not found = not an opcode)
:filter_is_basic_opcode_done
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; filter_is_special_opcode(*token)
; Return true if the given ID token matches a known special opcode
; [Z]: token node pointer
; Returns: 1 if ID is a valid special opcode, 0 otherwise
:filter_is_special_opcode
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Node pointer
    SET PUSH, B ; Node string
    
    ; Grab the node
    SET A, [Z]
    
    ; Set the return code for an error
    SET [Z], 0
    
    ; Copy the string of the node to a null-terminated buffer
    SET PUSH, A
    JSR node_to_string
    SET B, POP
    
    IFE B, 0x0000
        ; TODO: handle error
        SET PC, filter_is_special_opcode_done
    
    ; Get the opcode value
    SET PUSH, opcode_table_special
    SET PUSH, B
    JSR lookup_string
    SET [Z], POP
    ADD SP, 1
    
    ; Free the buffer
    SET PUSH, B
    JSR free
    ADD SP, 1
    
    ; If the value is nonzero, return true
    IFG [Z], 0
        SET Z, 1
    ; Otherwise, leave it as 0 (not found = not an opcode)
:filter_is_special_opcode_done
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; node_to_string(*node)
; Allocate a new string with the contents of the given node. Caller must free it.
; [Z]: node pointer
; Returns: string address, or null if it could not be allocated
:node_to_string
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Node pointer
    SET PUSH, B ; Node string length, node string end
    SET PUSH, I ; Original string pointer
    SET PUSH, J ; New string pointer
    
    ; Grab the node
    SET A, [Z]
    
    ; Calculate string length with null terminator
    SET B, [A+NODE_END]
    SUB B, [A+NODE_START]
    ADD B, 1
    
    ; Allocate new string
    SET PUSH, B
    JSR malloc
    SET J, POP
    
    ; Whatever this is, we return it
    SET [Z], J
    
    IFE J, 0x0000
        ; Nothing got allocated so don't copy
        SET PC, node_to_string_done
        
    ; Start copying from the start of the string, and continue until the end
    SET I, [A+NODE_START]
    SET B, [A+NODE_END]
    
:node_to_string_loop
    IFE I, B
        ; Hit the end
        SET PC, node_to_string_done
    ; Copy a character to the new string
    STI [J], [I]
    SET PC, node_to_string_loop
:node_to_string_done
    SET J, POP
    SET I, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; lookup_string(*table, *str):
; Get the table value for the given null-terminated string, or 0
; if it is not an entry in the given table.
; Uses a null-tertminated table of string pointers and values.
; [Z+1]: table address
; [Z]: string key
; Returns: table value, or 0 if string is not in the table
:lookup_string
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; table row pointer
    SET PUSH, B ; Return value scratch
    SET PUSH, C ; String we're looking up
    
    ; Save our string
    SET C, [Z]
    ; Say we haven't found it
    SET [Z], 0
    
    SET A, [Z+1] ; Start with first row of the table
:lookup_string_loop
    IFE [A], 0
        ; Null terminator
        SET PC, lookup_string_done
    
    ; Compare the string we're looking for against this table entry
    SET PUSH, [A]
    SET PUSH, C
    JSR strcasecmp
    SET B, POP
    ADD SP, 1
    
    IFE B, 0
        ; The string was found
        SET [Z], [A+1]
    IFE B, 0
        SET PC, lookup_string_done
        
    ; Try the next entry
    ADD A, 2
    SET PC, lookup_string_loop
    
:lookup_string_done
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
    
; strcasecmp(*str1, *str2):
; Case-insensitively compare the two strings, at least one of which must be
; null-terminated. Note that a terminated string never equals an unterminated
; string.
; [Z+1]: string 1
; [Z]: string 2
; Returns: -1 if str1 < str2, 0 if they are equal, and 1 if str2 < str1
:strcasecmp
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Case scratch
    SET PUSH, B ; Case scratch in other string
    SET PUSH, I ; String 1 pointer
    SET PUSH, J ; String 2 pointer
    
    ; Load the string pointers
    SET I, [Z+1]
    SET J, [Z]
    
    ; Assume strings are equal
    SET [Z], 0
    
:strcasecmp_loop
    SET A, [I]
    SET B, [J]
    
    ; Upper-case str1 character
    IFG A, 0x60 ; 'A' - 1
        IFL A, 0x7B ; 'Z' + 1
            SUB A, 0x20
            
    ; Upper-case str2 character
    IFG B, 0x60 ; 'A' - 1
        IFL B, 0x7B ; 'Z' + 1
            SUB B, 0x20

    IFL A, B
        ; String 1 smaller
        SET [Z], 0xFFFF
    IFL B, A
        ; String 2 smaller
        SET [Z], 1
        
    ; Stop if either is 0
    IFE [I], 0
        SET PC, strcasecmp_done
    IFE [J], 0
        SET PC, strcasecmp_done
    
    ; Look at the next character
    ADD I, 1
    ADD J, 1
    
    IFE [Z], 0
        ; Keep going as long as it's indeterminate which string wins
        SET PC, strcasecmp_loop
    
:strcasecmp_done
    SET J, POP
    SET I, POP
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
    
; We have a big bunch of string constants for all the string bits we need to
; parse
; Register names
:str_a
.asciiz "A"
:str_b
.asciiz "B"
:str_c
.asciiz "C"
:str_x
.asciiz "X"
:str_y
.asciiz "Y"
:str_z
.asciiz "Z"
:str_i
.asciiz "I"
:str_j
.asciiz "J"
:str_sp
.asciiz "SP"
:str_pc
.asciiz "PC"
:str_ex
.asciiz "EX"
; Push and pop
:str_push
.asciiz "PUSH"
:str_pop
.asciiz "POP"

; Basic opcode names
:str_set
.asciiz "SET"
:str_add
.asciiz "ADD"
:str_sub
.asciiz "SUB"
:str_mul
.asciiz "MUL"
:str_mli
.asciiz "MLI"
:str_div
.asciiz "DIV"
:str_dvi
.asciiz "DVI"
:str_mod
.asciiz "MOD"
:str_mdi
.asciiz "MDI"
:str_and
.asciiz "AND"
:str_bor
.asciiz "BOR"
:str_xor
.asciiz "XOR"
:str_shr
.asciiz "SHR"
:str_asr
.asciiz "ASR"
:str_shl
.asciiz "SHL"
:str_ifb
.asciiz "IFB"
:str_ifc
.asciiz "IFC"
:str_ife
.asciiz "IFE"
:str_ifn
.asciiz "IFN"
:str_ifg
.asciiz "IFG"
:str_ifa
.asciiz "IFA"
:str_ifl
.asciiz "IFL"
:str_ifu
.asciiz "IFU"
:str_adx
.asciiz "ADX"
:str_sbx
.asciiz "SBX"
:str_sti
.asciiz "STI"
:str_std
.asciiz "STD"

; Special opcode names
:str_jsr
.asciiz "JSR"
:str_int
.asciiz "INT"
:str_iag
.asciiz "IAG"
:str_ias
.asciiz "IAS"
:str_rfi
.asciiz "RFI"
:str_iaq
.asciiz "IAQ"
:str_hwn
.asciiz "HWN"
:str_hwq
.asciiz "HWQ"
:str_hwi
.asciiz "HWI"

; Now we have null-terminated string, code tables for basic and special opcodes

:opcode_table_basic
.dat str_set, 0x01
.dat str_add, 0x02
.dat str_sub, 0x03
.dat str_mul, 0x04
.dat str_mli, 0x05
.dat str_div, 0x06
.dat str_dvi, 0x07
.dat str_mod, 0x08
.dat str_mdi, 0x09
.dat str_and, 0x0A
.dat str_bor, 0x0B
.dat str_xor, 0x0C
.dat str_shr, 0x0D
.dat str_asr, 0x0E
.dat str_shl, 0x0F
.dat str_ifb, 0x10
.dat str_ifc, 0x11
.dat str_ife, 0x12
.dat str_ifn, 0x13
.dat str_ifg, 0x14
.dat str_ifa, 0x15
.dat str_ifl, 0x16
.dat str_ifu, 0x17
.dat str_adx, 0x1A
.dat str_sbx, 0x1B
.dat str_sti, 0x1E
.dat str_std, 0x1F
.dat 0, 0

:opcode_table_special
.dat str_jsr, 0x01
.dat str_int, 0x08
.dat str_iag, 0x09
.dat str_ias, 0x0A
.dat str_rfi, 0x0B
.dat str_iaq, 0x0C
.dat str_hwn, 0x10
.dat str_hwq, 0x11
.dat str_hwi, 0x12
.dat 0, 0

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



























