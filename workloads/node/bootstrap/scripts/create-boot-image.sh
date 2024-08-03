#!/usr/bin/env bash
# shellcheck source-path=../../../..
set -Eeo pipefail; shopt -s inherit_errexit
PKGROOT=/usr/local/lib/upkg

main() {
  source "$PKGROOT/.upkg/records.sh/records.sh"

  declare -A artifacts
  declare -A authentihashes
  declare -A sha256sums

  mkdir -p /workspace/root

  info "Extracting container export"
  for layer in $(jq -r '.[0].Layers[]' <(tar -xOf "/images/$VARIANT.new/node.tar" manifest.json)); do
    tar -xOf "/images/$VARIANT.new/node.tar" "$layer" | tar -xz -C /workspace/root
  done
  # During bootstrapping with kaniko these files can't be removed/overwritten,
  # instead we do it when creating the image
  rm /workspace/root/etc/hostname /workspace/root/etc/resolv.conf
  ln -sf ../run/systemd/resolve/stub-resolv.conf /workspace/root/etc/resolv.conf
  cp /assets/etc-hosts /workspace/root/etc/hosts

  #######################
  ### Create root.img ###
  #######################

  info "Creating squashfs image"

  # Move boot dir out of the way before creating squashfs image, but keep the mountpoint itself
  mv /workspace/root/boot /workspace/boot
  mkdir /workspace/root/boot

  local noprogress=
  [[ -t 1 ]] || noprogress=-no-progress
  mksquashfs /workspace/root /workspace/root.img -noappend -quiet $noprogress

  # Move boot dir back into place
  rm -rf /workspace/root/boot
  mv /workspace/boot /workspace/root/boot

  # Hash the root image so we can verify it during boot
  sha256sums[root.img]=$(sha256sum /workspace/root.img | cut -d ' ' -f1)

  artifacts[/workspace/root.img]=/images/$VARIANT.new/root.img
  artifacts[/workspace/root/boot/initrd.img]=/images/$VARIANT.new/initrd.img


  #####################
  ### node-settings ###
  #####################

  info "Generating node settings"
  mkdir /workspace/node-settings
  local file node_settings_size_b=0
  for file in /node-settings/*; do
    node_settings_size_b=$(( node_settings_size_b + $(stat -c %s "$file") ))
    cp "$file" "/workspace/node-settings/$(basename "$file" | sed s/:/-/g)"
  done

  ######################
  ### Build boot.img ###
  ######################

  if [[ $VARIANT = rpi* ]]; then

    # The last "console=" wins with respect to initramfs stdout/stderr output
    printf "console=ttyS0,115200 console=tty0 root=/run/initramfs/root.img root_sha256=%s noresume" "${sha256sums[root.img]}" > /workspace/cmdline.txt

    # Adjust config.txt for being embedded in boot.img
    sed 's/boot_ramdisk=1/auto_initramfs=1/' <"/assets/config-${VARIANT}.txt" >/workspace/config.txt
    cp "/assets/config-${VARIANT}.txt" /workspace/config-netboot.txt
    artifacts[/workspace/config-netboot.txt]=/images/$VARIANT.new/config.txt

    local file_size fs_table_size_b firmware_size_b=0
    fs_table_size_b=$(( 1024 * 1024 )) # Total guess, but should be enough
    while IFS= read -d $'\n' -r file_size; do
      firmware_size_b=$(( firmware_size_b + file_size ))
    done < <(find /workspace/root/boot/firmware -type f -exec stat -c %s \{\} \;)
    disk_size_kib=$((
      (
        fs_table_size_b +
        $(stat -c %s "/assets/config-${VARIANT}.txt") +
        $(stat -c %s /workspace/cmdline.txt) +
        node_settings_size_b +
        firmware_size_b +
        (1024 * 1024) +
        1023
      ) / 1024
    ))

    (( disk_size_kib <= 1024 * 64 )) || \
      warning "boot.img size exceeds 64MiB (%dMiB). Transferring the image via TFTP will result in its truncation" "$((disk_size_kib / 1024))"

    guestfish -xN /workspace/boot.img=disk:${disk_size_kib}K -- <<EOF
mkfs fat /dev/sda
mount /dev/sda /

copy-in /workspace/config.txt /
copy-in /workspace/cmdline.txt /
copy-in /workspace/root/boot/firmware /
glob mv /firmware/* /
rm-rf /firmware
mkdir-p /home-cluster
copy-in /workspace/node-settings /home-cluster/
EOF

    sha256sums[boot.img]=$(sha256sum /workspace/boot.img | cut -d ' ' -f1)
    artifacts[/workspace/boot.img]=/images/$VARIANT.new/boot.img

  fi

  ############################
  ### Unified kernel image ###
  ############################

  # Raspberry PI does not implement UEFI, so skip building a UKI
  if [[ $VARIANT != rpi* ]]; then

    info "Creating unified kernel image"

    local kernver
    kernver=$(echo /workspace/root/lib/modules/*)
    kernver=${kernver#'/workspace/root/lib/modules/'}

    chroot /workspace/root /lib/systemd/ukify build \
      --uname="$kernver" \
      --linux="boot/vmlinuz" \
      --initrd="boot/initrd" \
      --cmdline="root=/run/initramfs/root.img root_sha256=${sha256sums[root.img]} noresume" \
      --output=/boot/uki.efi

    local uki_size_b
    uki_size_b=$(stat -c %s /workspace/root/boot/uki.efi)
    (( uki_size_b <= 1024 * 1024 * 64 )) || \
      warning "uki.efi size exceeds 64MiB (%dMiB). Transferring the image via TFTP will result in its truncation" "$((uki_size_b / 1024 / 1024))"

    artifacts[/workspace/root/boot/uki.efi]=/images/$VARIANT.new/uki.efi

    # Extract authentihashes used for PE signatures so we can use them for remote attestation
    authentihashes[uki.efi]=$(/signify/bin/python3 /scripts/get-pe-digest.py --json /workspace/root/boot/uki.efi)
    sha256sums[uki.efi]=$(sha256sum /workspace/root/boot/uki.efi | cut -d ' ' -f1)
    # See https://lists.freedesktop.org/archives/systemd-devel/2022-December/048694.html
    # as to why we also measure the embedded kernel
    objcopy -O binary --only-section=.linux /workspace/root/boot/uki.efi /workspace/uki-vmlinuz
    authentihashes[vmlinuz]=$(/signify/bin/python3 /scripts/get-pe-digest.py --json /workspace/uki-vmlinuz)
  fi

  ######################
  ### Build node.raw ###
  ######################

  if [[ $VARIANT != rpi* ]]; then

    local efisuffix
    case $VARIANT in
      amd64) efisuffix=x64 ;;
      arm64) efisuffix=aa64 ;;
      *) fatal "Unknown variant: %s" "$VARIANT" ;;
    esac

    local sector_size_b=512 gpt_size_b partition_offset_b partition_size_b disk_size_kib
    gpt_size_b=$((33 * sector_size_b))
    partition_offset_b=$((1024 * 1024))
    # efi * 2 : The EFI boot loader is copied to two different destinations
    # stat -c %s : Size in bytes of the file
    # ... (sector_size_b - 1) ) / sector_size_b * sector_size_b : Round to next sector
    partition_size_b=$((
      (
        fs_table_size_b +
        node_settings_size_b +
        $(stat -c %s /workspace/root/boot/uki.efi) +
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
copy-in /workspace/root/boot/uki.efi /EFI/BOOT/
mv /EFI/BOOT/uki.efi /EFI/BOOT/BOOT${efisuffix^^}.EFI

mkdir-p /home-cluster
copy-in /workspace/root.img /home-cluster/
copy-in /workspace/node-settings /home-cluster/
EOF

    artifacts[/workspace/node.raw]=/images/$VARIANT.new/node.raw

  fi

  ################################
  ### Generate/extract authentihashes ###
  ################################

  local key digests='{"sha256sums": {}, "authentihashes": {}}'
  for key in "${!sha256sums[@]}"; do
    digests=$(jq --arg key "$key" --arg sha256sums "${sha256sums[$key]}" '
      .sha256sums[$key] = $sha256sums' <<<"$digests"
    )
  done
  for key in "${!authentihashes[@]}"; do
    digests=$(jq --arg key "$key" --argjson authentihashes "${authentihashes[$key]}" '
      .authentihashes[$key] = $authentihashes' <<<"$digests"
    )
  done
  printf "%s\n" "$digests" >/workspace/digests.json

  artifacts[/workspace/digests.json]=/images/$VARIANT.new/digests.json

  ################
  ### Finalize ###
  ################

  # Finish up by moving everything to the right place in the most atomic way possible
  # as to avoid leaving anything in an incomplete state

  info "Moving UEFI disk, squashfs root, shim bootloader, mok manager, and unified kernel image EFI to shared volume"

  # Move all artifacts into the /images mount
  local src mv_failed=0
  for src in "${!artifacts[@]}"; do
    mv "$src" "${artifacts[$src]}" || mv_failed=$?
  done
  [[ $mv_failed -eq 0 ]] || return $mv_failed

  # Move current node image to old, move new images from tmp to current
  if [[ -e /images/$VARIANT ]]; then
    rm -rf "/images/$VARIANT.old"
    mv "/images/$VARIANT" "/images/$VARIANT.old"
  fi
  mv "/images/$VARIANT.new" "/images/$VARIANT"

  [[ -z "$CHOWN" ]] || chown -R "$CHOWN" "/images/$VARIANT"
}

main "$@"
