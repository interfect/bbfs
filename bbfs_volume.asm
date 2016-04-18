; bbfs_volume.asm
; Filesystem header level functions

; bbfs_volume_open(volume*, device*)
;   Set up a new volume backed by the given device. May or may not be formatted
;   yet. Returns an error code, which will be BBFS_ERROR_UNFORMATTED if the
;   volume isn't formatted yet..
; [Z+1]: BBFS_VOLUME to operate on
; [Z]: BBFS_DEVICE that the volume is on
; Returns: error code in [Z]
bbfs_volume_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Pointer to the volume
    SET PUSH, B ; Pointer to the device
    SET PUSH, C ; Math scratch
    SET PUSH, X ; More math scratch
    SET PUSH, Y ; Sector size
    
    SET A, [Z+1]
    SET B, [Z]

    ; Make the array
    SET PUSH, A ; Arg 1: array to open
    ADD [SP], BBFS_VOLUME_ARRAY
    SET PUSH, B ; Arg 2: device
    SET PUSH, BBFS_START_SECTOR ; Arg 3: base sector
    JSR bbfs_array_open
    ADD SP, 3
    
    ; Work out where the freemask should start
    ; TODO: it is always ion the same place...
    SET C, BBFS_HEADER_FREEMASK
    SET [A+BBFS_VOLUME_FREEMASK_START], C
    
    ; And where the FAT begins (AKA past-the-end of the freemask)
    ; Get total sectors
    SET PUSH, B ; Arg 1: device
    JSR bbfs_device_sector_count
    SET X, POP
    ; Divide by 16 to a word
    SET C, X
    DIV C, 16
    SET [A+BBFS_VOLUME_FAT_START], C
    SET C, X
    MOD C, 16
    IFG C, 0
        ; Count a partial last word
        ADD [A+BBFS_VOLUME_FAT_START], 1
    ; Put it after where the freemask started
    ADD [A+BBFS_VOLUME_FAT_START], [A+BBFS_VOLUME_FREEMASK_START]
    
    ; Get the sector size
    SET PUSH, B ; Arg 1: device
    JSR bbfs_device_sector_size
    SET Y, POP
    
    ; How long will the FAT be? Total number of sectors.
    ADD X, [A+BBFS_VOLUME_FAT_START]
    ; Now X is the past-the-end word of the FAT
    SET C, X
    DIV C, Y ; How many sectors is that?
    
    ; Add in the boot record
    ADD C, BBFS_START_SECTOR
    
    MOD X, Y
    IFG X, 0
        ; Use a partial sector if needed
        ADD C, 1
        
    ; Save the number of the first usable sector
    SET [A+BBFS_VOLUME_FIRST_USABLE_SECTOR], C
    
    ; OK now go and actually look at the drive
    SET PUSH, A ; Arg 1: array
    ADD [SP], BBFS_VOLUME_ARRAY
    SET PUSH, BBFS_HEADER_VERSION ; Arg 2: index to look at
    JSR bbfs_array_get
    SET C, POP ; Value
    SET X, POP ; Error code
    
    IFN X, BBFS_ERR_NONE
        ; We couldn't talk to the drive
        SET PC, .error_x
        
    IFN C, BBFS_VERSION
        ; This doesn't look like a formatted disk
        SET [Z], BBFS_ERR_UNFORMATTED
        
    SET PC, .return
    
.error_x:
    SET [Z], X
.return:
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

; bbfs_volume_format(volume*)
;   Format the given volume with an empty BBFS filesystem. Returns an error
;   code.
; [Z+1]: BBFS_VOLUME to operate on
; Returns: error code in [Z]
bbfs_volume_format:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Pointer to the volume
    SET PUSH, B ; Pointer to the array
    SET PUSH, C ; Math scratch
    SET PUSH, I ; Loop index
    SET PUSH, J ; Sector countdown
    
    SET A, [Z] ; Get the volume
    
    ; Get the array
    SET B, A
    ADD B, BBFS_VOLUME_ARRAY
    
    ; Write the version
    SET PUSH, B ; Arg 1: array
    SET PUSH, BBFS_HEADER_VERSION ; Arg 2: offset in array
    SET PUSH, BBFS_VERSION ; Arg 3: value to write
    JSR bbfs_array_set
    SET C, POP
    ADD SP, 2
    
    ; Check return code
    IFN C, BBFS_ERR_NONE
        SET PC, .error_c
        
    ; Zero out all the reserved words
    SET I, BBFS_HEADER_VERSION
    ADD I, 1
    
.reserved_loop:
    SET PUSH, B ; Arg 1: array
    SET PUSH, I ; Arg 2: offset in array
    SET PUSH, 0 ; Arg 3: value to write
    JSR bbfs_array_set
    SET C, POP
    ADD SP, 2
    IFN C, BBFS_ERR_NONE
        SET PC, .error_c
        
    ADD I, 1
    IFN I, [A+BBFS_VOLUME_FREEMASK_START]
        ; Loop until we hit where the freemask starts
        SET PC, .reserved_loop
        
    ; OK now we do the freemask. We'll fill it with 0xFFFF now and go back and
    ; fix the low reserved sectors later.
