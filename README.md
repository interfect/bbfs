# BBFS
BBFS is a filesystem specification and implementation for virtual computers.

The targeted computers are DCPU-based systems running [BBOS](https://github.com/MadMockers/BareBonesOS).

# About BBFS

BBFS stands for "Bootable Bfs512 File System". The filesystem is a more-or-less straight reimplementation of [bfs512](https://github.com/Blecki/DCPUB/blob/master/Binaries/bfs512.dc) from the [DCPUB project](https://github.com/Blecki/DCPUB), but with all the filesystem tables shifted down on the disk by one sector, to make room for a bootloader at sector 0.

# Bootloaders

This repository includes a bootloader, `bbfs_bootloader.asm`, which (when given the appropriate magic word at the end of its sector) can be loaded by BBOS form the first sector of a disk, and can in turn load and boot `BOOT.IMG` off of its BBFS-formated disk.

The repository also includes a test/example program, `bbfs_test.asm`, which can be put onto a bootable unformatted disk with MadMockers' `build_bootable_floppy` program, and which will format its own disk with BBFS, save itself to `BOOT.IMG`, and install this bootloader on the disk. The net result is that the first time you boot the disk it will load the test program with MadMockers` bootloader, and on subsequent runs the same program will be loaded by the BBFS bootloader.

# BBFS Design

The design of BBFS is mostly documented in `bbfs.asm`, which gives layouts for all major data structures and descriptions of all the API functions.

Here is the basic structure of a BBFS disk:
```
; Disk structure:
;
; --------------+-------------------------------+
; Sector 0      | Bootloader                    |
; --------------+------------+------------------+
; Sector 1      | FS header  | Version          |
;               |            | (1 word, 0xBF56) |
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

All API functions are called using the same calling convention as BBOS calls: push the arguments to the stack, first argument first, call the function, and then remove all the arguments you pushed from the stack. If a return value is supplied, it overwrites the final argument (so it can be popped first).

The API is devided into levels:

* Level 0: Filesystem header functions (read and write FAT, allocate sectors, format a disk)

* Level 1: File functions (read and write, seek and reopen, truncate, create, open, and delete)

* Level 2: Directory functions (create, open, get next entry, remove entry at index)

Each layer is implemented on top of the layer below it. In particular,
directories are just files that store the names and defining sector numbers of
other files.


