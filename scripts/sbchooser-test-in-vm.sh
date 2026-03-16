#!/usr/bin/env bash
# Run inside a RHEL 9/10 VM that has UEFI db/dbx (e.g. launched with launch-with-uefi preset)
# and optionally nightly repos configured. Installs sbchooser, gathers two shims, runs sbchooser.

EFIVAR_REPO="${EFIVAR_REPO:-$HOME/efivar}"
EFIVAR_REPO_URL="${EFIVAR_REPO_URL:-git@github.com:src-up/efivar.git}"
EFIVAR_BRANCH="${EFIVAR_BRANCH:-sbchooser-docs}"
# Comma-separated repos to disable for dnf download (e.g. codeready-builder-for-rhel-9-x86_64-rhui-rpms)
DNF_DISABLEREPO="${DNF_DISABLEREPO:-}"
SHIM_EXISTING="/tmp/shim-existing.efi"
SHIM_NEW="/tmp/shim-new.efi"
SHIM_ESP="/boot/efi/EFI/redhat/shimx64.efi"

# Prefix so script messages are distinct from command output (cyan)
echo_prefix=$'\033[36m[sbchooser-test]\033[0m'

# check_sign SHIM_PATH -> prints 2011, 2023, or dual (uses pesign + openssl)
check_sign() {
	local path="$1"
	local tmp_pk7="" issuers="" has_2011=0 has_2023=0 u=0
	command -v pesign >/dev/null 2>&1 || { echo "unknown"; return; }
	[ ! -f "$path" ] && { echo "unknown"; return; }
	while true; do
		tmp_pk7="/tmp/sbchooser_sig_$$_${u}.pk7"
		sudo rm -f "$tmp_pk7"
		if ! sudo pesign -i "$path" -u "$u" --export-signature "$tmp_pk7" 2>/dev/null; then
			sudo rm -f "$tmp_pk7"
			break
		fi
		sudo chmod 644 "$tmp_pk7" 2>/dev/null
		issuers=$(openssl pkcs7 -in "$tmp_pk7" -inform DER -print_certs -noout -text 2>/dev/null | grep -i issuer)
		echo "$issuers" | grep -q "UEFI CA 2011" && has_2011=1
		echo "$issuers" | grep -q "UEFI CA 2023" && has_2023=1
		sudo rm -f "$tmp_pk7"
		u=$((u + 1))
	done
	if [ "$has_2011" -eq 1 ] && [ "$has_2023" -eq 1 ]; then
		echo "dual"
	elif [ "$has_2011" -eq 1 ]; then
		echo "2011"
	elif [ "$has_2023" -eq 1 ]; then
		echo "2023"
	else
		echo "unknown"
	fi
}

# Table: SHIM_EXISTING (A) vs SHIM_NEW (B) -> Preferred (A, B, or Tie)
# Look up expected winner from (SIG_EXISTING, SIG_NEW)
get_expected_winner() {
	case "$SIG_EXISTING,$SIG_NEW" in
	2011,2011)   echo "Tie";;
	2011,2023)   echo "B";;
	2011,dual)   echo "B";;
	2023,2011)   echo "A";;
	2023,2023)   echo "Tie";;
	2023,dual)   echo "Tie";;
	dual,2011)   echo "A";;
	dual,2023)   echo "Tie";;
	dual,dual)   echo "Tie";;
	*)           echo "unknown";;
	esac
}

# Print preference table with matching row marked with <<< at end
print_table_with_match() {
	local a="$1" b="$2" c1 c2 c3 end=""
	echo "$echo_prefix +------------------+------------------+------------+-------+"
	echo "$echo_prefix | SHIM_EXISTING (A) | SHIM_NEW (B)     | Preferred |       |"
	echo "$echo_prefix +------------------+------------------+------------+-------+"
	for row in "2011|2011|Tie" "2011|2023|B" "2011|dual|B" "2023|2011|A" "2023|2023|Tie" "2023|dual|Tie" "dual|2011|A" "dual|2023|Tie" "dual|dual|Tie"; do
		c1=$(echo "$row" | cut -d'|' -f1)
		c2=$(echo "$row" | cut -d'|' -f2)
		c3=$(echo "$row" | cut -d'|' -f3)
		end="     |"
		[ "$c1" = "$a" ] && [ "$c2" = "$b" ] && end=" <<<  |"
		echo "$echo_prefix | $(printf '%-16s' "$c1") | $(printf '%-16s' "$c2") | $(printf '%-10s' "$c3") |${end}"
	done
	echo "$echo_prefix +------------------+------------------+------------+-------+"
}

