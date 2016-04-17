; bbfs_volume.asm
; Filesystem header level functions

; bbfs_volume_open(volume*, device*)
;   Set up a new volume backed by the given device. May or may not be formatted
;   yet. Returns an error code, which will be BBFS_ERROR_UNFORMATTED if the
;   volume isn't formatted yet.

; bbfs_volume_format(volume*)
;   Format the given volume with an empty BBFS filesystem. Returns an error code.

; bbfs_volume_allocate_sector(volume*, sector_num)
;   Mark the given sector as allocated in the bitmap

; bbfs_volume_free_sector(volume*, sector_num)
;   Mark the given sector as free in the bitmap

; bbfs_volume_find_free_sector(volume*)
;   Return the first free sector on the disk, or 0xFFFF if no sector is free.

; bbfs_volume_fat_set(volume*, sector_num, value)
;   Set the FAT entry for the given sector to the given value (either next
;   sector number if high bit is off, or words used in sector if high bit is
;   on). Returns an error code.

; bbfs_volume_fat_get(volume*, sector_num)
;   Get the FAT entry for the given sector to the given value (either next
;   sector number if high bit is off, or words used in sector if high bit is
;   on). Returns FAT entry, and an error code.

; bbfs_volume_get_device(volume*)
;   Method to pull the device out of the volume, for syncing.

; Nothing here syncs. All syncing needs to be done on the underlying device.

