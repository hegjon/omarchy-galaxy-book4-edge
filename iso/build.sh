#!/bin/bash
# Build the Galaxy Book4 Edge 14 live ISO from the stock Omarchy aarch64 ISO:
#
#   iso/build.sh --iso omarchy-4.5.0rc1-aarch64.iso \
#     --kernel linux-omarchy-7.3-1-aarch64.pkg.tar.zst \
#     --headers linux-omarchy-headers-7.3-1-aarch64.pkg.tar.zst \
#     [--firmware DIR] [--shell Shell_Full.efi] [--authorized-keys FILE] \
#     [--ssh-from CIDR] [--work DIR] [--keep-work] -o OUT.iso
#
# The result boots the given kernel from GRUB with the Book4 Edge device tree.
# Its installer installs the same kernel, plus the Book4 Edge packages built
# here: gb4e/PKGBUILD and the firmware package (iso/firmware.PKGBUILD) made
# from --firmware, a directory with the five files from Windows (default
# gb4e/firmware). --authorized-keys lets those keys log in to the live system
# as root over SSH; with --ssh-from as well, they may also log in to the
# installed system from that network (iso/ssh.PKGBUILD). Runs as a normal
# user; fakeroot keeps the squashfs owned by root. Needs makepkg and about
# 15 GB in the work directory.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
repo=$(dirname "$here")

iso='' kernel='' headers='' firmware=$repo/gb4e/firmware keys='' ssh_from='' work='' out='' keep=''
shell=/usr/share/edk2-shell/aarch64/Shell_Full.efi
while (($#)); do
  case $1 in
    --iso) iso=$2; shift ;;
    --kernel) kernel=$2; shift ;;
    --headers) headers=$2; shift ;;
    --firmware) firmware=$2; shift ;;
    --shell) shell=$2; shift ;;
    --authorized-keys) keys=$2; shift ;;
    --ssh-from) ssh_from=$2; shift ;;
    --work) work=$2; shift ;;
    --keep-work) keep=1 ;;
    -o) out=$2; shift ;;
    *) echo "unknown option: $1 (see the top of $0)" >&2; exit 2 ;;
  esac
  shift
done
[[ -n $iso && -n $kernel && -n $headers && -n $out ]] || { echo "--iso, --kernel, --headers and -o are required" >&2; exit 2; }
if [[ -n $ssh_from ]]; then
  [[ -n $keys ]] || { echo "--ssh-from needs --authorized-keys" >&2; exit 2; }
  [[ $ssh_from =~ ^[0-9A-Fa-f:.]+(/[0-9]+)?$ ]] || { echo "--ssh-from: not an address or network: $ssh_from" >&2; exit 2; }
fi
fw_files=(qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf qcdxkmsuc8380.mbn)
for f in "$iso" "$kernel" "$headers" "${fw_files[@]/#/$firmware/}" ${keys:+"$keys"}; do
  [[ -f $f ]] || { echo "missing: $f" >&2; exit 1; }
done
# The full shell, because the minimal one has no bcfg (Arch: edk2-shell).
[[ -f $shell ]] || { echo "missing: $shell (install edk2-shell or pass --shell)" >&2; exit 1; }
iso=$(realpath "$iso") kernel=$(realpath "$kernel") headers=$(realpath "$headers")
firmware=$(realpath "$firmware") shell=$(realpath "$shell") out=$(realpath -m "$out")
[[ -n $keys ]] && keys=$(realpath "$keys")
w=$(realpath -m "${work:-${out%.iso}.work}")
[[ ! -e $w ]] || { echo "$w exists; remove it or pass another --work" >&2; exit 1; }
mkdir -p "$w"
say() { printf '==> %s\n' "$*"; }
# xorriso exits non-zero on SORRY or worse; show its log then.
run_xorriso() { xorriso "$@" > "$w/xorriso.log" 2>&1 || { tail -n 20 "$w/xorriso.log" >&2; return 1; }; }
xattr_ids() { unsquashfs -s "$1" 2>/dev/null | sed -n 's/^Number of xattr ids //p'; }

say "Extracting the stock ISO"
run_xorriso -osirrox on -indev "$iso" \
  -extract /arch/aarch64/airootfs.sfs "$w/stock.sfs" \
  -extract /arch/aarch64/airootfs.sha512 "$w/stock.sha512" \
  -extract /arch/boot/aarch64/initramfs-linux-omarchy.img "$w/initramfs-linux-omarchy.stock.img" \
  -extract /arch/boot/aarch64/omarchy-live.efi "$w/omarchy-live.efi" \
  -extract /arch/pkglist.aarch64.txt "$w/pkglist.aarch64.txt" \
  -extract /boot/grub/grub.cfg "$w/grub.stock.cfg"
