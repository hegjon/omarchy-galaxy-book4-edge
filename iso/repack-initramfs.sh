#!/bin/bash
# Swap the kernel modules in an mkinitcpio image for another kernel's:
#   repack-initramfs.sh IN OUT MODULES_DIR
# IN is one or more uncompressed (early) cpio archives followed by the gzip
# main archive. Every module in the main archive is replaced by its namesake
# from MODULES_DIR (usr/lib/modules/<version> from the kernel package);
# modules the new kernel doesn't have are listed and dropped.
set -euo pipefail
shopt -s nullglob
in=$(realpath "$1"); out=$(realpath -m "$2"); newmods=$(realpath "$3")
newver=$(basename "$newmods")
# Modules renamed between the stock kernel and the new one (7.3: smem.ko).
declare -A renamed=([kernel/drivers/soc/qcom/smem]=kernel/drivers/soc/qcom/qcom_smem)

w=$(mktemp -d -p "$(dirname "$out")" repack.XXXX)
trap 'rm -rf "$w"' EXIT
# Walk the newc archives at the start; the gzip stream begins after the last.
off=$(python3 -I - "$in" <<'EOF'
import sys
d = open(sys.argv[1], 'rb').read(64 << 20)
i = 0
while d[i:i + 6] == b'070701':
    namesize = int(d[i + 94:i + 102], 16)
    filesize = int(d[i + 54:i + 62], 16)
    name = d[i + 110:i + 110 + namesize - 1]
    i = (i + 110 + namesize + 3) & ~3
    i = (i + filesize + 3) & ~3
    if name == b'TRAILER!!!':
        while d[i:i + 1] == b'\0':
            i += 1
if d[i:i + 2] != b'\x1f\x8b':
    sys.exit(f'{sys.argv[1]}: no gzip archive at offset {i}')
print(i)
EOF
)
head -c "$off" "$in" > "$w/early.cpio"
mkdir "$w/root"; cd "$w/root"
tail -c +$((off + 1)) "$in" | gzip -dc | cpio -idm --quiet --no-absolute-filenames
oldver=$(ls usr/lib/modules)
echo "$(basename "$in"): $oldver -> $newver"
mkdir -p "usr/lib/modules/$newver"
missing=0
while read -r m; do
  rel=${m#usr/lib/modules/$oldver/}; base=${rel%.ko*}
  base=${renamed[$base]:-$base}
  srcs=("$newmods/$base".ko*)
  if ((${#srcs[@]} == 0)); then echo "  missing: $rel"; missing=$((missing + 1)); continue; fi
  install -D -p -m 0644 "${srcs[0]}" "usr/lib/modules/$newver/${srcs[0]#"$newmods"/}"
done < <(find "usr/lib/modules/$oldver" -name '*.ko*')
cp -p "$newmods"/modules.builtin* "$newmods"/modules.order "usr/lib/modules/$newver/"
rm -rf "usr/lib/modules/$oldver"
depmod -b . "$newver"
echo "  $missing modules not in $newver"
{ cat "$w/early.cpio"; find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort |
  cpio -o -H newc -R 0:0 --reproducible --quiet | gzip -6 -n; } > "$out"
