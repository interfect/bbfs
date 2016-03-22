; bbfs_directories.asm
; Implementation of directories as files pointing to sectors.

; bbfs_directory_create(*directory, *header, drive_num)
; Make a new directory.
; [Z+2]: BBFS_DIRECTORY handle
; [Z+1]: BBFS_HEADER
; [Z]: drive number
; Returns: error code in [Z]
bbfs_directory_create:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Addressing scratch
    SET PUSH, B ; BBFS_FILE for the directory
    SET PUSH, C ; BBFS_DIRHEADER we set up to write in.
    
    ; Set B to the BBFS_FILE for the directory
    SET B, [Z+2]
    ADD B, BBFS_DIRECTORY_FILE
    
    ; Set C to a BBFS_DIRHEADER on the stack
    SUB SP, BBFS_DIRHEADER_SIZEOF
    SET C, SP
    
    ; Make the file
    SET PUSH, B ; Arg 1: file
    SET PUSH, [Z+1] ; Arg 2: FS header
    SET PUSH, [Z] ; Arg 3: drive number
    JSR bbfs_file_create
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        ; Report an error
        SET PC, .error_A
        
    ; Set up an empty BBFS_DIRHEADER
    SET [C+BBFS_DIRHEADER_VERSION], BBFS_VERSION
    SET [C+BBFS_DIRHEADER_CHILD_COUNT], 0
    
    ; Save it to the file
    SET PUSH, B ; Arg 1: file
    SET PUSH, C ; Arg 2: data
    SET PUSH, BBFS_DIRHEADER_SIZEOF ; Arg 3: size
    JSR bbfs_file_write
    SET A, POP
    ADD SP, 2
    IFN A, BBFS_ERR_NONE
        ; Report an error
        SET PC, .error_A
    
    ; Sync the file to disk
    SET PUSH, B
    JSR bbfs_file_flush
    SET A, POP
    IFN A, BBFS_ERR_NONE
        ; Report an error
        SET PC, .error_A
        
    ; Report no error
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_A:
    SET [Z], A
    SET PC, .return
    
.return:
    ADD SP, BBFS_DIRHEADER_SIZEOF
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_directory_open(*directory, *header, drive_num, sector_num)
; Open an existing directory on disk,
; [Z+3]: BBFS_DIRECTORY to open into
; [Z+2]: BBFS_HEADER for the filesystem
; [Z+1]: drive number to open from
; [Z]: sector defining the directory's file.
; Returns: error code in [Z]
bbfs_directory_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBFS_DIRECTORY we're setting up
    SET PUSH, B ; BBFS_FILE for the directory
    SET PUSH, C ; BBFS_DIRHEADER we set up to read out
    
    SET A, [Z+3]
    
    ; Set B to the BBFS_FILE for the directory
    SET B, [Z+3]
    ADD B, BBFS_DIRECTORY_FILE
    
    ; Set C to a BBFS_DIRHEADER on the stack
    SUB SP, BBFS_DIRHEADER_SIZEOF
    SET C, SP
    
    ; Open the file
    SET PUSH, B ; Arg 1: BBFS_FILE to populate
    SET PUSH, [Z+2] ; Arg 2: BBFS_HEADER for the filesystem
    SET PUSH, [Z+1] ; Arg 3: drive number
    SET PUSH, [Z] ; Arg 4: sector defining file
    JSR bbfs_file_open
    SET [Z], POP
    ADD SP, 3
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Read out the BBFS_DIRHEADER
    SET PUSH, B ; Arg 1: file
    SET PUSH, C ; Arg 2: destination
    SET PUSH, BBFS_DIRHEADER_SIZEOF ; Arg 3: word count
    JSR bbfs_file_read
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; Make sure we opened a directory
    IFN [C+BBFS_DIRHEADER_VERSION], BBFS_VERSION
        SET PC, .error_notdir
        
    ; Fill in the number of remaining entries
    SET [A+BBFS_DIRECTORY_CHILDREN_LEFT] [C+BBFS_DIRHEADER_CHILD_COUNT]
    
    ; We succeeded
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
.error_notdir:
    SET [Z], BBFS_ERR_NOTDIR