echo "$echo_prefix === Step 1: Install build deps (gcc, make, openssl-devel, pesign) ==="
echo "$echo_prefix Running: sudo dnf install -y gcc make openssl-devel pesign"
sudo dnf install -y gcc make openssl-devel pesign
if [ $? -ne 0 ]; then
	echo "$echo_prefix ERROR: dnf install failed"
	exit 1
fi

echo "$echo_prefix === Step 2: Clone and build sbchooser ==="
if [ ! -d "$EFIVAR_REPO" ]; then
	echo "$echo_prefix Running: git clone --branch $EFIVAR_BRANCH $EFIVAR_REPO_URL $EFIVAR_REPO"
	git clone --branch "$EFIVAR_BRANCH" "$EFIVAR_REPO_URL" "$EFIVAR_REPO"
	if [ $? -ne 0 ]; then
		echo "$echo_prefix ERROR: git clone failed ($EFIVAR_REPO_URL branch $EFIVAR_BRANCH)"
		exit 1
	fi
fi
echo "$echo_prefix Running: cd $EFIVAR_REPO && make ENABLE_DOCS=0"
cd "$EFIVAR_REPO" || exit 1
make ENABLE_DOCS=0
if [ $? -ne 0 ]; then
	echo "$echo_prefix ERROR: make failed"
	exit 1
fi

echo "$echo_prefix Running: sudo make install ENABLE_DOCS=0"
sudo make install ENABLE_DOCS=0
if [ $? -ne 0 ]; then
	echo "$echo_prefix ERROR: make install failed"
	exit 1
fi

echo "$echo_prefix === Step 3: Copy current shim to $SHIM_EXISTING ==="
if ! sudo test -f "$SHIM_ESP"; then
	echo "$echo_prefix ERROR: $SHIM_ESP not found (use sudo find /boot -name 'shim*.efi' to locate)"
	exit 1
fi
echo "$echo_prefix Running: sudo cp $SHIM_ESP $SHIM_EXISTING"
sudo cp "$SHIM_ESP" "$SHIM_EXISTING"
if [ $? -ne 0 ]; then
	echo "$echo_prefix ERROR: copy existing shim failed"
	exit 1
fi
SHIM_EXISTING_VERSION=$(rpm -q shim-x64 2>/dev/null || echo "unknown")
echo "$echo_prefix SHIM_EXISTING version: $SHIM_EXISTING_VERSION"

echo "$echo_prefix === Step 4: Get latest available shim to $SHIM_NEW ==="
echo "$echo_prefix Running: sudo dnf list available shim-x64 -q (to resolve version)"
SHIM_VERSION=$(sudo dnf list available shim-x64 -q 2>&1 | awk '/shim-x64/ {print $2; exit}')
if [ -z "$SHIM_VERSION" ]; then
	echo "$echo_prefix ERROR: no available shim-x64 version from dnf (no upgrade candidate?)"
	exit 1
fi
SHIM_NEW_VERSION="${SHIM_VERSION}"
echo "$echo_prefix SHIM_NEW version: $SHIM_NEW_VERSION"

DNF_OPTS="--downloadonly -y shim-x64-${SHIM_VERSION}"
if [ -n "$DNF_DISABLEREPO" ]; then
	DNF_OPTS="--disablerepo=$DNF_DISABLEREPO $DNF_OPTS"
fi
echo "$echo_prefix Running: sudo dnf install $DNF_OPTS"
sudo dnf install $DNF_OPTS
if [ $? -ne 0 ]; then
	echo "$echo_prefix ERROR: dnf install --downloadonly shim-x64-${SHIM_VERSION} failed"
	exit 1
fi

