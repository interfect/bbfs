; bbfs_array.asm
; Disk-backed-array-level functions

; bbfs_array_open(array*, device*, sector): make a new array starting at the given sector on the given device
; bbfs_array_get(array*, offset): return the word at the given offset in the array, and an error code.
; bbfs_array_set(array*, offset, value): set the word at the given offset in the array. Returns an error code.

; Arrays can be destroyed without doing anything special as long as the device they use gets synced eventually.

; bbfs_array_open(array*, device*, sector)
; Initialize a BBFS_ARRAY starting at the given sector on the given drive
; [Z+2]: BBFS_ARRAY to operate on
; [Z+1]: BBFS_DEVICE backing the array
; [Z]: sector the array starts at
bbfs_array_open:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Array struct pointer
    
    SET A, [Z+2]
    SET [A+BBFS_ARRAY_DEVICE], [Z+1] ; Set the device
    SET [A+BBFS_ARRAY_START], [Z] ; And the start sector

    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_array_get(array*, offset)
; Get the value at the given offset in the given array
; [Z+1]: BBFS_ARRAY to operate on
; [Z]: word offset to get
; Returns: word value in [Z], error code in [Z+1]
bbfs_array_get:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Array struct pointer
    SET PUSH, B ; Sector to get, then sector pointer
    SET PUSH, C ; Sector offset
    
    SET PUSH, X ; Array's backing device
    SET PUSH, Y ; Sector size
    
    SET A, [Z+1] ; Get the array
    SET X, [A+BBFS_ARRAY_DEVICE] ; And its device
    
    ; Get the device's sector size
    SET PUSH, X ; Arg 1 - device
    JSR bbfs_device_sector_size
    SET Y, POP
    
    ; Divide offset by that to get the sector, and offset by start sector
    SET B, [Z]
    DIV B, Y
    ADD B, [A+BBFS_ARRAY_START]
    ; And mod offset to get the offset in the sector
    SET C, [Z]
    MOD C, Y
    
    ; Get a pointer to that sector
    SET PUSH, X ; Arg 1 - device
    SET PUSH, B ; Arg 2 - sector number
    JSR bbfs_device_get
    SET B, POP
    ADD SP, 1
    
    ; If it's 0 report an error
    IFE B, 0x0000
        SET PC, .error
    
    ; Find the word at this offset and return it
    ADD B, C
    SET [Z], [B]
    SET [Z+1], BBFS_ERR_NONE
    SET PC, .return

.error:
    ; TODO: all the errors are drive errors for now
    SET [Z+1], BBFS_ERR_DRIVE
    
.return:
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_array_set(array*, offset, value)
; Set the value at the given offset in the given array
; [Z+2]: BBFS_ARRAY to operate on
; [Z+1]: word offset to set
; [Z]: value to set it to
; Returns: error code in [Z]
bbfs_array_set:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; Array struct pointer
    SET PUSH, B ; Sector to edit, then sector pointer
    SET PUSH, C ; Sector offset
    
    SET PUSH, X ; Array's backing device
    SET PUSH, Y ; Sector size
    
    SET A, [Z+2] ; Get the array
    SET X, [A+BBFS_ARRAY_DEVICE] ; And its device
    
    ; Get the device's sector size
    SET PUSH, X ; Arg 1 - device
    JSR bbfs_device_sector_size
    SET Y, POP
    
    ; Divide offset by that to get the sector, and offset by start sector
    SET B, [Z+1]
    DIV B, Y
    ADD B, [A+BBFS_ARRAY_START]
    ; And mod offset to get the offset in the sector
    SET C, [Z+1]
    MOD C, Y
    
    ; Get a pointer to that sector
    SET PUSH, X ; Arg 1 - device
    SET PUSH, B ; Arg 2 - sector number
    JSR bbfs_device_get
    SET B, POP
    ADD SP, 1
    
    ; If it's 0 report an error
    IFE B, 0x0000
        SET PC, .error
    
    ; Find the word at this offset and set it
    ADD B, C
    SET [B], [Z]
    SET [Z], BBFS_ERR_NONE
    SET PC, .return

.error:
    ; TODO: all the errors are drive errors for now
    SET [Z], BBFS_ERR_DRIVE
    
.return:
    SET Y, POP
    SET X, POP
    SET C, POP
    SET B, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
