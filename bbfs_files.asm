; bbfs_files.asm
; File-level BBFS function implementations.

; bbfs_file_create(*file, *header, drive_num)
; Create a file in a new free sector and populate the file handle.
; [Z+2]: BBFS_FILE to populate
; [Z+1]: BBFS_HEADER to use
; [Z]: BBOS drive number to use for the file (TODO: keep it in header)
; Returns: error code in [Z]
bbfs_file_create:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Holds the file struct address
    
    ; Grab the file struct
    SET A, [Z+2]
    
    ; Fill in the drive
    SET [A+BBFS_FILE_DRIVE], [Z]
    ; And header address
    SET [A+BBFS_FILE_FILESYSTEM_HEADER], [Z+1]
    
    ; Find a free sector and fill in both sector values.
    ; TODO: may be 0xFFFF if disk is full
    SET PUSH, [Z+1] ; Arg 1 - BBFS_HEADER to search
    JSR bbfs_header_find_free_sector
    SET [A+BBFS_FILE_START_SECTOR], POP
    SET [A+BBFS_FILE_SECTOR], [A+BBFS_FILE_START_SECTOR]
    
    ; Make sure we actually got back a sector
    IFE [A+BBFS_FILE_START_SECTOR], 0xFFFF
        SET PC, .error
    
    ; Mark the sector allocated
    SET PUSH, [Z+1] ; Arg 1 - BBFS_HEADER to update
    SET PUSH, [A+BBFS_FILE_START_SECTOR] ; Arg 2 - Sector to mark allocated
    JSR bbfs_header_allocate_sector
    ADD SP, 2
    
    ; Fill in the offset for starting at the beginning of the sector
    SET [A+BBFS_FILE_OFFSET], 0
    ; Say no words are in the file yet.
    SET [A+BBFS_FILE_MAX_OFFSET], 0
    
    ; Don't bother with the file handle's buffer area.
    
    ; Commit the filesystem changes to disk
    SET PUSH, [Z] ; Drive number
    SET PUSH, [Z+1] ; Header pointer
    JSR bbfs_drive_save
    ADD SP, 2
    
    ; We were successful
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error:
    ; The only error we can have is a full disk
    SET [Z], BBFS_ERR_DISC_FULL

.return:
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_open(*file, *header, drive_num, sector_num)
; Open an existing file at the given sector on the given drive, and populate the
; file handle.
; [Z+3]: BBFS_FILE to populate
; [Z+2]: BBFS_HEADER to use
; [Z+1]: BBOS drive number
; [Z]: Sector at which the file starts
; Returns: error code in [Z]
bbfs_file_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Holds the file struct address
    SET PUSH, B ; Scratch for FAT interrogation
    
    ; Grab the file struct
    SET A, [Z+3]

    ; Populate the file struct
    ; Fill in the drive
    SET [A+BBFS_FILE_DRIVE], [Z+1]
    ; And header address
    SET [A+BBFS_FILE_FILESYSTEM_HEADER], [Z+2]
    ; And the sector indexes
    SET [A+BBFS_FILE_START_SECTOR], [Z]
    SET [A+BBFS_FILE_SECTOR], [Z]
    ; And zero the offset
    SET [A+BBFS_FILE_OFFSET], 0
    
    ; Load the number of words available to read in the sector
    ; Find the FS header
    SET B, [Z+2]
    ; And the FAT in it
    ADD B, BBFS_HEADER_FAT
    ; And the entry for this sector in the FAT
    ADD B, [Z]
    
    ; Load out the value
    SET B, [B]
    
    IFL B, 0x8000
        ; The high bit is unset, so this first sector is not also the last and
        ; is guaranteed to be full
        SET B, BBFS_WORDS_PER_SECTOR
    
    AND B, 0x7FFF ; Take everything but the high bit
    ; And say that that's the current file length within this sector.
    SET [A+BBFS_FILE_MAX_OFFSET], B 
    
    ; Read the right sector into the file struct's buffer. This clobbers A
    SET PUSH, [Z] ; Arg 1: Sector to read
    SET PUSH, A ; Arg 2: Pointer to read to
    ADD [SP], BBFS_FILE_BUFFER
    SET PUSH, [A+BBFS_FILE_DRIVE] ; Arg 3: Drive to read from
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ; TODO: handle drive errors
    ADD SP, 3

    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_reopen(*file)