.freemask_loop:
    SET PUSH, B ; Arg 1: array
    SET PUSH, I ; Arg 2: offset in array
    SET PUSH, 0xFFFF ; Arg 3: value to write
    JSR bbfs_array_set
    SET C, POP
    ADD SP, 2
    IFN C, BBFS_ERR_NONE
        SET PC, .error_c
        
    ADD I, 1
    IFN I, [A+BBFS_VOLUME_FAT_START]
        ; Loop until we hit the FAT
        SET PC, .freemask_loop
        
    ; Get the number of sectors we have to do
    SET PUSH, [A+BBFS_VOLUME_ARRAY+BBFS_ARRAY_DEVICE] ; Arg 1: device. TODO: expose through a call on the array?
    JSR bbfs_device_sector_count
    SET J, POP
        
.fat_loop:
    ; All the FAT enties also get 0xFFFF for unallocated.
    SET PUSH, B ; Arg 1: array
    SET PUSH, I ; Arg 2: offset in array
    SET PUSH, 0xFFFF ; Arg 3: value to write
    JSR bbfs_array_set
    SET C, POP
    ADD SP, 2
    IFN C, BBFS_ERR_NONE
        SET PC, .error_c
        
    ADD I, 1
    SUB J, 1
    
    IFN J, 0
        ; Loop until we do all the sectors
        SET PC, .fat_loop
    
    ; Now reserve sectors that aren't usable
    SET J, 0
.allocate_loop:
    ; Allocate each sector
    SET PUSH, A ; Arg 1: volume
    SET PUSH, J ; Arg 2: sector
    JSR bbfs_volume_allocate_sector
    SET C, POP
    ADD SP, 1
    
    IFN C, BBFS_ERR_NONE
        SET PC, .error_c
        
    ADD J, 1
    IFN J, [A+BBFS_VOLUME_FIRST_USABLE_SECTOR]
        SET PC, .allocate_loop
        
    ; Once we're here we've allocated all the reserved sectors at the beginning.
        
.error_c:
    SET [Z], C
.return:   
    SET J, POP
    SET I, POP 
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

; bbfs_volume_allocate_sector(volume*, sector_num)
;   Mark the given sector as allocated in the bitmap. Returns error code.
; [Z+1]: BBFS_VOLUME to work on
; [Z]: sector number to mark used in the FAT
; Returns: error code in [Z]
bbfs_volume_allocate_sector:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; Bitmask for setting
    SET PUSH, B ; Bit offset in its word, also word to work on
    SET PUSH, C ; Word the bit appears in
    SET PUSH, X ; BBFS_VOLUME this pointer
    
    ; Grab the volume
    SET X, [Z+1]
    
    ; Where is the relevant word
    SET C, [Z]
    DIV C, 16
    ; Use that as an offset into the free bitmask in the array
    ADD C, [X+BBFS_VOLUME_FREEMASK_START]
    
    ; What bit in the word do we want?
    SET B, [Z]
    MOD B, 16
    
    ; Make the mask
    SET A, 1
    SHL A, B
    XOR A, 0xffff ; Flip every bit in the mask    

    ; Load the word to edit
    SET PUSH, X ; Arg 1: array
    ADD [SP], BBFS_VOLUME_ARRAY
    SET PUSH, C ; Arg 2: word to get
    JSR bbfs_array_get
    SET B, POP ; Collect the word
    IFN [SP], BBFS_ERR_NONE
        SET PC, .error_stack
    ADD SP, 1

    AND B, A ; Keep all the bits except the target one
    
    ; Now put the word back
    SET PUSH, X ; Arg 1: array
    ADD [SP], BBFS_VOLUME_ARRAY
    SET PUSH, C ; Arg 2: word to set
    SET PUSH, B ; Arg 3: new value
    JSR bbfs_array_set
    SET [Z], POP ; Just return this error code
    ADD SP, 2
    
    SET PC, .return
    
.error_stack:
    ; Error is on the stack. Pop it.
    SET [Z], POP
.return:
    ; Return
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP

; bbfs_volume_free_sector(volume*, sector_num)
;   Mark the given sector as free in the bitmap. Returns error code.

; bbfs_volume_find_free_sector(volume*)
;   Return the first free sector on the disk, or 0xFFFF if no sector is free.

; bbfs_volume_fat_set(volume*, sector_num, value)
;   Set the FAT entry for the given sector to the given value (either next
;   sector number if high bit is off, or words used in sector if high bit is
;   on). Returns an error code.

; bbfs_volume_fat_get(volume*, sector_num)
;   Get the FAT entry for the given sector to the given value (either next
;   sector number if high bit is off, or words used in sector if high bit is
;   on). Returns FAT entry, and an error code.

; bbfs_volume_get_device(volume*)
;   Method to pull the device out of the volume, for syncing.

; Nothing here syncs. All syncing needs to be done on the underlying device.

