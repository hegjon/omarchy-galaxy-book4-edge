# Omarchy on the Samsung Galaxy Book4 Edge 14

Files that make [Omarchy](https://omarchy.org) 4.5.0rc1 (aarch64, `linux-omarchy`
7.3) work on the Samsung Galaxy Book4 Edge 14" (NP944XMA, Snapdragon X Elite
X1E-80-100). With them, a fresh install comes up with display, GPU, Wi-Fi,
Bluetooth, sound, microphones, camera, battery and fan working.

Upstream discussion: https://github.com/omacom/omarchy/discussions/15860

## Status

| Component | Status | Notes |
| --- | --- | --- |
| Boot, UFS, LUKS prompt | Works | v8 Book4 Edge DT series on 7.3; msm is kept out of the initramfs so the LUKS prompt stays visible |
| UEFI boot entry, efivars, RTC | Works | `qcom,x1e80100-qcp` in the root compatible stands in for the missing QSEECOM allowlist patch |
| Display, backlight, GPU | Works | msm + the zap shader from the Windows driver store; freedreno, Adreno X1-85 |
| Keyboard, touchpad, touchscreen | Works | udev rule: libinput otherwise opens the keyboard as a tablet pad |
| Wi-Fi (WCN7850) | Works | `board-2.bin` with an entry for board-id 255 |
| Bluetooth | Works (scan tested) | The controller has no address; a service sets a stable one from machine-id |
| Speakers (4) | Works | Amps are WSA883x; CRD topology, own UCM, volume cap patch |
| Internal microphones | Works | |
| Camera (OV02C10) | Works | ov02c10 patched for the module's 26 MHz oscillator; libcamera soft ISP |
| Battery | Works | EC driver from Saddytech/Galaxy-Book4-Edge-linux |
| Fan | Works | The EC never starts it; a service sets the speed from the CPU temperature |
| Charging | Only with the charger connected at boot | No charger/PD service on the ADSP |
| USB-C hotplug, DP alt mode | Missing | Same cause as charging; host mode is forced |
| Headphones, headset mic, DP audio, suspend | Untested | |

## Layout

`gb4e/` is the source of the `samsung-galaxy-book4-edge-14` package
(`gb4e/PKGBUILD`), which installs:

| File | Installed as | Purpose |
| --- | --- | --- |
| `x1e80100-samsung-galaxy-book4-edge-14.dtb` | `/boot/dtbs/linux-omarchy/qcom/` | Device tree: v8 series plus the changes in `samsung-galaxy-book4-edge-dtsi.patch` |
| `samsung-galaxy-book4-edge-dtsi.patch` | (not installed) | DT changes against Linux 7.3 + v8: WSA883x speakers, EC, camera, QSEECOM compatible |
| `x1e80100-samsung-galaxy-book4-edge-14.json` | `/usr/lib/systemd/boot/hwids/aa64/` | CHIDs, so the UKI's DeviceTreeAuto picks this tree |
| `samsung-galaxy-book4-edge-14.conf` | `/etc/limine-entry-tool.d/` | Adds `usbcore.autosuspend=-1` (usbcore is built in, so the modprobe option never applies) |
| `samsung-galaxy-book4-edge-14-initcpio-install`, `-mkinitcpio.conf` | `/usr/lib/initcpio/install/`, `/etc/mkinitcpio.conf.d/` | Keyboard modules in the initramfs; msm blacklisted there only |
| `board-2.bin` | `/usr/lib/firmware/updates/ath12k/WCN7850/hw2.0/` | linux-firmware's board file plus a board-id 255 entry (`wifi/ath12k_bd.py` builds it) |
| `X1E80100-GalaxyBook4Edge-tplg.bin` | `/usr/lib/firmware/updates/qcom/x1e80100/` | linux-firmware's `X1E001DE-DEVKIT-tplg.bin` under the name the kernel asks for |
| `ucm/`, `50-samsung-galaxy-book4-edge-upmix.conf` | `/usr/share/alsa/ucm2/Samsung/`, `/usr/share/pipewire/` | Four-speaker UCM profile; simple upmix so the woofers get centred sound |
| `61-…-keyboard.rules`, `62-…-wsa883x.rules`, `63-…-bluetooth.rules` | `/usr/lib/udev/rules.d/` | Keyboard tags, speaker amp runtime PM off, Bluetooth address service trigger |
| `samsung-galaxy-book4-edge-bdaddr`, `…@.service` | `/usr/lib/samsung-galaxy-book4-edge/bdaddr`, `/usr/lib/systemd/system/` | Sets the Bluetooth public address |
| `samsung-galaxy-book4-edge-fan`, `….service` | `/usr/lib/samsung-galaxy-book4-edge/fan`, `/usr/lib/systemd/system/` | Fan curve: 3000/4500/6000/8000 rpm at 60/70/80/88 °C; always enabled |
| `samsung-galaxybook-battery/`, `ov02c10-gb4e/`, `snd-soc-x1e80100-gb4e/` | `/usr/src/` | Out-of-tree modules: EC battery, ov02c10 with 26 MHz, x1e80100 with WSA883x volume caps |
| `samsung-galaxy-book4-edge-modules-build`, `90-…-modules.hook` | `/usr/lib/samsung-galaxy-book4-edge/build-modules`, `/usr/share/libalpm/hooks/` | Builds those modules into `updates/` when the package or a kernel's headers are installed or upgraded |
| `samsung-galaxy-book4-edge-modprobe.conf` | `/usr/lib/modprobe.d/` | Blacklists `qcom_battmgr` (it has no data on this machine) |