.return:
    ADD SP, BBFS_DIRHEADER_SIZEOF
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_directory_next(*directory, *entry)
; Get the next directory entry from an opened directory. If no entries are left,
; returns BBFS_ERR_EOF.
; [Z+1]: BBFS_DIRECTORY that has been opened
; [Z]: BBFS_DIRENTRY to populate
; Returns: error code in [Z]
bbfs_directory_next:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBFS_DIRECTORY
    
    SET A, [Z+1]
    
    ; Check to see if entries remain.
    IFE [A+BBFS_DIRECTORY_CHILDREN_LEFT], 0
        SET PC, .error_eof
        
    ; Decrement remaining entries
    SUB [A+BBFS_DIRECTORY_CHILDREN_LEFT], 1
    
    ; Read from the file into the entry struct
    SET PUSH, A ; Arg 1: file to read
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, [Z] ; Arg 2: place to read to
    SET PUSH, BBFS_DIRENTRY_SIZEOF ; Arg 3: words to read
    JSR bbfs_file_read
    SET [Z], POP
    ADD SP, 2
    
    ; Just return whatever error code we got when reading the file.
    SET PC, .return
.error_eof:
    SET [Z], BBFS_ERR_EOF
.return:
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_directory_append(*directory, *entry)
; Append an entry to a directory.
; [Z+1]: BBFS_DIRECTORY to append to. Must have been created or opened.
; [Z]: BBFS_DIRENTRY to add
; Returns: error code in [Z]
bbfs_directory_append:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBFS_DIRECTORY pointer
    SET PUSH, B ; BBFS_DIRHEADER on stack
    SET PUSH, C ; BBFS_DIRENTRY we're adding
    
    SET A, [Z+1] ; Grab the BBFS_DIRECTORY
    
    ; Allocate a directory header
    SUB SP, BBFS_DIRHEADER_SIZEOF
    SET B, SP
    
    ; Grab the address of the directory entry, before we overwrite it with our
    ; error code
    SET C, [Z]
    
    ; First repoen the directory's file to wind back to the start
    SET PUSH, A ; Arg 1 - BBFS_FILE to reopen
    ADD [SP], BBFS_DIRECTORY_FILE
    JSR bbfs_file_reopen
    SET [Z], POP
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Read the directory header
    SET PUSH, A ; Arg 1: file to read from
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, B ; Arg 2: buffer to read to
    SET PUSH, BBFS_DIRHEADER_SIZEOF ; Arg 3: words to read
    JSR bbfs_file_read
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; Update the child count
    ADD [B+BBFS_DIRHEADER_CHILD_COUNT], 1
    
    ; Reopen again (seek to 0)
    SET PUSH, A ; Arg 1 - BBFS_FILE to reopen
    ADD [SP], BBFS_DIRECTORY_FILE
    JSR bbfs_file_reopen
    SET [Z], POP
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; Write the updated header
    SET PUSH, A ; Arg 1: file to write to
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, B ; Arg 2: buffer to write from
    SET PUSH, BBFS_DIRHEADER_SIZEOF ; Arg 3: words to write
    JSR bbfs_file_write
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; Seek to where the new child should start
    SET PUSH, A ; Arg 1: file to seek in
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, [B+BBFS_DIRHEADER_CHILD_COUNT] ; Arg 2: words to seek
    SUB [SP], 1 ; We knock one off, because with 1 entry total we start here
    MUL [SP], BBFS_DIRENTRY_SIZEOF
    JSR bbfs_file_seek
    SET [Z], POP
    ADD SP, 1
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; Write the directory entry
    SET PUSH, A ; Arg 1: file to write to
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, C ; Arg 2: buffer to write from (BBFS_DIRENTRY address)
    SET PUSH, BBFS_DIRENTRY_SIZEOF ; Arg 3: words to write
    JSR bbfs_file_write
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Since we're at the end of the directory file, there are no entries left to
    ; iterate through.
    SET [A+BBFS_DIRECTORY_CHILDREN_LEFT], 0
    
    ; Sync the directory file
    SET PUSH, A ; Arg 1: file to sync
    ADD [SP], BBFS_DIRECTORY_FILE
    JSR bbfs_file_flush
    SET [Z], POP
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; If we get here we did everything successfully
    SET [Z], BBFS_ERR_NONE