; Reset back to the beginning of the file. Returns an error code.
; [Z]: BBFS_FILE to reopen
; Returns: error code on [Z]
bbfs_file_reopen:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls, FAT scratch
    SET PUSH, B ; File pointer
    
    SET B, [Z]
    
    IFE [B+BBFS_FILE_SECTOR], [B+BBFS_FILE_START_SECTOR]
        ; We don't have to move sectors
        SET PC, .no_sector_change
    
    ; Move back to the first sector
    ; First flush the file (which updates the FAT with the length if needed)
    SET PUSH, B
    JSR bbfs_file_flush
    SET A, POP
    IFN A, BBFS_ERR_NONE
        ; Just return this error code
        SET PC, .error_A
        
    ; Now change sectors
    SET [B+BBFS_FILE_SECTOR], [B+BBFS_FILE_START_SECTOR]
    
    ; Load it from disk (even if newly allocated)
    ; Clobber A with the BBOS call
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 1: Sector to read
    SET PUSH, B ; Arg 2: Pointer to write to
    ADD [SP], BBFS_FILE_BUFFER
    SET PUSH, [B+BBFS_FILE_DRIVE] ; Arg 3: Drive to read from
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ; TODO: handle drive errors
    ADD SP, 3
    
    ; If we changed sectors back to the first sector, this means there was a
    ; following sector and the first sector is thus full.
    SET [B+BBFS_FILE_MAX_OFFSET], BBFS_WORDS_PER_SECTOR
    
.no_sector_change:
    ; Move back to start of buffer
    SET [B+BBFS_FILE_OFFSET], 0

    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_A:
    ; Report the error in A
    SET [Z], A
    
.return:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_flush(*file)
; Flush the data in the currently buffered sector to disk. Returns an error
; code.
; [Z]: BBFS_FILE to flush
; Returns: error code in [Z]
bbfs_file_flush:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS calls
    SET PUSH, B ; BBFS_FILE struct addressing

    SET B, [Z] ; Load the address of the file struct

    ; Just make the BBOS write call
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 1: Sector to write
    SET PUSH, B ; Arg 2: Pointer to write from
    ADD [SP], BBFS_FILE_BUFFER
    SET PUSH, [B+BBFS_FILE_DRIVE] ; Arg 3: Drive to write to
    SET A, WRITE_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ; TODO: handle drive errors
    ADD SP, 3
    
    IFG [B+BBFS_FILE_MAX_OFFSET], BBFS_WORDS_PER_SECTOR-1
        ; The whole of this sector is actually used, so we can just return
        SET PC, .return
        
    ; Otherwise we need to say only part of this (last) sector is used.
    ; Find the FS header
    SET A, [B+BBFS_FILE_FILESYSTEM_HEADER]
    ; And the FAT in it
    ADD A, BBFS_HEADER_FAT
    ; And the entry for this sector in the FAT
    ADD A, [B+BBFS_FILE_SECTOR]
    
    ; TODO: assert that it looks like a last sector
    ; Save the number of words
    SET [A], [B+BBFS_FILE_MAX_OFFSET]
    ; Set the high bit to mark it a last sector
    BOR [A], 0x8000
    
    ; Commit the FS header changes
    SET PUSH, [B+BBFS_FILE_DRIVE] ; Drive number
    SET PUSH, [B+BBFS_FILE_FILESYSTEM_HEADER] ; Header pointer
    JSR bbfs_drive_save
    ADD SP, 2
    ; TODO: catch drive errors
    
.return:
    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_write(*file, *data, size)
