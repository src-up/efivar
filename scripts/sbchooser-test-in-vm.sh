#!/usr/bin/env bash
# Run inside a RHEL 9/10 VM that has UEFI db/dbx (e.g. launched with launch-with-uefi preset)
# and optionally nightly repos configured. Installs sbchooser, gathers two shims, runs sbchooser.

EFIVAR_REPO="${EFIVAR_REPO:-$HOME/efivar}"
SHIM_EXISTING="/tmp/shim-existing.efi"
SHIM_NEW="/tmp/shim-new.efi"
SHIM_ESP="/boot/efi/EFI/redhat/shimx64.efi"

echo "=== Step 1: Install build deps ==="
sudo dnf install -y gcc make openssl-devel
if [ $? -ne 0 ]; then
	echo "ERROR: dnf install failed"
	exit 1
fi

echo "=== Step 2: Clone and build sbchooser ==="
if [ ! -d "$EFIVAR_REPO" ]; then
	git clone --branch sbchooser https://github.com/vathpela/efivar.git "$EFIVAR_REPO"
	if [ $? -ne 0 ]; then
		echo "ERROR: git clone failed"
		exit 1
	fi
fi
cd "$EFIVAR_REPO" || exit 1

make ENABLE_DOCS=0
if [ $? -ne 0 ]; then
	echo "ERROR: make failed"
	exit 1
fi

sudo make install ENABLE_DOCS=0
if [ $? -ne 0 ]; then
	echo "ERROR: make install failed"
	exit 1
fi

echo "=== Step 3: Copy current shim to $SHIM_EXISTING ==="
if [ ! -f "$SHIM_ESP" ]; then
	echo "ERROR: $SHIM_ESP not found"
	exit 1
fi
sudo cp "$SHIM_ESP" "$SHIM_EXISTING"
if [ $? -ne 0 ]; then
	echo "ERROR: copy existing shim failed"
	exit 1
fi

echo "=== Step 4: Get nightly shim to $SHIM_NEW ==="
dnf download -y shim-x64
if [ $? -ne 0 ]; then
	echo "ERROR: dnf download shim-x64 failed (enable nightly repos and/or tunnel if required)"
	exit 1
fi
RPM=$(ls -t shim-x64-*.rpm 2>/dev/null | head -1)
if [ -z "$RPM" ] || [ ! -f "$RPM" ]; then
	echo "ERROR: no shim-x64 rpm found after download"
	exit 1
fi

EXTRACT_DIR=$(mktemp -d)
rpm2cpio "$RPM" | (cd "$EXTRACT_DIR" && cpio -idmv -q)
if [ $? -ne 0 ]; then
	echo "ERROR: rpm2cpio/cpio failed"
	rm -rf "$EXTRACT_DIR"
	exit 1
fi

NEW_EFI=$(find "$EXTRACT_DIR" -name 'shimx64.efi' -o -name 'shim*.efi' 2>/dev/null | head -1)
if [ -z "$NEW_EFI" ] || [ ! -f "$NEW_EFI" ]; then
	echo "ERROR: no shim efi found in rpm"
	rm -rf "$EXTRACT_DIR"
	exit 1
fi
sudo cp "$NEW_EFI" "$SHIM_NEW"
rm -rf "$EXTRACT_DIR"
if [ $? -ne 0 ]; then
	echo "ERROR: copy new shim failed"
	exit 1
fi

echo "=== Step 5: Run sbchooser ==="
if [ ! -f "$SHIM_EXISTING" ] || [ ! -f "$SHIM_NEW" ]; then
	echo "ERROR: one or both shims missing"
	exit 1
fi
sudo sbchooser -s -S --explain -i "$SHIM_NEW" -i "$SHIM_EXISTING"
exit $?
