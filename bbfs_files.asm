; bbfs_files.asm
; File-level BBFS function implementations.

; bbfs_file_create(*file, *volume)
; Create a file in a new free sector and populate the file handle.
; [Z+1]: BBFS_FILE to populate
; [Z]: BBFS_VOLUME to put the file on
; Returns: error code in [Z]
bbfs_file_create:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Holds the file struct address
    SET PUSH, B ; Error scratch
    
    ; Grab the file struct
    SET A, [Z+1]
    
    ; Fill in the volume
    SET [A+BBFS_FILE_VOLUME], [Z]
    
    ; Find a free sector and fill in both sector values.
    ; TODO: may be 0xFFFF if disk is full
    SET PUSH, [Z] ; Arg 1 - BBFS_VOLUME to search
    JSR bbfs_volume_find_free_sector
    SET [A+BBFS_FILE_START_SECTOR], POP
    SET [A+BBFS_FILE_SECTOR], [A+BBFS_FILE_START_SECTOR]
    
    ; Make sure we actually got back a sector
    IFE [A+BBFS_FILE_START_SECTOR], 0xFFFF
        SET PC, .error
    
    ; Mark the sector allocated
    SET PUSH, [Z] ; Arg 1 - BBFS_VOLUME to update
    SET PUSH, [A+BBFS_FILE_START_SECTOR] ; Arg 2 - Sector to mark allocated
    JSR bbfs_volume_allocate_sector
    SET B, POP
    ADD SP, 1
    
    IFN B, BBFS_ERR_NONE
        SET PC, .error_b
    
    ; Fill in the offset for starting at the beginning of the sector
    SET [A+BBFS_FILE_OFFSET], 0
    ; Say no words are in the file yet.
    SET [A+BBFS_FILE_MAX_OFFSET], 0
    
    ; Flush the file to commit its zero size
    ; TODO: roll this into allocate sector
    SET PUSH, A
    JSR bbfs_file_flush
    SET [Z], POP
    
    ; Return the error code of the flush, since we were otherwise successful
    
    SET PC, .return
    
.error:
    ; The generic error we can have is a full disk
    SET [Z], BBFS_ERR_DISK_FULL
    SET PC, .return
.error_b:
    SET [Z], B
.return:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_open(*file, *volume, drive_num, sector_num)
; Open an existing file at the given sector on the given drive, and populate the
; file handle.
; [Z+2]: BBFS_FILE to populate
; [Z+1]: BBFS_VOLUME to use
; [Z]: Sector at which the file starts
; Returns: error code in [Z]
bbfs_file_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Holds the file struct address
    SET PUSH, B ; Scratch for FAT interrogation
    SET PUSH, C ; Device, words per sector
    
    ; Grab the file struct
    SET A, [Z+2]

    ; Populate the file struct
    ; Fill in the volume address
    SET [A+BBFS_FILE_VOLUME], [Z+1]
    ; And the sector indexes
    SET [A+BBFS_FILE_START_SECTOR], [Z]
    SET [A+BBFS_FILE_SECTOR], [Z]
    ; And zero the offset
    SET [A+BBFS_FILE_OFFSET], 0
    
    ; Load the number of words available to read in the sector, which we get
    ; from the FAT.
    SET PUSH, [Z+1] ; Arg 1: volume
    SET PUSH, [Z] ; Arg 2: sector number
    JSR bbfs_volume_fat_get
    SET B, POP
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
    
    IFL B, 0x8000
        ; The high bit is unset, so this first sector is not also the last and
        ; is guaranteed to be full
        SET PC, .sector_is_full
    SET PC, .sector_not_full
.sector_is_full:
    ; The sector is full, but how many words is that?
    SET PUSH, [A+BBFS_FILE_VOLUME] ; Arg 1: volume to get device for
    JSR bbfs_volume_get_device
    SET C, POP
    
    SET PUSH, C ; Arg 1: device to get sector size for
    JSR bbfs_device_sector_size
    SET B, POP ; Our words remaining is the words per sector of the device
    
.sector_not_full:
    AND B, 0x7FFF ; Take everything but the high bit
    ; And say that that's the current file length within this sector.
    SET [A+BBFS_FILE_MAX_OFFSET], B 
    
    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_stack:
    SET [Z], POP