; Write the given number of words from the given address to the given file.
; [Z+2]: BBFS_FILE to write to
; [Z+1]: Address to get data from
; [Z]: number of words to write
; Returns: error code in [Z]
bbfs_file_write:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS calls, scratch, pointing to the FAT word
    SET PUSH, B ; File struct address
    SET PUSH, C ; Filesystem header struct address
    SET PUSH, I ; Pointer into file buffer
    SET PUSH, J ; Pointer into data
    SET PUSH, X ; Newly allocated sector, addressing scratch
    
    ; We're going to decrement [Z] as we write words until it's 0
    
    ; Load the file struct address
    SET B, [Z+2]
    ; And the FS header struct address
    SET C, [B+BBFS_FILE_FILESYSTEM_HEADER]
    ; Point I at the word in the file buffer to write to
    SET I, B
    ADD I, BBFS_FILE_BUFFER
    ADD I, [B+BBFS_FILE_OFFSET]
    ; Point J at the data word to read
    SET J, [Z+1]
    
.write_until_full:
    IFE [Z], 0 ; No more words to write
        SET PC, .done_writing
    IFE [B+BBFS_FILE_OFFSET], BBFS_WORDS_PER_SECTOR
        ; We've filled up our buffered sector
        SET PC, .go_to_next_sector
        
    ; Otherwise write a word to the buffer, and move both pointers
    STI [I], [J]
    ; Consume one word from our to-do list
    SUB [Z], 1
    ; And one word of this sector. This can point to the past-the-end word.
    ADD [B+BBFS_FILE_OFFSET], 1
    
    IFG [B+BBFS_FILE_OFFSET], [B+BBFS_FILE_MAX_OFFSET]
        ; We need to expand the part of this sector used by bumping up the max
        ; offset in this sector.
        SET [B+BBFS_FILE_MAX_OFFSET], [B+BBFS_FILE_OFFSET]
    
    ; Loop around
    SET PC, .write_until_full
    
.go_to_next_sector:
    ; When the current sector is full, save it to disk
    SET PUSH, B
    JSR bbfs_file_flush
    SET A, POP
    IFN A, BBFS_ERR_NONE
        ; Return whatever error we got
        SET PC, .error_A

    ; If we already have a next sector allocated, go to that one
    ; Look in the FAT at the current sector
    SET A, C
    ADD A, BBFS_HEADER_FAT
    ADD A, [B+BBFS_FILE_SECTOR]
    
    IFG [A], 0x7FFF
        ; If the high bit is set, this was the last sector
        ; Allocate a new sector
        SET PC, .allocate_sector
    
.sector_available:
    ; Now [A] holds the next sector, and any changes have been committed to disk
    
    ; Point the file at the start of the new sector
    SET [B+BBFS_FILE_SECTOR], [A]
    SET [B+BBFS_FILE_OFFSET], 0
    
    ; Load the number of words available to read in the sector. We'll point A to
    ; the new sector's FAT entry.
    ; Find the FS header
    SET A, [B+BBFS_FILE_FILESYSTEM_HEADER]
    ; And the FAT in it
    ADD A, BBFS_HEADER_FAT
    ; And the entry for this sector in the FAT
    ADD A, [B+BBFS_FILE_SECTOR]
    
    ; Load out the value
    SET A, [A]
    
    IFL A, 0x8000
        ; The high bit is unset, so this first sector is not also the last and
        ; is guaranteed to be full
        SET A, BBFS_WORDS_PER_SECTOR
    
    AND A, 0x7FFF ; Take everything but the high bit
    ; And say that that's the current file length within this sector.
    SET [B+BBFS_FILE_MAX_OFFSET], A 
    
    ; Load the sector from disk (even if newly allocated)
    ; Clobber A with the BBOS call
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 1: Sector to read
    SET PUSH, B ; Arg 2: Pointer to write to
    ADD [SP], BBFS_FILE_BUFFER
    SET PUSH, [B+BBFS_FILE_DRIVE] ; Arg 3: Drive to read from
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ; TODO: handle drive errors
    ADD SP, 3
    
    ; Move the cursor back to the start of the buffer
    SET I, B
    ADD I, BBFS_FILE_BUFFER
    ADD I, [B+BBFS_FILE_OFFSET]
    
    ; Keep writing
    SET PC, .write_until_full
    
