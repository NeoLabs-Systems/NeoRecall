#!/bin/bash
# Cheap source-level checks for the kernel override. The CI kernel matrix below
# additionally compiles it against Raspberry Pi's pinned 6.12 and 6.18 trees.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$HERE/kernel/neorecall-uac2-name"
FAILURES=0

check() {
    local label="$1"; shift
    if "$@"; then
        printf '  ok    %s\n' "$label"
    else
        printf '  FAIL  %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

has_no_stock_display_names() {
    ! grep -qE '(Playback|Capture) (Inactive|Active)' "$SOURCE/f_uac2.c"
}

echo "UAC2 name override checks"
check "the DKMS package keeps the upstream module name" \
    grep -q 'BUILT_MODULE_NAME\[0\]="usb_f_uac2"' "$SOURCE/dkms.conf"
check "the package installs in the DKMS override directory" \
    grep -q 'DEST_MODULE_LOCATION\[0\]="/updates/dkms"' "$SOURCE/dkms.conf"
check "future kernels are rebuilt automatically" \
    grep -q 'AUTOINSTALL="yes"' "$SOURCE/dkms.conf"
check "all four streaming strings use function_name" \
    test "$(grep -c 'strings_fn\[STR_AS_.*\]\.s = uac2_opts->function_name;' \
        "$SOURCE/f_uac2.c")" -eq 4
check "no inactive or active display names remain" \
    has_no_stock_display_names
check "the Raspberry Pi source commit is recorded" \
    grep -q '8c74b839debd96d0d7a441abc35d36b20fdda278' "$SOURCE/UPSTREAM.md"

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed."
    exit 1
fi
echo "All UAC2 name override checks passed."
