#!/bin/sh
# Build an EFI system disk: a FAT volume with one application on it.
#
# EFI firmware looks for /EFI/BOOT/BOOTAA64.EFI on a FAT filesystem and runs
# it. There is no partition table here - "-layout NONE" gives a bare volume,
# which the framework's firmware accepts and which is one fewer thing to get
# wrong than a GPT with an EFI system partition in it.
set -e
APP="$1"
OUT="$2"
WORK="${OUT%.img}"
rm -f "$WORK.dmg" "$OUT"
hdiutil create -size 48m -fs "MS-DOS FAT32" -volname EFI -layout NONE \
    -type UDIF -o "$WORK" >/dev/null
DEV=$(hdiutil attach -nomount "$WORK.dmg" | head -1 | awk '{print $1}')
MNT=$(mktemp -d)
diskutil mount -mountPoint "$MNT" "$DEV" >/dev/null
mkdir -p "$MNT/EFI/BOOT"
cp "$APP" "$MNT/EFI/BOOT/BOOTAA64.EFI"
diskutil unmount "$MNT" >/dev/null
hdiutil detach "$DEV" >/dev/null
mv "$WORK.dmg" "$OUT"
echo "mkesp: $OUT carries $(basename "$APP")"