.allocate_sector:
    ; We need to fill in [A] with a new sector and then commit the header
    ; changes to disk. We also need to preserve A.
    
    ; Find a free sector and save it there
    SET PUSH, C ; Arg 1 - BBFS_HEADER to find a sector in
    JSR bbfs_header_find_free_sector
    SET X, POP
    
    IFE X, 0xFFFF
        ; No free sector was available
        SET PC, .error_space
    ; Else we got a sector, point to it
    
    ; Otherwise we got a free one.
    
    ; Point to it in the FAT
    SET [A], X
    
    ; Allocate it
    SET PUSH, C ; Arg 1 - BBFS_HEADER to update
    SET PUSH, X ; Arg 2 - Sector to mark allocated
    JSR bbfs_header_allocate_sector
    ADD SP, 2
    
    ; Say it has no words used in its FAT entry.
    ; First find that entry with X.
    SET X, [B+BBFS_FILE_FILESYSTEM_HEADER]
    ADD X, BBFS_HEADER_FAT
    ADD X, [A]
    
    ; Set the high bit (sector is last in file), but leave the words used count
    ; as 0. This will then get loaded into the file max offset when the sector
    ; is loaded above.
    SET [X], 0x8000
    
    ; Commit the filesystem changes to disk
    SET PUSH, [B+BBFS_FILE_DRIVE] ; Drive number
    SET PUSH, C ; Header pointer
    JSR bbfs_drive_save
    ADD SP, 2
    ; TODO: catch drive errors
    
    ; Go back to reading this next sector from the file
    SET PC, .sector_available
    
.done_writing:
    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_A:
    ; Return the error in A
    SET [Z], A
    SET PC, .return
    
.error_space:
    ; Return the out of space error
    SET [Z], BBFS_ERR_DISC_FULL

.return:
    SET X, POP
    SET J, POP
    SET I, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_read(*file, *data, size)
; Read the given number of words from the given file into the given buffer.
; [Z+2]: BBFS_FILE to read from
; [Z+1]: Buffer to read into
; [Z]: Number of words to read
; Returns: error code in [Z]
bbfs_file_read:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS calls, scratch
    SET PUSH, B ; File struct address
    SET PUSH, C ; Filesystem header struct address
    SET PUSH, I ; Pointer into file buffer
    SET PUSH, J ; Pointer into data
    
    ; We're going to decrement [Z] as we read words until it's 0
    
    ; Load the file struct address
    SET B, [Z+2]
    ; And the FS header struct address
    SET C, [B+BBFS_FILE_FILESYSTEM_HEADER]
    ; Point I at the word in the file buffer to read from
    SET I, B
    ADD I, BBFS_FILE_BUFFER
    ADD I, [B+BBFS_FILE_OFFSET]
    ; Point J at the data word to write
    SET J, [Z+1]
    
.read_until_depleted:
    IFE [Z], 0 ; No more words to read
        SET PC, .done_reading
    IFE [B+BBFS_FILE_OFFSET], BBFS_WORDS_PER_SECTOR
        ; We've used up our buffered sector
        SET PC, .go_to_next_sector
    IFG [B+BBFS_FILE_OFFSET], [B+BBFS_FILE_MAX_OFFSET]
        ; Our max offset isn;t a full sector and we've depleted it.
        ; We know this has to be the last sector, so just say EOF.
        SET PC, .error_end_of_file
    
    ; Otherwise read a word from the buffer, and move both pointers
    STI [J], [I]
    ; Consume one word from our to-do list
    SUB [Z], 1
    ; And one word of this sector
    ADD [B+BBFS_FILE_OFFSET], 1
    
    ; Loop around
    SET PC, .read_until_depleted
    
