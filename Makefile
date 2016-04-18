all: bbfs_test.dsk shell.dsk bbfs2_test.dsk

%.dsk: %.bin
	build_bootable_floppy $< $@

bbfs_test.bin: bbfs_test.asm bbfs.asm bbfs_header.asm bbfs_files.asm bbfs_directories.asm bbfs_bootloader.asm 
	dasm $< $@

shell.bin: shell.asm bbfs.asm bbfs_header.asm bbfs_files.asm bbfs_directories.asm
	dasm $< $@
	
bbfs2_test.bin: bbfs2_test.asm bbfs.asm bbfs_device.asm bbfs_array.asm bbfs_volume.asm
	dasm $< $@

