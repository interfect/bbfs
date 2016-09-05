; hello.asm: loadable program that the shell can run
; To use:
; Build into a bare assembled binary
; Pretend it's a disk image and load it into your emulator
; Image it to a file in BBFS
; load it with the LOAD command

.org 0

#include "bbos.inc.asm"
define WRITE_STRING 0x1004

SET PUSH, str_hello
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

; Return to the shell if applicable
IFN SP, 0x0000
    SET PC, POP
    
str_hello:
    .asciiz "Hello from a loadable binary!"
    

; Terminate with at least a sector of zeroes so the imager knows to stop imaging
.RESERVE 1024