.go_to_next_sector:

    ; If we have a next sector allocated, go to that one
    ; Look in the FAT at the current sector
    SET A, C
    ADD A, BBFS_HEADER_FAT
    ADD A, [B+BBFS_FILE_SECTOR]
    
    IFE [A], 0xFFFF
        ; Otherwise, the file is over
        SET PC, .error_end_of_file
    
    ; Now [A] holds the next sector
    ; Point the file at the start of the new sector
    SET [B+BBFS_FILE_SECTOR], [A]
    SET [B+BBFS_FILE_OFFSET], 0
    
    ; Load it from disk
    ; Clobber A with the BBOS call
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 1: Sector to read
    SET PUSH, B ; Arg 2: Pointer to write to
    ADD [SP], BBFS_FILE_BUFFER
    SET PUSH, [B+BBFS_FILE_DRIVE] ; Arg 3: Drive to read from
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    SET A, POP
    ADD SP, 2
    
    ; Handle drive errors
    IFE A, 0
        SET PC, .error_drive
    
    ; Move the cursor back to the start of the buffer
    SET I, B
    ADD I, BBFS_FILE_BUFFER
    ADD I, [B+BBFS_FILE_OFFSET]
    
    ; Load the number of words available to read in the sector. We'll point A to
    ; the new sector's FAT entry.
    ; Find the FS header
    SET A, [B+BBFS_FILE_FILESYSTEM_HEADER]
    ; And the FAT in it
    ADD A, BBFS_HEADER_FAT
    ; And the entry for this sector in the FAT
    ADD A, [B+BBFS_FILE_SECTOR]
    
    ; Load out the value
    SET A, [A]
    
    IFL A, 0x8000
        ; The high bit is unset, so this sector is not the last and is
        ; guaranteed to be full
        SET A, BBFS_WORDS_PER_SECTOR
    
    AND A, 0x7FFF ; Take everything but the high bit
    ; And say that that's the current file length within this sector.
    SET [B+BBFS_FILE_MAX_OFFSET], A 
    
    ; Keep reading
    SET PC, .read_until_depleted
    
.done_reading:
    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_end_of_file:
    ; Return the end of file error
    SET [Z], BBFS_ERR_EOF
    SET PC, .return
    
.error_drive:
    ; Return drive error
    SET [Z], BBFS_ERR_DRIVE

.return:
    SET J, POP
    SET I, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_seek(*file, distance)
; Skip ahead the given number of words.
; [Z+1]: BBFS_FILE to skip in
; [Z]: Words to skip
; Returns: error code in [Z]
bbfs_file_seek:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS calls, scratch
    SET PUSH, B ; File struct address
    SET PUSH, C ; Filesystem header struct address
    SET PUSH, X ; Flag for if we need to re-load the sector at the end
    SET PUSH, Y ; FAT addressing scratch
    
    ; We're going to decrement [Z] as we skip until it's 0
    
    ; Load the file struct address
    SET B, [Z+1]
    ; And the FS header struct address
    SET C, [B+BBFS_FILE_FILESYSTEM_HEADER]
    
    SET X, 0 ; By default we don't need to touch any data sectors
    
    ; We need to save the current sector if we need to skip more than a sector,
    ; or if we need to skip less than a sector but we're too close to the end.
    IFG [Z], BBFS_WORDS_PER_SECTOR
        SET PC, .save_current_sector
    SET A, [Z]
    ADD A, [B+BBFS_FILE_OFFSET]
    IFG A, BBFS_WORDS_PER_SECTOR
        SET PC, .save_current_sector
    
.skip_until_done:
    IFE [Z], 0 ; No more words to skip
        SET PC, .done_skipping
    IFG [Z], BBFS_WORDS_PER_SECTOR
        ; We want to skip a whole sector or more
        SET PC, .go_to_next_sector
    SET A, [Z]
    ADD A, [B+BBFS_FILE_OFFSET]
    IFG A, BBFS_WORDS_PER_SECTOR
        ; We want to skip an amount that would put us in the next sector
        SET PC, .go_to_next_sector
    
    ; Otherwise we just need to adjust our position in this sector
    ADD [B+BBFS_FILE_OFFSET], [Z]
    SET [Z], 0
    
    IFG [B+BBFS_FILE_OFFSET], [B+BBFS_FILE_MAX_OFFSET]
        ; We need to extend this sector's used words
        SET [B+BBFS_FILE_MAX_OFFSET], [B+BBFS_FILE_OFFSET]
    
    ; Loop around
    SET PC, .skip_until_done
    
