; Bootloader with just enough BBFS code to load a file.

; We don't need to read the free bitmap or anything. All we need to do is follow
; FAT entries for the directory and for the actual boot file.

; Keeps itself at a fixed address, so there's a limit to the amount of code it
; can load.

; New and exciting bootloader plan:
; Grab the sector size to a global
; Have a simple FAT get function based on that
; Just use BBOS to load whole sectors
; Just load the whole root directory into RAM at address 0
; Scan it for the right filename
; Just load that into RAM at address 0
; Run it


#include "bbos.inc.asm"
#include "bbfs.inc.asm"

; Consele API that we need
; Write Char              0x1003  Char, MoveCursor        None            1.0
; Write String            0x1004  StringZ, NewLine        None            1.0
define WRITE_CHAR 0x1003
define WRITE_STRING 0x1004

define BOOTLOADER_BASE 0xd000

; We statically allocate a directory, a direntry, and a file, but don't include
; them in our image. We can't use labels in the defines; they all act like 0.
; Instead we just place it safely one sector after the fixed bootloader address.

; We need the BBOS drive info (DRIVE_SECT_SIZE and DRIVE_SECT_COUNT are members)
define STATIC_DRIVEPARAM_BL BOOTLOADER_BASE+BBFS_MAX_SECTOR_SIZE
; We need a sector cache for reading the FAT
define STATIC_FAT_CACHE_BL BOOTLOADER_BASE+BBFS_MAX_SECTOR_SIZE+DRIVEPARAM_SIZE
; A FAT start sector
define STATIC_FAT_SECTOR_BL BOOTLOADER_BASE+BBFS_MAX_SECTOR_SIZE+DRIVEPARAM_SIZE+BBFS_MAX_SECTOR_SIZE+1
; And offset in that sector
define STATIC_FAT_OFFSET_BL BOOTLOADER_BASE+BBFS_MAX_SECTOR_SIZE+DRIVEPARAM_SIZE+BBFS_MAX_SECTOR_SIZE+1+1
; And the sector at which the root directory starts
define STATIC_ROOT_BL BOOTLOADER_BASE+BBFS_MAX_SECTOR_SIZE+DRIVEPARAM_SIZE+BBFS_MAX_SECTOR_SIZE+1+1+1
; TODO: why can't these base on eachother???

; This code starts at 0 and is just smart enough to copy the rest to the bootloader base address.
.org 0

; Save the drive to load off of
SET PUSH, A
SET A, payload_measure_end_bl-payload_measure_start_bl ; How many words to copy
SET I, copy_end_bl ; Source
SET J, BOOTLOADER_BASE ; Destination
copy_loop_bl:
    SUB A, 1
    STI [J], [I]
    IFN A, 0
        SET PC, copy_loop_bl

; Jump into the bootloader code proper
SET PC, BOOTLOADER_BASE

copy_end_bl:

; This code all happens at the bootloader base address. We set all the labels to
; think they're there, but don't actually sort the sections in the assembler.
.org BOOTLOADER_BASE

payload_measure_start_bl:

; Actual bootloader code begins here.
; On the stack we have our BBOS drive to load from.
; Save that in B
SET B, POP

; Announce ourselves
SET PUSH, str_intro_bl
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2
SET PUSH, str_copyright_bl
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

; Get drive info into globals
; Make the BBOS call to get device info
SET PUSH, STATIC_DRIVEPARAM_BL ; Arg 1: drive info to populate
SET PUSH, B ; Arg 2: device number
SET A, GET_DRIVE_PARAMETERS
INT BBOS_IRQ_MAGIC
ADD SP, 2

; Determine FAT start sector and start offset
; First work out its word offset in Y
    
; It comes after the freemask, which starts here
SET Y, BBFS_HEADER_FREEMASK
    
; Find where the FAT begins (AKA past-the-end of the freemask)
; Get total sectors
SET X, [STATIC_DRIVEPARAM_BL+DRIVE_SECT_COUNT]
; Divide by 16 to a word
SET C, X
DIV C, 16

; Add in all the full words
ADD Y, C
SET C, X
MOD C, 16
IFG C, 0
    ; Count a partial last word
    ADD Y, 1
    
; Say the FAT starts in the sector where this word lands
SET [STATIC_FAT_SECTOR_BL], Y
DIV [STATIC_FAT_SECTOR_BL], [STATIC_DRIVEPARAM_BL+DRIVE_SECT_SIZE]
; But after the BBFS start sector
ADD [STATIC_FAT_SECTOR_BL], BBFS_START_SECTOR

; And say it starts at the offset that this word has
SET [STATIC_FAT_OFFSET_BL], Y
MOD [STATIC_FAT_OFFSET_BL], [STATIC_DRIVEPARAM_BL+DRIVE_SECT_SIZE]

; We still have total sectors in X. We need a FAT entry for each sector
ADD Y, X
; Now Y is the past-the-end word of the FAT
SET C, Y
DIV C, [STATIC_DRIVEPARAM_BL+DRIVE_SECT_SIZE] ; How many sectors is that?
    
MOD Y, [STATIC_DRIVEPARAM_BL+DRIVE_SECT_SIZE]
IFG Y, 0
    ; Use a partial sector if needed
    ADD C, 1
    
; Add in the boot record
ADD C, BBFS_START_SECTOR

; Save the sector after the FAT (where the root directory lives) in a global
SET [STATIC_ROOT_BL], C

; Read root directory file to address 0

