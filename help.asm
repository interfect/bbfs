; help.asm: help command for the shell
; To install:
; Build into a bare assembled binary
; Pretend it's a disk image and load it into your emulator
; Image it to a file in BBFS
; load it with the LOAD command

; TODO: need a way to make the build system dump this into a BBFS image, or to
; automate those actions.

.org 0

#include "bbos.inc.asm"
define WRITE_STRING 0x1004

SET PUSH, str_help00
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

SET PUSH, str_help01
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

SET PUSH, str_help02
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

SET PUSH, str_help03
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

SET PUSH, str_help04
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

SET PUSH, str_help05
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

SET PUSH, str_help06
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

SET PUSH, str_help07
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

SET PUSH, str_help08
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

SET PUSH, str_help09
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

SET PUSH, str_help10
SET PUSH, 1 ; With newline
SET A, WRITE_STRING
INT BBOS_IRQ_MAGIC
ADD SP, 2

; Return to the shell if applicable
IFN SP, 0x0000
    SET PC, POP
    
str_help00: .asciiz "DC-DOS is a disk operating      "
str_help01: .asciiz "system for DCPU16-based systems."
str_help02: .asciiz "                                "
str_help03: .asciiz "Builtins: DIR COPY DEL IMAGE VER"
str_help04: .asciiz "LOAD FORMAT                     "
str_help05: .asciiz "                                "
str_help06: .asciiz "Additional commands can be      "
str_help07: .asciiz "loaded from .IMG files on disk. "
str_help08: .asciiz "Images are loaded at address 0. "
str_help09: .asciiz "Use 'image B file.img' to image "
str_help10: .asciiz "the disk in drive B for loading."

; Terminate with at least a sector of zeroes so the imager knows to stop imaging
.RESERVE 1024
