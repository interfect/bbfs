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
;   Format the given volume with an empty BBFS filesystem. Returns an error code.

; bbfs_volume_allocate_sector(volume*, sector_num)
;   Mark the given sector as allocated in the bitmap

; bbfs_volume_free_sector(volume*, sector_num)
;   Mark the given sector as free in the bitmap

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

