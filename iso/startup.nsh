@echo -off
echo "Adding the Omarchy boot entry..."
for %a run (0 29)
  if exist fs%a:\EFI\limine\limine_aa64.efi then
    bcfg boot add 0 fs%a:\EFI\limine\limine_aa64.efi "Omarchy"
    bcfg boot dump
    echo "Done. Remove the USB stick and type: reset"
    goto END
  endif
endfor
echo "Limine was not found on any drive."
:END