.return:
    ADD SP, BBFS_DIRHEADER_SIZEOF
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_directory_remove(*directory, index)
; Delete the directory entry at the given index.
; [Z+1]: BBFS_DIRECTORY to operate on
; [Z]: index in the directory of the entry to delete.
bbfs_directory_remove:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Hold the directory struct
    SET PUSH, B ; Hold the index to delete
    SET PUSH, C ; BBFS_DIRENTRY temp space
    SET PUSH, X ; BBFS_DIRHEADER temp space
    
    SET A, [Z+1] ; Grab the BBFS_DIRECTORY struct
    SET B, [Z] ; And the index to delete
    ; Add a directory entry temp on the stack
    SUB SP, BBFS_DIRENTRY_SIZEOF
    SET C, SP
    ; And a directory header (for decrementing entry count)
    SUB SP, BBFS_DIRHEADER_SIZEOF
    SET X, SP
    
    ; TODO: we can save a re-open in the case where we aren't at the end of the
    ; directory already.
        
    ; Reopen the directory to go back to the start
    SET PUSH, A ; Arg 1 - BBFS_FILE to reopen
    ADD [SP], BBFS_DIRECTORY_FILE
    JSR bbfs_file_reopen
    SET [Z], POP
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Read the header
    SET PUSH, A ; Arg 1: file to read from
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, X ; Arg 2: buffer to write to (BBFS_DIRHEADER address)
    SET PUSH, BBFS_DIRHEADER_SIZEOF ; Arg 3: words to read
    JSR bbfs_file_read
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; If the header says requested entry is not in the directory, fail as not
    ; found.
    IFL B, [X+BBFS_DIRHEADER_CHILD_COUNT]
        SET PC, .in_range
    ; It's out of range (handles empty directory)
    SET [Z], BBFS_ERR_NOTFOUND
    SET PC, .return
        