.return:
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_reopen(*file)
; Reset back to the beginning of the file. Returns an error code.
; [Z]: BBFS_FILE to reopen
; Returns: error code in [Z]
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
    
    ; If we changed sectors back to the first sector, this means there was a
    ; following sector and the first sector is thus full.
    SET PUSH, [B+BBFS_FILE_VOLUME]
    JSR bbfs_volume_get_device
    JSR bbfs_device_sector_size ; Just leave the device on the stack
    SET [B+BBFS_FILE_MAX_OFFSET], POP
    
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
; code. After flushing, no close operation is necessary.
; [Z]: BBFS_FILE to flush
; Returns: error code in [Z]
bbfs_file_flush:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; FAT word value, scratch/error code
    SET PUSH, B ; BBFS_FILE struct addressing
    SET PUSH, C ; words per sector for this device
    SET PUSH, X ; Old FAT word

    SET B, [Z] ; Load the address of the file struct
    
    SET PUSH, [B+BBFS_FILE_VOLUME]
    JSR bbfs_volume_get_device
    JSR bbfs_device_sector_size ; Just leave the device on the stack
    SET C, POP
    
    ; Now we have to sync to the FAT. We want to save the file size if we're the
    ; last sector in the file. Otherwise we want to leave the FAT alone.
    
    ; Load what was in the FAT
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1 - volume
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2 - sector
    JSR bbfs_volume_fat_get
    SET X, POP ; Old FAT word
    SET A, POP ; Error code
    
    IFN A, BBFS_ERR_NONE
        SET PC, .error_a
        
    ; If we aren't tracking this sector's length, we don't want to touch the FAT
    IFL X, 0x8000
        SET PC, .skip_fat
    
    ; Save the number of words
    SET A, [B+BBFS_FILE_MAX_OFFSET]
    ; Set the high bit to mark it a last sector
    BOR A, 0x8000
    
    ; Save it in the FAT
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1 - volume
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2 - sector
    SET PUSH, A ; Arg 3 - new FAT value
    JSR bbfs_volume_fat_set
    SET A, POP
    ADD SP, 2
    
    IFN A, BBFS_ERR_NONE
        SET PC, .error_a
    
.skip_fat:
    
    ; Sync the underlying device
    
    ; First get the device
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume
    JSR bbfs_volume_get_device
    SET A, POP
    
    SET PUSH, A ; Arg 1: device
    JSR bbfs_device_sync
    SET [Z], POP ; Return the error code we get from that
    
    SET PC, .return
    
.error_a:
    SET [Z], A
.return:
    SET X, POP
    SET C, POP
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

    SET PUSH, A ; Scratch, next sector
    SET PUSH, B ; File struct address
    SET PUSH, C ; Filesystem device address
    SET PUSH, I ; Pointer into buffered sector
    SET PUSH, J ; Pointer into data
    SET PUSH, X ; Scratch
    SET PUSH, Y ; Words per sector
    
    ; We're going to decrement [Z] as we write words until it's 0
    
    ; Load the file struct address
    SET B, [Z+2]
    
    ; And the device address
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume to get device for
    JSR bbfs_volume_get_device
    SET C, POP
    
    ; And the sector size on the device
    SET PUSH, C ; Arg 1: device
    JSR bbfs_device_sector_size
    SET Y, POP
    
    ; Grab the sector we're supposed to be writing to
    SET PUSH, C ; Arg 1: device
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector we want
    JSR bbfs_device_get
    SET I, POP
    ADD SP, 1
    
    IFE I, 0x0000
        ; Couldn't get the sector
        SET PC, .error_drive
    
    ; Point I at the word in the file buffer to write to
    ADD I, [B+BBFS_FILE_OFFSET]
    ; Point J at the data word to read
    SET J, [Z+1]
    
.write_until_full:
    IFE [Z], 0 ; No more words to write
        SET PC, .done_writing
    IFE [B+BBFS_FILE_OFFSET], Y
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
    
    ; This will get committed to the FAT when we sync/close the file, if we
    ; don't go beyond this sector before doing so.
    
    ; Loop around
    SET PC, .write_until_full
    
