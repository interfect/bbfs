# BBFS
BBFS is a filesystem specification and implementation for virtual computers.

The targeted computers are DCPU-based systems running [BBOS](https://github.com/MadMockers/BareBonesOS), and having either M35FD floppy drives or M525HD hard disks.

# About BBFS

BBFS stands for "Bootable Bfs512 File System". The filesystem is a more-or-less straight reimplementation of [bfs512](https://github.com/Blecki/DCPUB/blob/master/Binaries/techcompliant/bfs512.b) from the [DCPUB project](https://github.com/Blecki/DCPUB). Originally it differed from bfs512 by supporting a boot sector at sector 0; however, bfs512 added a boot sector and now the two implementations are compatible on M35FD disks.

# DC-DOS Shell

This repository contains a simple shell, in `shell.asm`, which supports formatting BBFS volumes and creating, deleting, and accessing files on them. The shell can load and execute a file, allowing you to keep your programs as files on disk and run them on demand.

Executables are stored in `.IMG` files, which are loaded at address 0 and executed from there. On execution, the A register holds the BBOS drive number from which the program was loaded, as it does when BBOS loads a bootloader or when the bootloader loads `BOOT.IMG`. The stack is preserved, so if the loaded program does not corrupt the shell's code (which lives at 0xA000 and above), it can `SET PC, POP` to return control back to the shell.

This binary foirmat has been designed for maximum compatibility; it can load programs which don't know anything about the shell, BBFS, or even BBOS, as long as they are designed to execute from address 0 (and as long as they can re-map VRAM from where BBOS keeps it, if applicable). Unfortunately, it does not yet support command-line argument passing.

# Bootloaders

This repository includes a bootloader, `bbfs_bootloader.asm`, which (when given the appropriate magic word at the end of its sector) can be loaded by BBOS form the first sector of a disk, and can in turn load and boot `BOOT.IMG` off of its BBFS-formated disk.

The repository also includes a test/example program, `bbfs_test.asm`, which can be put onto a bootable unformatted disk with MadMockers' `build_bootable_floppy` program, and which will format its own disk with BBFS, save itself to `BOOT.IMG`, and install this bootloader on the disk. The net result is that the first time you boot the disk it will load the test program with MadMockers` bootloader, and on subsequent runs the same program will be loaded by the BBFS bootloader.

# BBFS Design

The design of BBFS is mostly documented in `bbfs.asm`, which gives layouts for all major data structures.

Here is the basic structure of a BBFS M535FD disk:
```
; Disk structure:
;
; --------------+-------------------------------+
; Sector 0      | Bootloader                    |
; --------------+------------+------------------+
; Sector 1      | FS header  | Version          |
;               |            | (1 word)         |
;               |            +------------------+
;               |            | Reserved         |
;               |            | (5 words)        |
;               +------------+------------------+
;               | Free mask                     |
;               | (90 words, 1=free)            |
;               +------------+------------------+
;               | File       | First 416        |
;               | Allocation | FAT words        |
; --------------+ Table      +------------------+
; Sector 2      |            | Next 512         |
;               | (1440      | FAT words        |
; --------------+  words)    +------------------+
; Sector 3      |            | Last 512         |
;               |            | FAT words        |
; --------------+------------+------------------+
; Sector 4      | First sector of file for root |
;               | directory (stored as a file)  |
; --------------+-------------------------------+
; Remaining sectors: file data
```

The File Allocation Table (FAT) connects all the sectors that make up a file, by pointing from each sector to the sector that comes after it in the file. In this way, a single sector number (for the file's first sector) can define an entire file on disk.

Since a file may not incluse all of its last sector, the last entry in the FAT for a file has the high bit set (to indicate that it is the last entry), while the remaining bits give the number of used words in that sector.


# BBFS API

All API functions are called using the same calling convention as BBOS calls: push the arguments to the stack, first argument first, call the function, and then remove all the arguments you pushed from the stack. If a return value is supplied, it overwrites the final argument (so it can be popped first). Some functions have multiple return values, which are popped in order.

The API is devided into levels:

* Level 0: `bbfs_device.asm`: Device functions, implementing a sector-level cache on top of BBOS drives.

* Level 1: `bbfs_array.asm`: The disk-backed word array used to implement the FAT, free bitmap, and filesystem header.

* Level 2: `bbfs_volume.asm`: Functions for working with a volume's FAT, free bitmap and filesystem header.

* Level 3: `bbfs_files.asm`: File functions (read and write, seek and reopen, truncate, create, open, and delete)

* Level 4: `bbfs_directories.asm`: Directory functions (create, open, get next entry, remove entry at index)

Each layer is implemented on top of the layer below it. In particular,
directories are just files that store the names and defining sector numbers of
other files.


