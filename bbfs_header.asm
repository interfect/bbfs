; bbfs_header.asm
; Filesystem-header and disk-level BBFS function implementations.

; bbfs_drive_load(drive_num, header*)
; Load header info from the given drive to the given address.
; [Z+1]: BBOS drive to operate on
; [Z]: BBFS_HEADER to operate on
bbfs_drive_load:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    ; We loop 0, 1, 2 and load sectors 1, 2, 3    
    SET PUSH, A ; BBOS command
    SET PUSH, B ; Loop index
    SET PUSH, C ; offset into header
    
    SET B, 0
.loop:
    ; Calculate offset to write to
    SET C, B
    MUL C, BBFS_WORDS_PER_SECTOR
    ; Then offset from the header start
    ADD C, [Z]
    
    ; Read the sector
    SET PUSH, B ; Arg 1: Sector to read
    ADD [SP], 1
    SET PUSH, C ; Arg 2: Pointer to read to
    SET PUSH, [Z+1] ; Arg 3: drive number
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ; TODO: We assume success
    ADD SP, 3 
    
    ; Loop through 0, 1, and 2
    ADD B, 1
    IFL B, 3
        SET PC, .loop
.loop_break:
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_drive_save(drive_num, header*)
; Save header info to the given drive from the given address.
; [Z+1]: BBOS drive to operate on
; [Z]: BBFS_HEADER to operate on
bbfs_drive_save:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    ; We loop 0, 1, 2 and load sectors 1, 2, 3    
    SET PUSH, A ; BBOS command
    SET PUSH, B ; Loop index
    SET PUSH, C ; offset into header
    
    SET B, 0
.loop:
    ; Calculate offset to read from
    SET C, B
    MUL C, BBFS_WORDS_PER_SECTOR
    ; Then offset from the header start
    ADD C, [Z]
    
    ; Read the sector
    SET PUSH, B ; Arg 1: Sector to write
    ADD [SP], 1
    SET PUSH, C ; Arg 2: Pointer to write to
    SET PUSH, [Z+1] ; Arg 3: drive number
    SET A, WRITE_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ; TODO: We assume success
    ADD SP, 3 
    
    ; Loop through 0, 1, and 2
    ADD B, 1
    IFL B, 3
        SET PC, .loop
.loop_break:
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
    
    

; bbfs_header_allocate_sector(*header, sector_num)
; Mark a sector as in use (0 its free bit)
; [Z+1]: BBFS_HEADER to operate on
; [Z]: sector to allocate
bbfs_header_allocate_sector:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Bitmask for setting
    SET PUSH, B ; Bit offset in its word
    SET PUSH, C ; Word the bit appears in
    
    ; Where is the relevant word
    SET C, [Z]
    DIV C, 16
    ; Use that as an offset into the free bitmask
    ADD C, BBFS_HEADER_FREEMASK
    ; And look in the right struct in memory
    ADD C, [Z+1]
    
    ; What bit in the word do we want?
    SET B, [Z]
    MOD B, 16
    
    ; Make the mask
    SET A, 1
    SHL A, B
    
    XOR A, 0xffff ; Flip every bit in the mask    
    AND [C], A ; Keep all the bits except the target one 
    
    SET C, [C]
    
    ; Return
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_header_free_sector(*header, sector_num)
; Mark a sector as free (1 its free bit)
; [Z+1]: BBFS_HEADER to operate on
; [Z]: sector to free
bbfs_header_free_sector:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Bitmask for setting
    SET PUSH, B ; Bit offset in its word
    SET PUSH, C ; Word the bit appears in
    
    ; Where is the relevant word
    SET C, [Z]
    DIV C, 16
    ; Use that as an offset into the free bitmask
    ADD C, BBFS_HEADER_FREEMASK
    ; And look in the right struct in memory
    ADD C, [Z+1]
    
    ; What bit in the word do we want?
    SET B, [Z]
    MOD B, 16
    
    ; Make the mask
    SET A, 1
    SHL A, B
    
    BOR [C], A ; Set the bit to mark the sector free
    
    ; Return
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_header_find_free_sector(*header)
; Return the first free sector on the disk, or 0xFFFF if no sector is free.
; [Z]: address of BBFS header to search
bbfs_header_find_free_sector:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Word we have found a free sector in
    SET PUSH, B ; Free bit in the word
    SET PUSH, C ; Addressing scratch
    SET PUSH, X ; Mask
    
    SET A, 0 ; Start at word 0 in the bitmap
    
    
.word_loop:
    ; Look at that word in the bitmap
    SET C, A
    ADD C, [Z]
    ADD C, BBFS_HEADER_FREEMASK
    
    IFN [C], 0 ; We found a word that doesn't represent 16 used sectors
        SET PC, .found_word
    
    ; Otherwise keep searching
    ADD A, 1
    IFL A, BBFS_SECTOR_WORDS
        SET PC, .word_loop
    
    ; We might not find anything if all the sectors are used
    SET [Z], 0xFFFF
    SET PC, .return
    
.found_word:
    ; Word at index A, address C has a free sector bit
    ; Look for the bit
    SET B, 0
    
.bit_loop:
    ; Make the mask
    SET X, 1
    SHL X, B
    
    ; Check against the word
    AND X, [C]
    
    IFG X, 0 ; This bit is set (free)
        SET PC, .found_bit

    ADD B, 1
    IFL B, 16 ; Keep going through bits 0-15
        SET PC, .bit_loop
        
    ; We should never end up not finding a free bit, but if we do:
    SET [Z], 0xFFFF
    SET PC, .return

.found_bit:   
    
    ; Compute word * 16 + bit and return it
    SET [Z], A
    MUL [Z], 16
    ADD [Z], B
    
.return:
    ; Return
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_header_format(*header)
; Format a new BBFS header.
; [Z]: header start address in memory
bbfs_header_format:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Holds the address we're working on
    SET PUSH, B ; Loop index
    
    SET A, [Z]
    
    ; Fill in the version
    SET [A], 0xBF56
    ADD A, 1
    
    ; Fill in the reserved bytes
    SET B, 0
.reserved_loop:
    SET [A], 0
    ADD A, 1
    ADD B, 1
    IFL B, 5 ; Fill 5 bytes
        SET PC, .reserved_loop
    
    ; Fill in the free bitmap with all 1s
    SET B, 0
.free_loop:
    SET [A], 0xFFFF
    ADD A, 1
    ADD B, 1
    IFL B, BBFS_SECTOR_WORDS ; Fill one bit per sector
        SET PC, .free_loop
    
    ; Mark sectors 0, 1, 2, and 3 as in use
    SET B, [Z]
    ADD B, BBFS_HEADER_FREEMASK
    SET [B], 0xFFF0
    
    ; Fill in the FAT with 0xFFFF
    SET B, 0
.fat_loop:
    SET [A], 0xFFFF
    ADD A, 1
    ADD B, 1
    IFL B, BBFS_SECTORS ; Fill one word per sector
        SET PC, .fat_loop

    ; Return
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

