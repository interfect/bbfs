#!/usr/bin/env bash

# splice.sh: splice the newest bootloader onto a .dsk. Handles the problem that the new BL may not be padded to the right size.

set -e

SOURCE_DSK="formatted.dsk"
SOURCE_BL="bootloader.bin"
TEMP_DSK="temp.dsk"
DEST_DSK="spliced.dsk"

BL_SIZE="$(stat ${SOURCE_BL} | cut -f8 -d' ')"

# Start with the bootloader
cat "${SOURCE_BL}" > "${TEMP_DSK}"

while [[ "${BL_SIZE}" -lt "1022" ]]; do

    # Pad with 0s
    printf '\0' >> "${TEMP_DSK}"
    (( BL_SIZE=BL_SIZE+1 ))

done

# Add 0x55AA (AKA 85, 170, AKA octal 125, 252)
# This is the magic bootable marker
printf '\125\252' >> ${TEMP_DSK}

cat "${SOURCE_DSK}" | tail -b +3 >> "${TEMP_DSK}"

mv "${TEMP_DSK}" "${DEST_DSK}"