.go_to_next_sector:

    ; If we already have a next sector allocated, go to that one
    ; Look in the FAT at the current sector
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector
    JSR bbfs_volume_fat_get
    SET A, POP
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
    
    IFG A, 0x7FFF
        ; If the high bit is set, this was the last sector
        ; Allocate a new sector
        SET PC, .allocate_sector
    
.sector_available:
    ; Now A holds the next sector, which is allocated and atatched to our file
    
    ; Point the file at the start of the new sector
    SET [B+BBFS_FILE_SECTOR], A
    SET [B+BBFS_FILE_OFFSET], 0
    
    ; Load the number of words available to read in the sector. We'll set A to
    ; the new sector's FAT entry.
    ; Find the FS volume
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector
    JSR bbfs_volume_fat_get
    SET A, POP
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
    
    IFL A, 0x8000
        ; The high bit is unset, so this sector is not the last and is
        ; guaranteed to be full. Use the sector size we grabbed earlier.
        SET A, Y
    
    AND A, 0x7FFF ; Take everything but the high bit
    ; And say that that's the current file length within this sector.
    SET [B+BBFS_FILE_MAX_OFFSET], A 
    
    ; Point I at a buffer for this sector
    SET PUSH, C ; Arg 1: device
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector we want
    JSR bbfs_device_get
    SET I, POP
    ADD SP, 1

    IFE I, 0x0000
        ; Couldn't get the sector
        SET PC, .error_drive

    ; Keep writing
    SET PC, .write_until_full
    
.allocate_sector:
    ; We need to fill in A with a new sector
    
    ; Find a free sector and save it there
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1 - BBFS_VOLUME to find a sector in
    JSR bbfs_volume_find_free_sector
    SET X, POP
    
    IFE X, 0xFFFF
        ; No free sector was available
        SET PC, .error_space
    ; Else we got a sector, point to it
    
    ; Otherwise we got a free one.
    SET A, X
    
    ; Point to it in the FAT
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume to change the FAT in
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector to set FAT of (current)
    SET PUSH, A ; Arg 3: new FAT value (new sector to point to)
    JSR bbfs_volume_fat_set
    SET X, POP
    ADD SP, 2
    IFN X, BBFS_ERR_NONE
        SET PC, .error_x
        
    ; Allocate it
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1 - BBFS_VOLUME to update
    SET PUSH, A ; Arg 2 - Sector to mark allocated
    JSR bbfs_volume_allocate_sector
    SET X, POP
    ADD SP, 1
    IFN X, BBFS_ERR_NONE
        SET PC, .error_x
    
    
    ; Say it has no words used in its FAT entry.
    ; Set the high bit (sector is last in file), but leave the words used count
    ; as 0. This will then get loaded into the file max offset when the sector
    ; is loaded above.
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume to change the FAT in
    SET PUSH, A ; Arg 2: sector to set FAT of (new)
    SET PUSH, 0x8000 ; Arg 3: new FAT value (no words used/high bit set)
    JSR bbfs_volume_fat_set
    SET X, POP
    ADD SP, 2
    IFN X, BBFS_ERR_NONE
        SET PC, .error_x
    
    ; Go back to reading this next sector (A) from the file
    SET PC, .sector_available
    
.done_writing:
    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_A:
    ; Return the error in A
    SET [Z], A
    SET PC, .return
    
.error_x:
    ; Return the error in X
    SET [Z], X
    SET PC, .return
    
.error_stack:
    ; Return the error on the stack
    SET [Z], POP
    SET PC, .return
    
.error_space:
    ; Return the out of space error
    SET [Z], BBFS_ERR_DISK_FULL
    SET PC, .return
    
.error_drive:
    ; Couldn't get a sector pointer
    SET [Z], BBFS_ERR_DRIVE

