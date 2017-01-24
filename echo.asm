; echo.asm: loadable program using the DC-DOS API
; To use:
; Build into a bare assembled binary
; Pretend it's a disk image and load it into your emulator
; Image it to a file in BBFS
; run it by typing its name, followed by arguments

.org 0

#include "bbos.inc.asm"
#include "dcdos_api.inc.asm"
define WRITE_STRING 0x1004

; Define a stack space for getting the argument string
SET PUSH, 0
SET A, DCDOS_ARGS_GET
INT DCDOS_IRQ_MAGIC
SET B, POP
; Keep the argument string in B


SET PUSH, B
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

; Return to the shell if applicable
IFN SP, 0x0000
    SET PC, POP

; Terminate with at least a sector of zeroes so the imager knows to stop imaging
.RESERVE 1024