.save_current_sector:
    ; Save the sector the file is at now
    SET PUSH, B
    JSR bbfs_file_flush
    SET A, POP
    IFN A, BBFS_ERR_NONE
        ; Return whatever error we got
        SET PC, .error_A
        
    ; Remember that we need to re-load the sector we're pointing to
    SET X, 1
        
    SET PC, .skip_until_done

.go_to_next_sector:
    
    ; If we already have a next sector allocated, go to that one
    ; Otherwise, allocate a new sector
    
    ; Look in the FAT at the current sector
    SET A, C
    ADD A, BBFS_HEADER_FAT
    ADD A, [B+BBFS_FILE_SECTOR]
    
    IFG [A], 0x7FFF
        ; High bit is set, so this is the last sector. ALlocate a new one.
        SET PC, .allocate_sector
    
.sector_available:
    ; Now [A] holds the next sector, and any changes have been committed to disk
    
    ; Adjust how much we have to skip to account for jumping to the start of the
    ; next sector. Note that this may underflow and then overflow back.
    SUB [Z], BBFS_WORDS_PER_SECTOR
    ADD [Z], [B+BBFS_FILE_OFFSET]
    
    ; Point the file at the start of the new sector
    SET [B+BBFS_FILE_SECTOR], [A]
    SET [B+BBFS_FILE_OFFSET], 0
    
    SET PC, .skip_until_done
    
.allocate_sector:
    ; We need to fill in [A] with a new sector and then commit the header
    ; changes to disk.
    
    ; Find a free sector and save it there
    SET PUSH, C ; Arg 1 - BBFS_HEADER to find a sector in
    JSR bbfs_header_find_free_sector
    SET Y, POP
    
    IFE Y, 0xFFFF
        ; No free sector was available
        SET PC, .error_space
    ; Else we got a sector, point to it
    SET [A], Y
        
    ; Allocate it
    SET PUSH, C ; Arg 1 - BBFS_HEADER to update
    SET PUSH, [A] ; Arg 2 - Sector to mark allocated
    JSR bbfs_header_allocate_sector
    ADD SP, 2
    
    ; Say it has no words used in its FAT entry.
    ; First find that entry with Y.
    SET Y, [B+BBFS_FILE_FILESYSTEM_HEADER]
    ADD Y, BBFS_HEADER_FAT
    ADD Y, [A]
    
    ; Set the high bit (sector is last in file), but leave the words used count
    ; as 0. This will then get loaded into the file max offset when the sector
    ; is loaded.
    SET [Y], 0x8000
    
    ; Commit the filesystem changes to disk
    SET PUSH, [B+BBFS_FILE_DRIVE] ; Drive number
    SET PUSH, C ; Header pointer
    JSR bbfs_drive_save
    ADD SP, 2
    ; TODO: catch drive errors
    
    ; Go back to updating the file offset and then skipping more
    SET PC, .sector_available
    
.done_skipping:
    
    IFE X, 0
        ; We stayed in the same sector
        SET PC, .no_reload
        
    ; Load up the sector that the file points at.
    ; Clobber A with the BBOS call
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 1: Sector to read
    SET PUSH, B ; Arg 2: Pointer to write to
    ADD [SP], BBFS_FILE_BUFFER
    SET PUSH, [B+BBFS_FILE_DRIVE] ; Arg 3: Drive to read from
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ; TODO: handle drive errors
    ADD SP, 3
    
    ; Load the number of words available to read in the sector. We'll point A to
    ; the new sector's FAT entry.
    ; Find the FS header
    SET A, [B+BBFS_FILE_FILESYSTEM_HEADER]
    ; And the FAT in it
    ADD A, BBFS_HEADER_FAT
    ; And the entry for this sector in the FAT
    ADD A, [B+BBFS_FILE_SECTOR]
    
    ; Load out the value
    SET A, [A]
    
    IFL A, 0x8000
        ; The high bit is unset, so this sector is not the last and is
        ; guaranteed to be full
        SET A, BBFS_WORDS_PER_SECTOR
    
    AND A, 0x7FFF ; Take everything but the high bit
    ; And say that that's the current file length within this sector.
    SET [B+BBFS_FILE_MAX_OFFSET], A 
    
