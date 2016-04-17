; bbfs_device.asm
; Sector cache level functions

; bbfs_device_open(device*, drive_num)
; bbfs_device_sync(device*) (doubles as close) (returns error)
; bbfs_device_sector_size(device*) (returns sector size in words)
; bbfs_device_sector_count(device*) (returns sector count on the device)
; bbfs_device_get(device*, word sector) (returns a pointer to a sector)



; bbfs_device_open(device*, drive_num)
; Initialize a BBFS_DEVICE to cache sectors from the given drive.
; [Z+1]: BBFS_DEVICE to operate on
; [Z]: BBOS drive number to point the device at
bbfs_device_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS scratch, and struct pointer
    
    ; Make the BBOS call to get device info
    SET PUSH, [Z+1] ; Arg 1: drive info to populate
    ADD [SP], BBFS_DEVICE_DRIVEINFO
    SET PUSH, [Z] ; Arg 2: device number
    SET A, GET_DRIVE_PARAMETERS
    INT BBOS_IRQ_MAGIC
    ADD SP, 2
    
    SET A, [Z+1] ; Grab the device pointer
    SET [A+BBFS_DEVICE_DRIVE], [Z] ; Save the drive number
    SET [A+BBFS_DEVICE_SECTOR], BBFS_MAX_SECTOR_COUNT ; Say no sector is currently cached    

    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_device_sync(device*)
; Save cached sectors back. Also basically close.
; [Z]: BBFS_DEVICE to operate on
; Returns: error code in [Z]
bbfs_device_sync:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A

    SET A, [Z] ; Grab the device pointer
    
    IFE [A+BBFS_DEVICE_SECTOR], BBFS_MAX_SECTOR_COUNT
        ; Nothing to save!
        SET PC, .skipped    
    
    ; Otherwise we need to save the sector

    SET PUSH, [A+BBFS_DEVICE_SECTOR] ; Arg 1: Sector to write
    SET PUSH, A ; Arg 2: Pointer to write from
    ADD [SP], BBFS_DEVICE_BUFFER 
    SET PUSH, [A+BBFS_DEVICE_DRIVE] ; Arg 3: drive number
    SET A, WRITE_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    
    ; Handle error return
    IFE [SP], 0
        SET [Z], BBFS_ERR_DRIVE
    IFE [SP], 1
        SET [Z], BBFS_ERR_NONE
        
    ; Clean up stack
    ADD SP, 3
    SET PC, .done
    
.skipped:
    SET [Z], BBFS_ERR_NONE
.done:
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_device_sector_size(device*)
; Return the sector size of the device, in words.
; [Z]: BBFS_DEVICE to operate on
; Returns: sector size in [Z]
bbfs_device_sector_size:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A

    SET A, [Z] ; Grab the device pointer
    
    ; Go get the sector size
    SET [Z], [A+BBFS_DEVICE_DRIVEINFO+DRIVE_SECT_SIZE]
    
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_device_sector_count(device*)
; Return the sector count of the device (total sectors).
; [Z]: BBFS_DEVICE to operate on
; Returns: sector count in [Z]
bbfs_device_sector_count:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A

    SET A, [Z] ; Grab the device pointer
    
    ; Go get the sector size
    SET [Z], [A+BBFS_DEVICE_DRIVEINFO+DRIVE_SECT_COUNT]
    
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_device_get(device*, word sector)
; Get a pointer to a loaded copy of the given sector.
; [Z+1]: BBFS_DEVICE to operate on
; [Z]: sector number to get
; Returns: sector pointer in [Z], or 0x0000 on error
bbfs_device_get:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS calls
    SET PUSH, B ; Device struct

    SET B, [Z+1] ; Grab the device pointer
    
    IFE [B+BBFS_DEVICE_SECTOR], [Z]
        ; Already loaded!
        SET PC, .skip_load    
    
    IFE [B+BBFS_DEVICE_SECTOR], BBFS_MAX_SECTOR_COUNT
        ; Nothing to save!
        SET PC, .skip_save    
    
    ; Otherwise we need to save the sector

    SET PUSH, [B+BBFS_DEVICE_SECTOR] ; Arg 1: Sector to write
    SET PUSH, B ; Arg 2: Pointer to write from
    ADD [SP], BBFS_DEVICE_BUFFER 
    SET PUSH, [B+BBFS_DEVICE_DRIVE] ; Arg 3: drive number
    SET A, WRITE_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    
    ; Handle error return
    IFE [SP], 1
        SET PC, .save_success
    ADD SP, 3
    SET PC, .error
.save_success:
    ; Clean up stack
    ADD SP, 3
    
.skip_save:
    ; Now we saved the existing sector (or don't need to), so load the new one
    
    SET PUSH, [Z] ; Arg 1: Sector to read
    SET PUSH, B ; Arg 2: Pointer to read to
    ADD [SP], BBFS_DEVICE_BUFFER 
    SET PUSH, [B+BBFS_DEVICE_DRIVE] ; Arg 3: drive number
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    
    ; Handle error return
    IFE [SP], 1
        SET PC, .load_success
    ; Otherwise we failed
    ADD SP, 3
    SET PC, .error
.load_success:
    ; Clean up stack
    ADD SP, 3
    
    ; Say we loaded the right thing
    SET [B+BBFS_DEVICE_SECTOR], [Z]
    
.skip_load:
    ; Point the return value at the buffer we loaded into.
    ADD B, BBFS_DEVICE_BUFFER
    SET [Z], B
    SET PC, .done
.error:
    SET [Z], 0x0000
.done:
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    


   