SET PUSH, [STATIC_ROOT_BL]
JSR read_to_address_0_bl
ADD SP, 1

; Scan for boot.img
; Use A to index child in the directory
SET A, 0

scan_loop_bl:
; If we use up all the children, complain
IFE A, [BBFS_DIRHEADER_CHILD_COUNT]
    SET PC, not_found_bl

; Compare filename of this entry and correct packed filename
SET PUSH, A ; Arg 1: pointer to packed filename
MUL [SP], BBFS_DIRENTRY_SIZEOF
ADD [SP], BBFS_DIRHEADER_SIZEOF+BBFS_DIRENTRY_NAME ; Need to offset by name in entry and by header before entries
SET PUSH, packed_filename_bl ; Arg 2: other packed filename
JSR bbfs_filename_compare_bl
SET C, POP
ADD SP, 1

; We have a match!
IFE C, 1
    SET PC, found_bl


; Look at the next entry
ADD A, 1
SET PC, scan_loop_bl

found_bl:
; If found, read it to address 0
; First calculate the memory location of the start sector for this file
MUL A, BBFS_DIRENTRY_SIZEOF
ADD A, BBFS_DIRHEADER_SIZEOF+BBFS_DIRENTRY_SECTOR

; Read all from that sector into memory
SET PUSH, [A] ; Arg 1: sector to start at
JSR read_to_address_0_bl
ADD SP, 1

; Actually execute the loaded code
; Make sure to pass drive in A
SET A, B
SET PC, 0

not_found_bl:
; We didn't find the boot image
SET PUSH, str_not_found_bl
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

halt_bl:
    SET PC, halt_bl
    
;; FUNCTIONS

; get_fat_bl(sector)
; Get the FAT entry for the given sector. Drive is read from B, which remains
; untouched.
; [Z]: Sector to read
; Returns: FAT entry in [Z]
get_fat_bl:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2
    
    SET PUSH, A ; BBOS Scratch
    
    ; Read FAT into buffer
    ; TODO: don't do this every time
    SET PUSH, [Z] ; Arg 1: Sector to read. We need to find the sector this sector in the FAT ends up being
    ADD [SP], [STATIC_FAT_OFFSET_BL]
    
    DIV [SP], [STATIC_DRIVEPARAM_BL+DRIVE_SECT_SIZE]
    ADD [SP], [STATIC_FAT_SECTOR_BL]
    
    SET PUSH, STATIC_FAT_CACHE_BL ; Arg 2: Pointer to read to
    
    SET PUSH, B ; Arg 3: drive
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ADD SP, 3
    
    ; Now grab the word in the FAT
    SET A, [Z]
    ADD A, [STATIC_FAT_OFFSET_BL]
    MOD A, [STATIC_DRIVEPARAM_BL+DRIVE_SECT_SIZE]
    SET [Z], [A+STATIC_FAT_CACHE_BL]
    
    ; Return
    SET A, POP
    SET Z, POP
    SET PC, POP


; read_to_address_0_bl(start_sector)
; Read the whole file starting at the given sector into memory, starting at
; address 0. Drive is read from B, which remains untouched.
; [Z]: sector number to start at
; Returns: nothing, but clobbers Z by incrementing
read_to_address_0_bl:
    ; Set up frame pointer
    SET PUSH, Z
    SET Z, SP
    ADD Z, 2

    SET PUSH, A ; BBOS scratch
    SET PUSH, C ; Place to write to
    
    SET C, 0
    
.loop:
    ; Read a sector
    SET PUSH, [Z] ; Arg 1: Sector to read
    SET PUSH, C ; Arg 2: pointer to read to
    SET PUSH, B ; Arg 3: drive
    SET A, READ_DRIVE_SECTOR
    INT BBOS_IRQ_MAGIC
    ADD SP, 3
    
    ; Check the FAT for this sector
    SET PUSH, [Z]
    JSR get_fat_bl
    SET [Z], POP
    
    ; If the high bit is set, this was the last sector, so stop.
    IFG [Z], 0x7FFF
        SET PC, .done
        
    ; Next time write after the sector we just loaded
    ADD C, [STATIC_DRIVEPARAM_BL+DRIVE_SECT_SIZE]
    
    ; Keep going with the next sector
    SET PC, .loop
    
    ; We loaded all the sectors
.done:
    SET C, POP
    SET A, POP
    SET Z, POP
    SET PC, POP
    
; bbfs_filename_compare_bl(*packed1, *packed2)
; Return 1 if the packed filenames match, 0 otherwise.
; Performs case-insensitive comparison
; [Z+1]: Filename 1
; [Z]: Filename 2
; Return: 1 for match or 0 for mismatch in [Z]
bbfs_filename_compare_bl:
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

;; CONSTANTS
    

str_not_found_bl:
    .asciiz "BOOT.IMG not found"
str_found_bl:
    .asciiz "Loading BOOT.IMG"
str_intro_bl:
    .asciiz "UBM Bootloader 3.0"
str_copyright_bl:
    .asciiz "(C) UBM"
str_error_bl:
    .asciiz "Error"
packed_filename_bl:
    ; Packed version of the "BOOT.IMG" filename. 8 words is less than the unpack
    ; routine.
    DAT 0x424f
    DAT 0x4f54
    DAT 0x2e49
    DAT 0x4d47
    DAT 0x0000
    DAT 0x0000
    DAT 0x0000
    
payload_measure_end_bl:

