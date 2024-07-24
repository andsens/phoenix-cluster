#!/usr/bin/env bash
# shellcheck source-path=../../../..
set -Eeo pipefail; shopt -s inherit_errexit
PKGROOT=/usr/local/lib/upkg

main() {
  source "$PKGROOT/.upkg/records.sh/records.sh"
  # shellcheck disable=SC2154

  mkdir -p /workspace/root

  info "Extracting container export"
  for layer in $(jq -r '.[0].Layers[]' <(tar -xOf "/images/$ARCH.new/node.tar" manifest.json)); do
    tar -xOf "/images/$ARCH.new/node.tar" "$layer" | tar -xz -C /workspace/root
  done
  # During bootstrapping with kaniko these file can't be removed/overwritten,
  # instead we do it when creating the image
  rm /workspace/root/etc/hostname /workspace/root/etc/resolv.conf
  cp /assets/etc-hosts /workspace/root/etc/hosts
  ln -sf ../run/systemd/resolve/stub-resolv.conf /workspace/root/etc/resolv.conf
  # Revert the disabling of initramfs creation
  cp /assets/etc-initramfs-tools-update-initramfs.conf /workspace/root/etc/initramfs-tools/update-initramfs.conf

  local vmlinuz initrd
  vmlinuz=/$(readlink /workspace/root/vmlinuz)
  initrd=/$(readlink /workspace/root/initrd.img)
  # Remove kernel symlinks
  rm /workspace/root/initrd.img* /workspace/root/vmlinuz*
  # Move boot dir out of the way before creating squashfs image
  mv /workspace/root/boot /workspace/boot

  info "Creating squashfs image"
  local noprogress=
  [[ -t 1 ]] || noprogress=-no-progress
  mksquashfs /workspace/root /workspace/root.img -noappend -quiet $noprogress

  # Move boot dir back into place
  mv /workspace/boot /workspace/root/boot

  # Hash the root image so we can verify it during boot
  local rootimg_checksum
  rootimg_checksum=$(sha256sum /workspace/root.img | cut -d ' ' -f1)

  info "Creating unified kernel image"
  local kernver=${vmlinuz#'/boot/vmlinuz-'}
  chroot /workspace/root update-initramfs -c -k "$kernver"
  chroot /workspace/root /lib/systemd/ukify build \
    --uname="$kernver" \
    --linux="$vmlinuz" \
    --initrd="$initrd" \
    --cmdline="root=/run/initramfs/root.img root_sha256=$rootimg_checksum noresume" \
    --output=/boot/uki.efi
  mv /workspace/root/boot/uki.efi /workspace/uki.efi

  ### UEFI Boot ###

  local shimsuffix
  case $ARCH in
    amd64) shimsuffix=x64 ;;
    arm64) shimsuffix=aa64 ;;
    default) fatal "Unknown processor architecture: %s" "$ARCH" ;;
  esac

  info "Generating node settings"
  mkdir /workspace/node-settings
  local file node_settings_size_b=0
  for file in /node-settings/*; do
    node_settings_size_b=$(( node_settings_size_b + $(stat -c %s "$file") ))
    cp "$file" "/workspace/node-settings/$(basename "$file" | sed s/:/-/g)"
  done

  local sector_size_b=512 gpt_size_b fs_table_size_b partition_offset_b partition_size_b disk_size_kib
  gpt_size_b=$((33 * sector_size_b))
  fs_table_size_b=$(( 1024 * 1024 )) # Total guess, but should be enough
  partition_offset_b=$((1024 * 1024))
  # efi * 2 : The EFI boot loader is copied to two different destinations
  # stat -c %s : Size in bytes of the file
  # ... (sector_size_b - 1) ) / sector_size_b * sector_size_b : Round to next sector
  partition_size_b=$((
    (
      fs_table_size_b +
      node_settings_size_b +
      $(stat -c %s /usr/lib/shim/shim${shimsuffix}.efi.signed) +
      $(stat -c %s /usr/lib/shim/mm${shimsuffix}.efi.signed) +
      $(stat -c %s /workspace/uki.efi) +
      $(stat -c %s /workspace/root.img) +
      (sector_size_b - 1)
    ) / sector_size_b * sector_size_b
  ))
  disk_size_kib=$((
    (
      partition_offset_b +
      partition_size_b +
      gpt_size_b +
      1023
    ) / 1024
  ))

  # Fixed, so we can find it when we need to mount the EFI partition during init
  DISK_UUID=caf66bff-edab-4fb1-8ad9-e570be5415d7
  ESP_UUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b

  info "Creating UEFI boot image"

  guestfish -xN /workspace/node.raw=disk:${disk_size_kib}K -- <<EOF
part-init /dev/sda gpt
part-add /dev/sda primary $(( partition_offset_b / sector_size_b )) $(( (partition_offset_b + partition_size_b ) / sector_size_b - 1 ))
part-set-bootable /dev/sda 1 true
part-set-disk-guid /dev/sda $DISK_UUID
part-set-gpt-guid /dev/sda 1 $ESP_UUID

mkfs vfat /dev/sda1
mount /dev/sda1 /

mkdir-p /EFI/BOOT
copy-in /usr/lib/shim/shim${shimsuffix}.efi.signed /EFI/BOOT/
mv /EFI/BOOT/shim${shimsuffix}.efi.signed /EFI/BOOT/BOOT${shimsuffix^^}.EFI
copy-in /usr/lib/shim/mm${shimsuffix}.efi.signed /EFI/BOOT/
mv /EFI/BOOT/mm${shimsuffix}.efi.signed /EFI/BOOT/mm${shimsuffix}.efi
copy-in /workspace/uki.efi /EFI/BOOT/
mv /EFI/BOOT/uki.efi /EFI/BOOT/grub${shimsuffix}.efi

mkdir-p /home-cluster
copy-in /workspace/root.img /home-cluster/
copy-in /workspace/node-settings /home-cluster/
EOF

  # Finish up by moving everything to the right place in the most atomic way possible
  # as to avoid leaving anything in an incomplete state

  info "Moving UEFI disk, squashfs root, shim bootloader, mok manager, and unified kernel image EFI to shared volume"

  # Extract digests used for PE signatures so we can use them for remote attestation
  local shim_digests uki_digests kernel_digests
  shim_digests=$(/signify/bin/python3 /scripts/get-pe-digest.py --json /usr/lib/shim/shim${shimsuffix}.efi.signed)
  uki_digests=$(/signify/bin/python3 /scripts/get-pe-digest.py --json /workspace/uki.efi)
  # See https://lists.freedesktop.org/archives/systemd-devel/2022-December/048694.html
  # as to why we also measure the embedded kernel
  objcopy -O binary --only-section=.linux /workspace/uki.efi /workspace/kernel
  kernel_digests=$(/signify/bin/python3 /scripts/get-pe-digest.py --json /workspace/kernel)
  jq -n --argjson shim "$shim_digests" --argjson uki "$uki_digests" --argjson kernel "$kernel_digests" '
    {
      "shim": $shim,
      "uki": $uki,
      "kernel": $kernel
    }' >/workspace/digests.json

  # Move all local files into the /images mount
  mv /workspace/node.raw                        "/images/$ARCH.new/node.raw"
  mv /workspace/root.img                        "/images/$ARCH.new/root.img"
  mv /workspace/uki.efi                         "/images/$ARCH.new/uki.efi"
  cp /usr/lib/shim/shim${shimsuffix}.efi.signed "/images/$ARCH.new/shim.efi"
  cp /usr/lib/shim/mm${shimsuffix}.efi.signed   "/images/$ARCH.new/mm.efi"
  mv /workspace/digests.json                    "/images/$ARCH.new/digests.json"

  # Move current node image to old, move new images from tmp to current
  rm -rf "/images/$ARCH.old"
  [[ ! -e /images/$ARCH ]] || mv "/images/$ARCH" "/images/$ARCH.old"
  mv "/images/$ARCH.new" "/images/$ARCH"

  [[ -z "$CHOWN" ]] || chown -R "$CHOWN" "/images/$ARCH"
}

main "$@"
