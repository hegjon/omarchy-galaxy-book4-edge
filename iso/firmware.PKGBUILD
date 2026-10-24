# Firmware from Windows for the Samsung Galaxy Book4 Edge 14: ADSP and CDSP
# images with their device-tree blobs, and the GPU zap shader. Qualcomm and
# Samsung files that can't be redistributed: iso/build.sh builds this from your
# own copy (--firmware) for your own ISO. Never publish the result.
pkgname=samsung-galaxy-book4-edge-14-firmware
pkgver=1
pkgrel=1
pkgdesc='Samsung Galaxy Book4 Edge 14 DSP firmware and GPU zap shader from Windows'
arch=(any)
license=(LicenseRef-proprietary)
options=(!strip !debug)
source=(qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf qcdxkmsuc8380.mbn)
sha256sums=(SKIP SKIP SKIP SKIP SKIP)

package() {
  # The paths the device tree's firmware-name properties give, under updates/
  # like qcom-firmware-extract, which then finds nothing missing.
  install -Dm644 -t "$pkgdir/usr/lib/firmware/updates/qcom/x1e80100/SAMSUNG/galaxy-book4-edge" "${source[@]}"
}