.return:
    SET Y, POP
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
; Returns: error code in [Z], words successfully read in [Z+1]
bbfs_file_read:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS calls, scratch
    SET PUSH, B ; File struct address
    SET PUSH, C ; Filesystem device struct address
    SET PUSH, I ; Pointer into file buffer
    SET PUSH, J ; Pointer into data
    SET PUSH, X ; Words successfully read
    SET PUSH, Y ; Words per sector
    
    ; We're going to decrement [Z] as we read words until it's 0
    
    ; We also increment X
    SET X, 0
    
    ; Load the file struct address
    SET B, [Z+2]
    ; And the FS volume struct address
    SET C, [B+BBFS_FILE_VOLUME]
    
    ; And the device address
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume to get device for
    JSR bbfs_volume_get_device
    SET C, POP
    
    ; And the sector size on the device
    SET PUSH, C ; Arg 1: device
    JSR bbfs_device_sector_size
    SET Y, POP
    
    ; Grab the sector we're supposed to be reading
    SET PUSH, C ; Arg 1: device
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector we want
    JSR bbfs_device_get
    SET I, POP
    ADD SP, 1
    
    IFE I, 0x0000
        ; Couldn't get the sector
        SET PC, .error_drive

    ; Point I at the word in the file buffer to read from
    ADD I, [B+BBFS_FILE_OFFSET]
    
    ; Point J at the data word to write
    SET J, [Z+1]
    
.read_until_depleted:
    IFE [Z], 0 ; No more words to read
        SET PC, .done_reading
    IFE [B+BBFS_FILE_OFFSET], Y
        ; We've used up our buffered sector
        SET PC, .go_to_next_sector
    IFE [B+BBFS_FILE_OFFSET], [B+BBFS_FILE_MAX_OFFSET]
        ; Our max offset isn't a full sector and we've depleted it.
        ; We know this has to be the last sector, so just say EOF.
        SET PC, .error_end_of_file
    
    ; Otherwise read a word from the buffer, and move both pointers
    STI [J], [I]
    ; Consume one word from our to-do list
    SUB [Z], 1
    ; And one word of this sector
    ADD [B+BBFS_FILE_OFFSET], 1
    ; Record that we successfully read a word
    ADD X, 1
    
    ; Loop around
    SET PC, .read_until_depleted
    
.go_to_next_sector:

    ; If we already have a next sector allocated, go to that one
    ; Look in the FAT at the current sector
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector
    JSR bbfs_volume_fat_get
    SET A, POP
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
   
    IFG A, 0x7FFF
        ; If the high bit is set, this was the last sector
        ; Maybe we filled it.
        SET PC, .error_end_of_file

    ; Now A holds the next sector
    ; Point the file at the start of the new sector
    SET [B+BBFS_FILE_SECTOR], A
    SET [B+BBFS_FILE_OFFSET], 0
    
    ; Load the number of words available to read in the sector from its FAT
    ; entry. We need to do this first because otherwise it would touch the
    ; device and invalidate the sector pointer.
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector
    JSR bbfs_volume_fat_get
    SET A, POP
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
    
    IFL A, 0x8000
        ; The high bit is unset, so this sector is not the last and is
        ; guaranteed to be full
        SET A, Y
    
    AND A, 0x7FFF ; Take everything but the high bit
    ; And say that that's the current file length within this sector.
    SET [B+BBFS_FILE_MAX_OFFSET], A 
    
    ; Load the sector from disk
    SET PUSH, C ; Arg 1: device
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector we want
    JSR bbfs_device_get
    SET I, POP
    ADD SP, 1
    
    IFE I, 0x0000
        ; Couldn't get the sector
        SET PC, .error_drive
    
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
 
.error_stack:
    ; Return error on the stack
    SET [Z], POP
    SET PC, .return    
        
.error_drive:
    ; Couldn't get a sector pointer
    SET [Z], BBFS_ERR_DRIVE

.return:
    SET [Z+1], X ; Return words successfully read (before any error)
    SET Y, POP
    SET X, POP
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
    SET PUSH, C ; Filesystem device address
    SET PUSH, X ; FAT scratch
    SET PUSH, Y ; FS sector size
    
    ; We're going to decrement [Z] as we skip until it's 0
    
    ; Load the file struct address
    SET B, [Z+1]
    ; And the FS volume struct address
    SET C, [B+BBFS_FILE_VOLUME]
    
    ; And the device address
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume to get device for
    JSR bbfs_volume_get_device
    SET C, POP
    
    ; And the sector size on the device
    SET PUSH, C ; Arg 1: device
    JSR bbfs_device_sector_size
    SET Y, POP
    
