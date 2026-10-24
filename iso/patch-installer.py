"""Make the Omarchy installer skip efibootmgr when there are no EFI variables.

  patch-installer.py usr/share/omarchy-iso/orchestrator/phases_impl.py

Without QSEECOM (a kernel or device tree that doesn't allow it on this
machine) efivars is empty, efibootmgr fails and the installer stops. With the
patch it logs a warning and leaves the boot entry to the UEFI Shell entry on
the stick. With efivars present it changes nothing.
"""
import ast
import sys

path = sys.argv[1]
s = open(path).read()


def sub(old, new):
    global s
    assert s.count(old) == 1, f"{path}: expected one match for {old!r}"
    s = s.replace(old, new)


sub('''def _read_efibootmgr() -> dict:
    res = capture(''', '''def _efivars_available() -> bool:
    # Some Snapdragon laptops (Galaxy Book4 Edge) expose no EFI variables
    # without QSEECOM, so efibootmgr cannot work; the firmware then boots
    # Limine's removable fallback (EFI/BOOT/BOOTAA64.EFI) instead.
    efivars = Path("/sys/firmware/efi/efivars")
    return efivars.is_dir() and any(efivars.iterdir())


def _read_efibootmgr() -> dict:
    if not _efivars_available():
        return {"entries": {}, "order": [], "raw": ""}
    res = capture(''')
sub('''    pre_state = pre_state or _read_efibootmgr()

    subprocess.run(''', '''    if not _efivars_available():
        info("warning: no EFI variables; not registering a Limine boot entry")
        return
    pre_state = pre_state or _read_efibootmgr()

    subprocess.run(''')
sub('''        if not _find_label_entries(post["entries"], "Limine"):''',
    '''        if _efivars_available() and not _find_label_entries(post["entries"], "Limine"):''')
ast.parse(s, path)
open(path, "w").write(s)