The fan and Bluetooth address services only start on this machine
(`ConditionFirmware=device-tree-compatible(samsung,galaxy-book4-edge-14)`).
`iso/` builds the live ISO (see below), and `wifi/ath12k_bd.py` adds board
entries to `board-2.bin`.

## Firmware is not included

The ADSP/CDSP firmware (`qcadsp8380.mbn`, `adsp_dtbs.elf`, `qccdsp8380.mbn`,
`cdsp_dtbs.elf`) and the GPU zap shader (`qcdxkmsuc8380.mbn`) are Qualcomm and
Samsung files that can't be redistributed. Take them from your own Windows
install with Omarchy's `qcom-firmware-extract`, or from Samsung's Windows
Driver Pack for your model on the
[Galaxy Books Download Center](https://www.samsung.com/global/galaxybooks-downloadcenter/).
Without the ADSP there is no sound; without the zap shader there is no GPU.
`iso/build.sh` packages your copy as `samsung-galaxy-book4-edge-14-firmware`
for your own ISO; don't publish that package.

## Building the live ISO

The stock ISO resets in a loop on this machine: its UKI has no device tree for
it. `iso/build.sh` turns the stock Omarchy 4.5.0rc1 aarch64 ISO into one that
boots and installs here:

```
iso/build.sh --iso omarchy-4.5.0rc1-aarch64.iso \
  --kernel linux-omarchy-7.3-1-aarch64.pkg.tar.zst \
  --headers linux-omarchy-headers-7.3-1-aarch64.pkg.tar.zst \
  --firmware ~/gb4e-firmware \
  -o omarchy-galaxybook4edge14.iso
```

- `--kernel`, `--headers`: linux-omarchy 7.3, which the device tree is built
  for. The tested packages came from the CI of
  [omacom/omarchy-pkgs#1417](https://github.com/omacom/omarchy-pkgs/pull/1417).
  They replace the stock kernel in the live system, its initramfs images and
  the installer's offline repository, so the installed system gets 7.3 too.
- `--firmware`: a directory with the five files above (default `gb4e/firmware`).
- `--authorized-keys FILE` (optional): lets those keys log in to the live
  system as root over SSH.
- `--ssh-from CIDR` (optional, with `--authorized-keys`): adds the
  `samsung-galaxy-book4-edge-14-ssh` package (`iso/ssh.PKGBUILD`), so the same
  keys can log in to the installed system as any user but root, from that
  network only (`from=` on each key and a ufw rule).
- It runs as a normal user (fakeroot) and needs `xorriso`, `squashfs-tools`,
  `fakeroot`, `mtools`, `pacman` (with `makepkg` and `repo-add`), `kmod`,
  `cpio`, Python 3, `edk2-shell` (or `--shell`) and about 15 GB in the work
  directory.

It builds the board package from `gb4e/` and the firmware package, puts them
in the installer's offline repository and adds them to the Snapdragon package
list. The installer then installs them with the rest of Omarchy, after it
creates the user and before it builds the UKI, and the module hook builds the
modules in the same step. The ISO also gets the GRUB entries in
`iso/grub-galaxy-book4-edge.cfg`, the device tree, a UEFI Shell with
`iso/startup.nsh` on the EFI partition, the GPU zap shader and `board-2.bin`
in the live system, and `iso/patch-installer.py`, which keeps the installer
going when there are no EFI variables. It removes the stock live UKI.

## Installing

The Omarchy installer used here takes the whole internal drive. Copy the
firmware from Windows before you install.

1. Write the ISO to a USB stick. Turn off Secure Boot (GRUB won't load a
   device tree with it on).
2. Plug in the stick, and a USB Ethernet adapter if you want SSH, **before
   power-on**: USB-C has no hotplug.
3. Boot "Omarchy (Galaxy Book4 Edge 14)" from the GRUB menu and run the
   installer as usual.

On an existing install (untested): run `makepkg` in `gb4e/`, build the firmware
package from `iso/firmware.PKGBUILD` next to your five files, and install both
with `pacman -U`.

## Notes for other Snapdragon devices

- The Samsung EC (ENE KB9058, ACPI `SAM060B`) answers on two ports. 0x64 on
  i2c-2 is a mailbox to EC RAM: battery, AC, thermistors. 0x62 on i2c-3 takes
  commands; `17 <rpm, big-endian u32>` sets the fan. These were decoded from
  Samsung's Windows `EC2.sys`.
- `x1e80100.c` caps PA Volume at 6, which is 0 dB on WSA884x but −3 dB on
  WSA883x (17 is 0 dB there).
- `usbcore.autosuspend=-1` belongs on the kernel command line on
  linux-omarchy, not in `modprobe.d`.

## Credits and licenses

- `samsung-galaxybook-battery/`: from
  [Saddytech/Galaxy-Book4-Edge-linux](https://github.com/Saddytech/Galaxy-Book4-Edge-linux),
  unmodified; see its `LICENSE`.
- `ov02c10-gb4e/` and `snd-soc-x1e80100-gb4e/`: Linux 7.3 sources plus our
  patches, GPL-2.0.
- `board-2.bin` and the topology come from linux-firmware and keep its licenses.
- The device tree is the v8 Galaxy Book4 Edge series
  ([patchwork](https://patchwork.kernel.org/series/1177250/)) plus the changes in
  `samsung-galaxy-book4-edge-dtsi.patch`.
