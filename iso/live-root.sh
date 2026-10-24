#!/bin/bash
# Changes to the unpacked live root. build.sh runs this under fakeroot:
#   live-root.sh ROOT WORK KERNEL_PKG HEADERS_PKG BOARD_PKG_DIR FIRMWARE_DIR [AUTHORIZED_KEYS]
# BOARD_PKG_DIR holds the Book4 Edge packages the installer is to install.
set -euo pipefail
r=$1 w=$2 kernel=$3 headers=$4 boardpkgs=$5 firmware=$6 keys=${7:-}
here=$(dirname "$(readlink -f "$0")")

# Kernel: install the new linux-omarchy in place of the stock one. Hooks and
# scriptlets are skipped (they would build a UKI); build.sh repacks the ISO's
# initramfs images separately.
old=$(cd "$r/var/lib/pacman/local" && echo linux-omarchy-[0-9]*)
oldver=${old#linux-omarchy-}
oldkver=$(ls "$r/usr/lib/modules")
kver=$(bsdtar -tf "$kernel" | sed -n 's|^usr/lib/modules/\([^/]*\)/vmlinuz$|\1|p')
[[ $oldkver != *$'\n'* && -n $kver ]] || { echo "can't tell the kernel versions apart" >&2; exit 1; }
pkgs=("$kernel")
[[ -d $r/var/lib/pacman/local/linux-omarchy-headers-$oldver ]] && pkgs+=("$headers")
printf '[options]\nArchitecture = aarch64\nSigLevel = Never\nLocalFileSigLevel = Never\n' > "$w/pacman.conf"
mkdir -p "$w/nohooks" "$w/pcache"
mv "$r/usr/share/libalpm/hooks" "$r/usr/share/libalpm/hooks.off"
# pacman can't chroot under fakeroot to run ldconfig and says so; that's fine,
# the kernel package has no libraries.
pacman --root "$r" --dbpath "$r/var/lib/pacman" --cachedir "$w/pcache" --logfile "$w/pacman.log" \
  --config "$w/pacman.conf" --hookdir "$w/nohooks" --noscriptlet --noconfirm -Udd "${pkgs[@]}"
mv "$r/usr/share/libalpm/hooks.off" "$r/usr/share/libalpm/hooks"
# pacman leaves the old version's depmod output behind.
[[ $oldkver == "$kver" ]] || rm -rf "$r/usr/lib/modules/$oldkver"
depmod -b "$r" "$kver"

# The installer's offline repo: the same kernel and headers for the target,
# and the Book4 Edge packages.
o=$r/var/cache/omarchy/mirror/offline
rm -f "$o"/linux-omarchy{,-headers}-"$oldver"-aarch64.pkg.tar.zst{,.sig}
board=("$boardpkgs"/*.pkg.tar.zst)
install -m 0644 "$kernel" "$headers" "${board[@]}" "$o/"
repo-add -q "$o/offline.db.tar.gz" "$o/$(basename "$kernel")" "$o/$(basename "$headers")" "${board[@]/#"$boardpkgs"/$o}"
rm -f "$o"/offline.{db,files}.tar.gz.old

# The installer installs this platform's package list with the Omarchy base,
# after it creates the user and before it builds the UKI. The count feeds the
# installer's progress bar.
share=$r/usr/share/omarchy-iso
printf '\n# Samsung Galaxy Book4 Edge 14 (gb4e iso/build.sh)\n' >> "$share/omarchy-base.aarch64-qualcomm.packages"
for f in "${board[@]}"; do
  bsdtar -xOf "$f" .PKGINFO | sed -n 's/^pkgname = //p' >> "$share/omarchy-base.aarch64-qualcomm.packages"
done
echo $(($(cat "$share/expected-packages.aarch64-qualcomm") + ${#board[@]})) > "$share/expected-packages.aarch64-qualcomm"

python3 -I "$here/patch-installer.py" "$share/orchestrator/phases_impl.py"

# Live system firmware: the GPU zap shader (msm entry) and the Wi-Fi board file.
install -D -m 0644 "$firmware/qcdxkmsuc8380.mbn" \
  "$r/usr/lib/firmware/qcom/x1e80100/SAMSUNG/galaxy-book4-edge/qcdxkmsuc8380.mbn"
install -D -m 0644 "$(dirname "$here")/gb4e/board-2.bin" "$r/usr/lib/firmware/updates/ath12k/WCN7850/hw2.0/board-2.bin"

if [[ -n $keys ]]; then
  install -d -m 0700 "$r/root/.ssh"
  install -m 0600 "$keys" "$r/root/.ssh/authorized_keys"
fi
echo "live root: linux-omarchy $oldver -> ${kernel##*/}, modules $oldkver -> $kver, added ${board[*]##*/}"