chmod u+w "$w"/*
! grep -q galaxy-book4-edge "$w/grub.stock.cfg" || { echo "$iso is not a stock ISO" >&2; exit 1; }
(cd "$w" && sed 's/airootfs.sfs$/stock.sfs/' stock.sha512 | sha512sum -c --quiet)
# The live UKI's initramfs is the one the Book4 Edge entries boot with GRUB.
python3 -I - "$w/omarchy-live.efi" "$w/initramfs-linux-omarchy-uki.stock.img" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]
count, optsize = struct.unpack_from('<H', d, pe + 6)[0], struct.unpack_from('<H', d, pe + 20)[0]
for i in range(count):
    name, vsize, _, rsize, rptr = struct.unpack_from('<8sIIII', d, pe + 24 + optsize + 40 * i)
    if name.rstrip(b'\0') == b'.initrd':
        open(sys.argv[2], 'wb').write(d[rptr:rptr + min(vsize, rsize)])
        break
else:
    sys.exit('no .initrd section in ' + sys.argv[1])
EOF

say "Building the Book4 Edge packages"
pkgs=$w/pkgs
mkdir -p "$pkgs" "$w/makepkg"
# makepkg in DIR, with the package in $pkgs and its work files under $w.
makepkg_in() {
  (cd "$1" && BUILDDIR=$w/makepkg PKGDEST=$pkgs SRCDEST=$w/makepkg PKGEXT=.pkg.tar.zst \
    makepkg --nodeps --nosign --skipinteg --clean --force) > "$w/makepkg.log" 2>&1 ||
    { tail -n 30 "$w/makepkg.log" >&2; return 1; }
}
makepkg_in "$repo/gb4e"
mkdir "$w/firmware-pkg"
cp "$here/firmware.PKGBUILD" "$w/firmware-pkg/PKGBUILD"
cp "${fw_files[@]/#/$firmware/}" "$w/firmware-pkg/"
makepkg_in "$w/firmware-pkg"
if [[ -n $ssh_from ]]; then
  d=$w/ssh-pkg
  mkdir "$d"
  cp "$here/ssh.PKGBUILD" "$d/PKGBUILD"
  cp "$here/ssh-sshd.conf" "$d/sshd.conf"
  sed "s|@SSH_FROM@|$ssh_from|g" "$here/ssh.service" > "$d/samsung-galaxy-book4-edge-14-ssh.service"
  grep -Ev '^[[:space:]]*(#|$)' "$keys" | sed "s|^|from=\"$ssh_from\" |" > "$d/authorized_keys"
  makepkg_in "$d"
fi
ls "$pkgs"

say "Unpacking and changing the live root"
fakeroot -s "$w/fr.db" unsquashfs -q -n -no-xattrs -d "$w/root" "$w/stock.sfs"
oldver=$(sed -n 's/^linux-omarchy //p' "$w/pkglist.aarch64.txt")
fakeroot -i "$w/fr.db" -s "$w/fr.db" bash "$here/live-root.sh" "$w/root" "$w" "$kernel" "$headers" "$pkgs" "$firmware" "$keys"
newver=$(bsdtar -xOf "$kernel" .PKGINFO | sed -n 's/^pkgver = //p')
sed -i "s/^linux-omarchy $oldver\$/linux-omarchy $newver/" "$w/pkglist.aarch64.txt"
# fakeroot drops file capabilities (newuidmap, newgidmap); copy them from stock.
stock_xattr_ids=$(xattr_ids "$w/stock.sfs")
unsquashfs -pf - "$w/stock.sfs" 2>/dev/null | grep -a -E '^[^ ]+ x [a-z]+\.[^ =]+=' |
  while read -r path rest; do [[ -e $w/root/$path ]] && printf '%s %s\n' "$path" "$rest"; done > "$w/xattrs.pseudo" || true

say "Building the squashfs"
unsquashfs -lln "$w/stock.sfs" > "$w/stock.lst" 2>/dev/null
rm -f "$w/stock.sfs"
fakeroot -i "$w/fr.db" mksquashfs "$w/root" "$w/airootfs.sfs" -comp zstd -Xcompression-level 19 -b 1M \
  -no-progress -quiet -pf "$w/xattrs.pseudo"
[[ $(xattr_ids "$w/airootfs.sfs") == "$stock_xattr_ids" ]] || { echo "xattrs differ from the stock squashfs" >&2; exit 1; }
# fakeroot's database is keyed on st_dev, which can change on btrfs (between
# boots, for one). Files it no longer recognizes come out owned by root, so
# check that every path the squashfs shares with stock kept its owner.
unsquashfs -lln "$w/airootfs.sfs" > "$w/new.lst" 2>/dev/null
python3 -I - "$w/stock.lst" "$w/new.lst" <<'EOF'
import sys
def owners(f):
    d = {}
    for line in open(f, errors='surrogateescape'):
        parts = line.split(None, 5)
        if len(parts) == 6:
            d[parts[5].rstrip('\n').split(' -> ')[0]] = parts[1]
    return d
a, b = owners(sys.argv[1]), owners(sys.argv[2])
bad = [p for p in a if p in b and a[p] != b[p]]
for p in bad[:10]:
    print(f'owner changed: {p} {a[p]} -> {b[p]}', file=sys.stderr)
sys.exit(f'{len(bad)} files changed owner' if bad else 0)
EOF
(cd "$w" && sha512sum airootfs.sfs) > "$w/airootfs.sha512"

say "Repacking the initramfs images"
kpkg=$w/kpkg
mkdir "$kpkg" && bsdtar -xf "$kernel" -C "$kpkg" usr/lib/modules
kver=$(ls "$kpkg/usr/lib/modules")
for img in initramfs-linux-omarchy-uki initramfs-linux-omarchy; do
  "$here/repack-initramfs.sh" "$w/$img.stock.img" "$w/$img.img" "$kpkg/usr/lib/modules/$kver"
done

say "GRUB entries and the EFI partition"
uuid=$(grep -o -m1 'archisosearchuuid=[^ ]*' "$w/grub.stock.cfg" | cut -d= -f2)
awk -v snippet="$here/grub-galaxy-book4-edge.cfg" -v uuid="$uuid" '
  !done && /^menuentry "Omarchy \(aarch64, \$\{archiso_platform\}\)"/ {
    while ((getline line < snippet) > 0) { gsub(/@ARCHISO_UUID@/, uuid, line); print line }
    done = 1
  }
  { print }
  END { exit !done }' "$w/grub.stock.cfg" > "$w/grub.cfg"
read -r efi_start efi_size < <(sfdisk -d "$iso" 2>/dev/null | awk -F'[=,]' '/type=C12A7328/ { print $2 + 0, $4 + 0 }')
dd if="$iso" of="$w/efipart.img" bs=512 skip="$efi_start" count="$efi_size" status=none
sed 's/$/\r/' "$here/startup.nsh" > "$w/startup.nsh"
mmd -i "$w/efipart.img" ::/EFI/tools
mcopy -o -i "$w/efipart.img" "$shell" ::/EFI/tools/shellaa64.efi
mcopy -o -i "$w/efipart.img" "$w/startup.nsh" ::/startup.nsh
mcopy -o -i "$w/efipart.img" "$w/startup.nsh" ::/EFI/tools/startup.nsh

say "Writing $out"
dtb=x1e80100-samsung-galaxy-book4-edge-14.dtb
rm -f "$out" "$out.sha256"
run_xorriso -indev "$iso" -outdev "$out" \
  -map "$w/airootfs.sfs" /arch/aarch64/airootfs.sfs \
  -map "$w/airootfs.sha512" /arch/aarch64/airootfs.sha512 \
  -map "$kpkg/usr/lib/modules/$kver/vmlinuz" /arch/boot/aarch64/vmlinuz-linux-omarchy \
  -map "$w/initramfs-linux-omarchy-uki.img" /arch/boot/aarch64/initramfs-linux-omarchy-uki.img \
  -map "$w/initramfs-linux-omarchy.img" /arch/boot/aarch64/initramfs-linux-omarchy.img \
  -map "$w/pkglist.aarch64.txt" /arch/pkglist.aarch64.txt \
  -rm /arch/boot/aarch64/omarchy-live.efi -- \
  -map "$repo/gb4e/$dtb" "/boot/dtbs/$dtb" \
  -map "$w/grub.cfg" /boot/grub/grub.cfg \
  -boot_image any replay -append_partition 2 0xef "$w/efipart.img"

# Read the new image back and check what was put in.
mkdir "$w/check"
run_xorriso -osirrox on -indev "$out" \
  -extract /arch/aarch64/airootfs.sha512 "$w/check/airootfs.sha512" \
  -extract /boot/grub/grub.cfg "$w/check/grub.cfg" \
  -extract "/boot/dtbs/$dtb" "$w/check/$dtb"
cmp "$w/check/airootfs.sha512" "$w/airootfs.sha512"
cmp "$w/check/grub.cfg" "$w/grub.cfg"
cmp "$w/check/$dtb" "$repo/gb4e/$dtb"
read -r s n < <(sfdisk -d "$out" 2>/dev/null | awk -F'[=,]' '/type=C12A7328/ { print $2 + 0, $4 + 0 }')
dd if="$out" bs=512 skip="$s" count="$n" status=none | cmp - "$w/efipart.img"
(cd "$(dirname "$out")" && sha256sum "$(basename "$out")") > "$out.sha256"
if [[ -z $keep ]]; then chmod -R u+rwX "$w" && rm -rf "$w"; fi
say "Done: $(cat "$out.sha256")"
