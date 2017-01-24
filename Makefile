all: bbfs_test.dsk shell.dsk bbfs2_test.dsk bootloader.bin hello.bin help.bin echo.bin

%.dsk: %.bin
	build_bootable_floppy $< $@

bbfs_test.bin: bbfs_test.asm bbfs.asm bbfs.inc.asm bbfs_device.asm bbfs_array.asm bbfs_volume.asm bbfs_files.asm bbfs_directories.asm bbfs_bootloader.asm 
	dasm $< $@

shell.bin: shell.asm bbfs.asm bbfs.inc.asm bbfs_device.asm bbfs_array.asm bbfs_volume.asm bbfs_files.asm bbfs_directories.asm bbfs_bootloader.asm dcdos_api.inc.asm
	dasm $< $@
	
bbfs2_test.bin: bbfs2_test.asm bbfs.asm bbfs.inc.asm bbfs_device.asm bbfs_array.asm bbfs_volume.asm bbfs_files.asm
	dasm $< $@
	
bootloader.bin: bbfs_bootloader.asm bbfs.inc.asm
	dasm $< $@

hello.bin: hello.asm dcdos_api.inc.asm
	dasm $< $@
	
help.bin: help.asm dcdos_api.inc.asm
	dasm $< $@
	
echo.bin: echo.asm dcdos_api.inc.asm
	dasm $< $@