.in_range:
    
    ; Else, decrement entry count
    SUB [X+BBFS_DIRHEADER_CHILD_COUNT], 1
        
    ; Seek to where the last entry should start
    SET PUSH, A ; Arg 1: file to seek in
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, [X+BBFS_DIRHEADER_CHILD_COUNT] ; Arg 2: words to seek
    MUL [SP], BBFS_DIRENTRY_SIZEOF
    JSR bbfs_file_seek
    SET [Z], POP
    ADD SP, 1
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return

    ; Read the last entry. No harm in doing this even if we have no entries.
    SET PUSH, A ; Arg 1: file to read from
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, C ; Arg 2: buffer to write to (BBFS_DIRENTRY address)
    SET PUSH, BBFS_DIRENTRY_SIZEOF ; Arg 3: words to read
    JSR bbfs_file_read
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Reopen and jump to the beginning again.
    SET PUSH, A ; Arg 1 - BBFS_FILE to reopen
    ADD [SP], BBFS_DIRECTORY_FILE
    JSR bbfs_file_reopen
    SET [Z], POP
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Save the header
    SET PUSH, A ; Arg 1: file to read from
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, X ; Arg 2: buffer to write to (BBFS_DIRHEADER address)
    SET PUSH, BBFS_DIRHEADER_SIZEOF ; Arg 3: words to write
    JSR bbfs_file_write
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; If we were supposed to delete the end entry, just skip ahead to the
    ; truncating bit
    IFE B, [X+BBFS_DIRHEADER_CHILD_COUNT]
        SET PC, .was_final_entry
    
    ; Seek to where entry to remove should be
    SET PUSH, A ; Arg 1: file to seek in
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, B ; Arg 2: words to seek (entry index to delete * entry size)
    MUL [SP], BBFS_DIRENTRY_SIZEOF
    JSR bbfs_file_seek
    SET [Z], POP
    ADD SP, 1
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Write the former final entry over it
    SET PUSH, A ; Arg 1: file to write to
    ADD [SP], BBFS_DIRECTORY_FILE
    SET PUSH, C ; Arg 2: buffer to write from (BBFS_DIRENTRY address)
    SET PUSH, BBFS_DIRENTRY_SIZEOF ; Arg 3: words to write
    JSR bbfs_file_write
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
.was_final_entry:
    ; If it was the final entry we wanted to drop, we just discard the old final
    ; entry and don't write it back.
    
    ; Reopen *again* (TODO: don't do if we won't drop a page, or just write
    ; special page-droping logic. TODO: we could also know where we are and
    ; where we want to be and just not re-open and seek directly instead.
    SET PUSH, A ; Arg 1 - BBFS_FILE to reopen
    ADD [SP], BBFS_DIRECTORY_FILE
    JSR bbfs_file_reopen
    SET [Z], POP
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Go to the character right *before* the old last entry (which may be in the
    ; header)
    SET PUSH, A ; Arg 1: file to seek in
    ADD [SP], BBFS_DIRECTORY_FILE
    ; Arg 2: words to seek (entry count * entry size - 1 + header)
    SET PUSH, [X+BBFS_DIRHEADER_CHILD_COUNT] 
    MUL [SP], BBFS_DIRENTRY_SIZEOF
    ADD [SP], BBFS_DIRHEADER_SIZEOF - 1
    JSR bbfs_file_seek
    SET [Z], POP
    ADD SP, 1
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; Truncate the file
    SET PUSH, A ; Arg 1: file to truncate
    ADD [SP], BBFS_DIRECTORY_FILE
    JSR bbfs_file_truncate
    SET [Z], POP
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Sync the directory file
    SET PUSH, A ; Arg 1: file to sync
    ADD [SP], BBFS_DIRECTORY_FILE
    JSR bbfs_file_flush
    SET [Z], POP
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
    
    ; Return success
    SET [Z], BBFS_ERR_NONE
.return:
    ; Say we have no more children. If we had an error, we're in an undefined
    ; state, and if we succeeded, we're not aligned to an entry boundary and
    ; can't get to one easily.
    SET [A+BBFS_DIRECTORY_CHILDREN_LEFT], 0
    
    ADD SP, BBFS_DIRHEADER_SIZEOF
    ADD SP, BBFS_DIRENTRY_SIZEOF
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
    
    
; bbfs_filename_pack(*unpacked, *packed)
; Pack a normal string of lenght 16 or less into a packed string in 8 words.
; High bits of individual unpacked characters should be 0, and may be 0'd out.
; [Z+1]: unpacked string
; [Z]: packed string
bbfs_filename_pack:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; unpacked string
    SET PUSH, B ; Packed string
    SET PUSH, C ; character index
    SET PUSH, X ; Addressing scratch
    SET PUSH, Y ; Character scratch
    
    SET A, [Z+1]
    SET B, [Z]
    
    ; First zero out the packed filename
    SET C, 0
.zero_loop:
    SET X, B
    ADD X, C
    SET [X], 0
    ADD C, 1
    IFL C, BBFS_FILENAME_PACKED
        SET PC, .zero_loop
        
    ; Now go copying characters
    SET C, 0
.copy_loop:
    ; Get the high character
    SET X, C
    MUL X, 2
    ADD X, A
    IFE [X], 0
        ; No need to pack a null
        SET PC, .return
    SET Y, [X]
    
    ; Shift it up
    SHL Y, 8
    
    ; Or in the low character
    ADD X, 1
    IFE [X], 0
        ; No need to pack a null
        SET PC, .pack_high_only
    AND [X], 0x00FF
    BOR Y, [X]
    
    ; Now save it
    SET X, B
    ADD X, C
    SET [X], Y
    
    ; Repeat until all pairs of characters are packed
    ADD C, 1
    IFL C, BBFS_FILENAME_PACKED
        SET PC, .copy_loop
        
    SET PC, .return
        
.pack_high_only:
    ; We have to save the high character, but leave the low as a null
    SET X, B
    ADD X, C
    SET [X], Y
    ; After a null, filename ends
    
.return:
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_filename_unpack(*unpacked, *packed)
; Unpack a normal string of length 16 or less from a packed string in 8 words.
; Unpacked buffer must be 17 words or more, for trailing null.
; [Z+1]: unpacked string
; [Z]: packed string
bbfs_filename_unpack:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; unpacked string
    SET PUSH, B ; Packed string
    SET PUSH, C ; character index
    SET PUSH, X ; Addressing scratch
    SET PUSH, Y ; Character scratch
    
    SET A, [Z+1]
    SET B, [Z]
    
    ; First zero out the unpacked filename
    SET C, 0
.zero_loop:
    SET X, A
    ADD X, C
    SET [X], 0
    ADD C, 1
    IFL C, BBFS_FILENAME_BUFSIZE
        SET PC, .zero_loop
        
    ; Now go copying characters
    SET C, 0
.copy_loop:
    ; Get the packed pair
    SET X, B
    ADD X, C
    SET Y, [X]
    
    ; Find where the high char goes
    SET X, C
    MUL X, 2
    ADD X, A
    
    ; Unpack the high char
    SET [X], Y
    SHR [X], 8
    
    ; Find where the low char goes
    ADD X, 1
    
    ; Unpack it too
    SET [X], Y
    AND [X], 0x00FF
    
    ; Repeat until all pairs of characters are unpacked
    ADD C, 1
    IFL C, BBFS_FILENAME_PACKED
        SET PC, .copy_loop
        
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_filename_compare(*packed1, *packed2)
; Return 1 if the packed filenames match, 0 otherwise.
; Performs case-insensitive comparison
; [Z+1]: Filename 1
; [Z]: Filename 2
; Return: 1 for match or 0 for mismatch in [Z]
bbfs_filename_compare:
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Filename 1 addressing
    SET PUSH, B ; Filename 2 addressing
    SET PUSH, C ; Character counter
    SET PUSH, X ; Filename 1 character
    SET PUSH, Y ; Filename 2 character
    
    SET A, [Z+1] ; Load string 1
    SET B, [Z] ; And string 2
    
    SET C, 0
.loop:
    ; Unpack character 1 from filename 1
    SET X, [A]
    SHR X, 8
    
    IFG X, 0x60 ; If it's greater than ` (char before a)
        IFL X, 0x7B ; And less than { (char after z)
            SUB X, 32 ; Knock it down to upper case
            
    ; Also character 1 from filename 2
    SET Y, [B]
    SHR Y, 8
    
    IFG Y, 0x60 ; If it's greater than ` (char before a)
        IFL Y, 0x7B ; And less than { (char after z)
            SUB Y, 32 ; Knock it down to upper case

    IFN X, Y
        SET PC, .unequal
        
    ; And character 2 from each
    SET X, [A]
    AND X, 0xFF
    
    IFG X, 0x60 ; If it's greater than ` (char before a)
        IFL X, 0x7B ; And less than { (char after z)
            SUB X, 32 ; Knock it down to upper case
            
    SET Y, [B]
    AND Y, 0xFF
    
    IFG Y, 0x60 ; If it's greater than ` (char before a)
        IFL Y, 0x7B ; And less than { (char after z)
            SUB Y, 32 ; Knock it down to upper case

    IFN X, Y
        SET PC, .unequal
        
    ADD A, 1
    ADD B, 1
    ADD C, 1
    IFL C, BBFS_FILENAME_PACKED
        SET PC, .loop
    
    ; If we get here they're equal
    SET [Z], 1
    SET PC, .return
    
.unequal:
    SET [Z], 0
.return:
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
    
    