.skip_until_done:
    IFE [Z], 0 ; No more words to skip
        SET PC, .done_skipping
    IFG [Z], Y
        ; We want to skip a whole sector or more
        SET PC, .go_to_next_sector
    SET A, [Z]
    ADD A, [B+BBFS_FILE_OFFSET]
    IFG A, Y
        ; We want to skip an amount that would put us in the next sector
        SET PC, .go_to_next_sector
    
    ; Otherwise we just need to adjust our position in this sector
    ADD [B+BBFS_FILE_OFFSET], [Z]
    SET [Z], 0
    
    IFG [B+BBFS_FILE_OFFSET], [B+BBFS_FILE_MAX_OFFSET]
        ; We need to extend this sector's used words
        SET [B+BBFS_FILE_MAX_OFFSET], [B+BBFS_FILE_OFFSET]
        
    ; This will get committed to the FAT when we sync/close the file, if we
    ; don't go beyond this sector before doing so.
    
    ; Loop around
    SET PC, .skip_until_done
    
.go_to_next_sector:

    ; First, account for all the words we're skipping: all the ones left in the sector.
    SUB [Z], Y ; A whole sector
    ADD [Z], [B+BBFS_FILE_OFFSET] ; Except what we had already passed

    ; If we already have a next sector allocated, go to that one
    ; Look in the FAT at the current sector
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector
    JSR bbfs_volume_fat_get
    SET A, POP
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
    
    IFG A, 0x7FFF
        ; If the high bit is set, this was the last sector
        ; Allocate a new sector
        SET PC, .allocate_sector
    
.sector_available:
    ; Now A holds the next sector, which is allocated and atatched to our file
    
    ; Point the file at the start of the new sector
    SET [B+BBFS_FILE_SECTOR], A
    SET [B+BBFS_FILE_OFFSET], 0
    
    ; Load the number of words available to read in the sector. We'll set A to
    ; the new sector's FAT entry.
    ; Find the FS volume
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector
    JSR bbfs_volume_fat_get
    SET A, POP
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
    
    IFL A, 0x8000
        ; The high bit is unset, so this sector is not the last and is
        ; guaranteed to be full. Use the sector size we grabbed earlier.
        SET A, Y
    
    AND A, 0x7FFF ; Take everything but the high bit
    ; And say that that's the current file length within this sector.
    SET [B+BBFS_FILE_MAX_OFFSET], A 
    
    ; Keep seeking
    SET PC, .skip_until_done
    
.allocate_sector:
    ; We need to fill in A with a new sector
    
    ; Find a free sector and save it there
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1 - BBFS_VOLUME to find a sector in
    JSR bbfs_volume_find_free_sector
    SET X, POP
    
    IFE X, 0xFFFF
        ; No free sector was available
        SET PC, .error_space
    ; Else we got a sector, point to it
    
    ; Otherwise we got a free one.
    SET A, X
    
    ; Point to it in the FAT
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume to change the FAT in
    SET PUSH, [B+BBFS_FILE_SECTOR] ; Arg 2: sector to set FAT of (current)
    SET PUSH, A ; Arg 3: new FAT value (new sector to point to)
    JSR bbfs_volume_fat_set
    SET X, POP
    ADD SP, 2
    IFN X, BBFS_ERR_NONE
        SET PC, .error_x
    
    ; Allocate it
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1 - BBFS_VOLUME to update
    SET PUSH, A ; Arg 2 - Sector to mark allocated
    JSR bbfs_volume_allocate_sector
    SET X, POP
    ADD SP, 1
    IFN X, BBFS_ERR_NONE
        SET PC, .error_x
    
    
    ; Say it has no words used in its FAT entry.
    ; Set the high bit (sector is last in file), but leave the words used count
    ; as 0. This will then get loaded into the file max offset when the sector
    ; is loaded above.
    SET PUSH, [B+BBFS_FILE_VOLUME] ; Arg 1: volume to change the FAT in
    SET PUSH, A ; Arg 2: sector to set FAT of (new)
    SET PUSH, 0x8000 ; Arg 3: new FAT value (no words used/high bit set)
    JSR bbfs_volume_fat_set
    SET X, POP
    ADD SP, 2
    IFN X, BBFS_ERR_NONE
        SET PC, .error_x
    
    ; Go back to seeking through this next sector (A)
    SET PC, .sector_available
    