echo "$echo_prefix Running: sudo find /var/cache/dnf -name 'shim-x64-${SHIM_VERSION}.x86_64.rpm' ..."
CACHED=$(sudo find /var/cache/dnf -name "shim-x64-${SHIM_VERSION}.x86_64.rpm" -type f 2>/dev/null | head -1)
if [ -z "$CACHED" ]; then
	echo "$echo_prefix ERROR: cached rpm not found (shim-x64-${SHIM_VERSION}.x86_64.rpm)"
	exit 1
fi

EXTRACT_DIR=$(mktemp -d)
echo "$echo_prefix Running: sudo rpm2cpio \$CACHED | (cd \$EXTRACT_DIR && cpio -idm)"
sudo rpm2cpio "$CACHED" | (cd "$EXTRACT_DIR" && cpio -idm)
if [ $? -ne 0 ]; then
	echo "$echo_prefix ERROR: rpm2cpio/cpio failed"
	rm -rf "$EXTRACT_DIR"
	exit 1
fi

NEW_EFI=$(find "$EXTRACT_DIR" -name 'shimx64.efi' -o -name 'shim*.efi' 2>/dev/null | head -1)
if [ -z "$NEW_EFI" ] || [ ! -f "$NEW_EFI" ]; then
	echo "$echo_prefix ERROR: no shim efi found in rpm"
	rm -rf "$EXTRACT_DIR"
	exit 1
fi
echo "$echo_prefix Running: sudo cp \$NEW_EFI $SHIM_NEW && sudo chown \$(whoami) $SHIM_NEW"
sudo cp "$NEW_EFI" "$SHIM_NEW"
sudo chown "$(whoami):" "$SHIM_NEW"
rm -rf "$EXTRACT_DIR"

echo "$echo_prefix === Step 4b: Check signature versions (pesign + openssl) ==="
echo "$echo_prefix SHIM_EXISTING ($SHIM_EXISTING_VERSION) signature:"
SIG_EXISTING=$(check_sign "$SHIM_EXISTING")
echo "$echo_prefix   -> $SIG_EXISTING"
echo "$echo_prefix SHIM_NEW ($SHIM_NEW_VERSION) signature:"
SIG_NEW=$(check_sign "$SHIM_NEW")
echo "$echo_prefix   -> $SIG_NEW"

echo "$echo_prefix === Step 5: Run sbchooser ==="
if [ ! -f "$SHIM_EXISTING" ] || [ ! -f "$SHIM_NEW" ]; then
	echo "$echo_prefix ERROR: one or both shims missing"
	exit 1
fi
echo "$echo_prefix Running: sudo sbchooser -s -S --explain --trace -i $SHIM_NEW -i $SHIM_EXISTING"
SBCHOOSER_OUT=$(mktemp)
sudo sbchooser -s -S --explain --trace -i "$SHIM_NEW" -i "$SHIM_EXISTING" > "$SBCHOOSER_OUT" 2>&1
sbchooser_rc=$?
cat "$SBCHOOSER_OUT"
WINNER=$(grep -m1 " is trusted because \| is not trusted because " "$SBCHOOSER_OUT" | sed 's/ is .*//')
rm -f "$SBCHOOSER_OUT"

EXPECTED=$(get_expected_winner)
result="FAIL"
if [ "$EXPECTED" = "Tie" ]; then
	[ "$WINNER" = "$SHIM_EXISTING" ] || [ "$WINNER" = "$SHIM_NEW" ] && result="PASS"
elif [ "$EXPECTED" = "A" ]; then
	[ "$WINNER" = "$SHIM_EXISTING" ] && result="PASS"
elif [ "$EXPECTED" = "B" ]; then
	[ "$WINNER" = "$SHIM_NEW" ] && result="PASS"
fi

echo "$echo_prefix === Table lookup (SHIM_EXISTING=$SIG_EXISTING, SHIM_NEW=$SIG_NEW -> expected $EXPECTED, winner $WINNER) ==="
print_table_with_match "$SIG_EXISTING" "$SIG_NEW"
echo "$echo_prefix Row marked with '<<<' at end is the matching table row for this run."
echo "$echo_prefix Table lookup matches expected. Result: $result"
exit $sbchooser_rc
