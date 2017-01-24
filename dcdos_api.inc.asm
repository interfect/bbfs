; dcdos_api.inc.asm
; Include this file to get the DEFINEs necessary to write a DC-DOS application.

; To call a DCDOS function, push arguments in order to the stack, put the code
; in A, and interrupt with DCDOS_IRQ_MAGIC (just like with BBOS). The caller has
; to pop the arguments back off the stack; returned values overwrite arguments,
; so that the first return value is the first thign popped off the stack.
define DCDOS_IRQ_MAGIC 0xDCD0

; Filesystem operations operate on a BBFS_FILE type, which is 5 words:
;
; +-------------------+
; | Volume            |
; +-------------------+
; | Start Sector      |
; +-------------------+
; | Current Sector    |
; +-------------------+
; | Current Offset    |
; +-------------------+
; | Max Sector Offset |
; +-------------------+
;
; Generally client applications will allocate this themselves.

; Filesystem operations generally return error codes.
;
;ERROR TABLE
;==============
;Name                   Value       Meaning
;-------------------------------------------------------------------------------
; ERR_NONE              0x0000      No error; operation succeeded
; ERR_DRIVE             0x0005      Drive returned an error
; ERR_DISK_FULL         0x0007      Disk is full
; ERR_EOF               0x0008      End of file reached
; ERR_UNKNOWN           0x0009      An unknown error has occurred
; ERR_UNFORMATTED       0x000A      Disk is not BBFS-formatted
; ERR_NOTDIR            0x1001      Directory file wasn't a directory
; ERR_NOTFOUND          0x1002      No file at given sector/name 
; ERR_INVALID           0x1003      Name or other parameters invalid

;FUNCTION TABLE
;==============
;Name                  A       Args                         Returns
;-------------------------------------------------------------------------------
;-- Applications
; DCDOS_HANDLER_GET     0x0001  OUT handler_addr            handler_addr
; DCDOS_ARGS_GET        0x0001  OUT *args                   *args
;
;-- High-level filesystem functions:
; DCDOS_SHELL_OPEN      0x1000  *file, *filename, create    error
;
;-- Files
; DCDOS_FILE_READ       0x2001  *file, *data, size          error, words read
; DCDOS_FILE_WRITE      0x2002  *file, *data, size          error
; DCDOS_FILE_FLUSH      0x2003  *file                       error
; DCDOS_FILE_REOPEN     0x2004  *file                       error
; DCDOS_FILE_SEEK       0x2005  *file, distance             error
; DCDOS_FILE_TRUNCATE   0x2006  *file                       error

define DCDOS_HANDLER_GET   0x0000
; DCDOS_HANDLER_GET()
; Get the address of the DC-DOS interrupt handler. If you replace the system
; interrupt handler, all DC-DOS and BBOS interrupts should be sent to this
; address with a "SET PC, handler_addr" in your interrupt handler.
; handler_addr: must be pushed onto the stack to make room for the return value
; Returns: address to forward DC-DOS and BBOS interrupts to
define DCDOS_ARGS_GET   0x0001
; DCDOS_ARGS_GET()
; Get the command line used to call the application as a string.
; *args: must be pushed onto the stack to make room for the return value
; Returns: Pointer to a null-terminated string containing the entire command
; line, minus the program name and first space.
define DCDOS_SHELL_OPEN 0x1000
; DCDOS_SHELL_OPEN(*file, *filename, create)
; Populate the given file by opening the given filename. Get drive
; from filename if possible.
; *file: BBFS_FILE to populate. May be completely uninitialized.
; *filename: File name buffer, null terminated. May have a leading drive like
; A: or A:\. May be modified.
; create: Flag for whether to create the file if it does not exist.
; Returns: Error code
define DCDOS_FILE_READ 0x2001
; DCDOS_FILE_READ(*file, *data, size)
; Read the given number of words from the given file into the given buffer.
; *file: BBFS_FILE to read from
; *data: Buffer to read into
; size: Number of words to read
; Returns: error code, words successfully read
define DCDOS_FILE_WRITE 0x2002
; DCDOS_FILE_WRITE(*file, *data, size)
; Write the given number of words from the given address to the given file.
; *file: BBFS_FILE to write to
; *data: Address to get data from
; size: number of words to write
; Returns: error code
define DCDOS_FILE_FLUSH 0x2003
; DCDOS_FILE_FLUSH(*file)
; Flush the data in the currently buffered sector to disk. Returns an error
; code. After flushing, no close operation is necessary.
; *file: BBFS_FILE to flush
; Returns: error code
define DCDOS_FILE_REOPEN 0x2004
; DCDOS_FILE_REOPEN(*file)
; Reset back to the beginning of the file. Returns an error code.
; *file: BBFS_FILE to reopen
; Returns: error code
define DCDOS_FILE_SEEK 0x2005
; DCDOS_FILE_SEEK(*file, distance)
; Skip ahead the given number of words.
; *file: BBFS_FILE to skip in
; distance: Words to skip
; Returns: error code
define DCDOS_FILE_TRUNCATE 0x2006
; DCDOS_FILE_TRUNCATE(*file)
; Truncate the file to end at the current position. Returns an error code.
; *file: BBFS_FILE to truncate
; Returns: error code