.done_skipping:
    ; Return success
    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_A:
    ; Return the error in A
    SET [Z], A
    SET PC, .return
    
.error_x:
    ; Return the error in x
    SET [Z], X
    SET PC, .return
    
.error_stack:
    ; Return the error from the stack
    SET [Z], POP
    SET PC, .return
    
.error_space:
    ; Return the out of space error
    SET [Z], BBFS_ERR_DISK_FULL

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
    SET PUSH, B ; Volume struct
    SET PUSH, C ; Current sector number
    SET PUSH, X ; Scratch/next sector
    SET PUSH, Y ; Other scratch
    
    ; Load the file struct address
    SET A, [Z]
    ; Load the filesystem volume address
    SET B, [A+BBFS_FILE_VOLUME]
    ; Load the current sector
    SET C, [A+BBFS_FILE_SECTOR]
    
.loop:
    ; Get the next sector from the FAT
    
    SET PUSH, B ; Arg 1 - volume to work on
    SET PUSH, C ; Arg 2 - sector to look up
    JSR bbfs_volume_fat_get
    SET X, POP ; Stick the value in X
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1
    
    ; Clear out the link or size
    SET PUSH, B ; Arg 1 - volume to work on
    SET PUSH, C ; Arg 2 - sector to set
    SET PUSH, 0xFFFF ; Arg 3 - value to point it at (0xFFFF = sector is free)
    IFE C, [A+BBFS_FILE_SECTOR]
        ; If this is the first sector, actually just mark it as empty but used.
        ; Real word count will be filled in in the FAT when the file is synced.
        SET [SP], 0x8000
    JSR bbfs_volume_fat_set
    SET Y, POP
    ADD SP, 2
    IFN Y, BBFS_ERR_NONE
        SET PC, .error_y
        
    IFG X, 0x7FFF
        ; We're already the last sector
        SET PC, .done
    
    ; Move to that sector
    SET C, X
    
    ; Mark that sector as free in the bitmap
    SET PUSH, B ; Arg 1: volume to work on
    SET PUSH, C ; Arg 2: sector to free
    JSR bbfs_volume_free_sector
    SET Y, POP
    ADD SP, 1
    IFN Y, BBFS_ERR_NONE
        SET PC, .error_y
    
    ; Keep going until we've freed the sector that didn't point to another
    ; sector
    SET PC, .loop
    
.done:
    
    ; Set the file's max offset to its current offset
    SET [A+BBFS_FILE_MAX_OFFSET], [A+BBFS_FILE_OFFSET]
    
    ; This sector's FAT entry is already 0x8000 as if it was just allocated.
    ; Actual size will be filled in in FAT on flush.

    SET [Z], BBFS_ERR_NONE
    SET PC, .return
    
.error_stack:
    SET [Z], POP
    SET PC, .return
    
.error_y:
    SET [Z], Y
    SET PC, .return
    
.return:
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_file_delete(*file)
; Delete the given open file. File should not be flushed afterwards.
; [Z]: BBFS_FILE struct
; Returns: error code in [Z]
bbfs_file_delete:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; File struct
    SET PUSH, B ; FAT scratch
    
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
    SET PUSH, [A+BBFS_FILE_VOLUME] ; Arg 1 - volume to work on
    SET PUSH, [A+BBFS_FILE_START_SECTOR] ; Arg 2 - sector to set
    SET PUSH, 0xFFFF ; Arg 3 - value to point it at (0xFFFF = sector is free)
    JSR bbfs_volume_fat_set
    SET [Z], POP
    ADD SP, 2
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return
        
    ; Now free the last sector in the bitmap
    SET PUSH, [A+BBFS_FILE_VOLUME] ; Arg 1: volume to work on
    SET PUSH, [A+BBFS_FILE_START_SECTOR] ; Arg 2: sector to free
    JSR bbfs_volume_free_sector
    SET [Z], POP
    ADD SP, 1
    IFN [Z], BBFS_ERR_NONE
        SET PC, .return

    ; Now we're done    
    SET [Z], BBFS_ERR_NONE
.return:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
 
    
    