.no_reload:
    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_A:
    ; Return the error in A
    SET [Z], A
    SET PC, .return
    
.error_space:
    ; Return the out of space error
    SET [Z], BBFS_ERR_DISC_FULL

.return:
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_truncate(*file)
; Truncate the file to end at the current position. Returns an error code.
; [Z]: BBFS_FILE to truncate
; Returns: error code in [Z]
bbfs_file_truncate:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; File struct
    SET PUSH, B ; Header struct
    SET PUSH, C ; Current sector number
    SET PUSH, X ; Scratch
    
    ; Load the file struct address
    SET A, [Z]
    ; Load the filesystem header address
    SET B, [A+BBFS_FILE_FILESYSTEM_HEADER]
    ; Load the current sector
    SET C, [A+BBFS_FILE_SECTOR]
    
.loop:
    ; Get the next sector from the FAT
    SET X, B
    ADD X, BBFS_HEADER_FAT
    ADD X, C
    IFG [X], 0x7FFF
        ; We're already the last sector
        SET PC, .done
    
    ; Move to that sector and clear out the link from this one.
    SET C, [X]
    SET [X], 0xFFFF
    
    ; Mark that sector as free
    SET PUSH, B
    SET PUSH, C
    JSR bbfs_header_free_sector
    ADD SP, 2
    
    ; Keep going until we've freed the sector that already pointed to 0xFFFF at
    ; the end of the file.
    SET PC, .loop
    
.done:
    ; Fix up the last sector to be unused, not just partially filled (0xFFFF)
    SET [X], 0xFFFF
    
    ; Set the file's max offset to its current offset
    SET [A+BBFS_FILE_MAX_OFFSET], [A+BBFS_FILE_OFFSET]
    
    ; This is now the last sector, so update the FAT for it to note the number
    ; of words used.
    SET X, B
    ADD X, BBFS_HEADER_FAT
    ADD X, [A+BBFS_FILE_SECTOR]
    SET [X], [A+BBFS_FILE_MAX_OFFSET] ; Put in the word count
    BOR [X], 0x8000 ; Set the high bit to mark this as the last sector

    ; Commit the changes to disk
    SET PUSH, [A+BBFS_FILE_DRIVE]
    SET PUSH, B
    JSR bbfs_drive_save
    ADD SP, 2

    SET [Z], BBFS_ERR_NONE
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_delete(*file)
; Delete the given open file.
; [Z]: BBFS_FILE struct
; Returns: error code in [Z]
bbfs_file_delete:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; File struct
    SET PUSH, B ; FAT addressing scratch
    
    SET A, [Z] ; Load up the file struct
    
    ; Fake seek to the first sector
    SET [A+BBFS_FILE_SECTOR], [A+BBFS_FILE_START_SECTOR]
    ; Call truncate to free most of the file. TODO: just start the chain routine
    ; with freeing the first sector instead.
    SET PUSH, A
    JSR bbfs_file_truncate
    SET [Z], POP
    IFN [Z], BBFS_ERR_NONE
        ; Return the error it threw
        SET PC, .return
        
    ; Now set the FAT on the last sector to 0xFFFF (for unused)
    SET B, [A+BBFS_FILE_FILESYSTEM_HEADER]
    ADD B, BBFS_HEADER_FAT
    ADD B, [A+BBFS_FILE_SECTOR]
    SET [B], 0xFFFF
    
        
    ; Now free the last sector in the bitmap
    SET PUSH, [A+BBFS_FILE_FILESYSTEM_HEADER]
    SET PUSH, [A+BBFS_FILE_START_SECTOR]
    JSR bbfs_header_free_sector
    ADD SP, 2
    
    ; Save FS header to the drive
    SET PUSH, [A+BBFS_FILE_DRIVE]
    SET PUSH, [A+BBFS_FILE_FILESYSTEM_HEADER]
    JSR bbfs_drive_save
    ADD SP, 2

    ; Now we're done    
    SET [Z], BBFS_ERR_NONE
.return:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
    
    
    















