#!/usr/bin/env bash

set -eo pipefail; shopt -s inherit_errexit
PKGROOT=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
PATH=$("$PKGROOT/.upkg/.bin/path_prepend" "$PKGROOT/.upkg/.bin")

main() {
  source "$PKGROOT/.upkg/orbit-online/records.sh/records.sh"
  source "$PKGROOT/.upkg/orbit-online/collections.sh/collections.sh"

  DOC="bootstrap.sh - Bootstrap k3s cluster images
Usage:
  bootstrap create HOSTNAME
  bootstrap mount HOSTNAME
  bootstrap boot HOSTNAME
"
# docopt parser below, refresh this parser with `docopt.sh bootstrap.sh`
# shellcheck disable=2016,1090,1091,2034
docopt() { source "$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh" '1.0.0' || {
ret=$?; printf -- "exit %d\n" "$ret"; exit "$ret"; }; set -e
trimmed_doc=${DOC:0:131}; usage=${DOC:44:87}; digest=8a844; shorts=(); longs=()
argcounts=(); node_0(){ value HOSTNAME a; }; node_1(){ _command create; }
node_2(){ _command mount; }; node_3(){ _command boot; }; node_4(){ required 1 0
}; node_5(){ required 2 0; }; node_6(){ required 3 0; }; node_7(){ either 4 5 6
}; node_8(){ required 7; }; cat <<<' docopt_exit() {
[[ -n $1 ]] && printf "%s\n" "$1" >&2; printf "%s\n" "${DOC:44:87}" >&2; exit 1
}'; unset var_HOSTNAME var_create var_mount var_boot; parse 8 "$@"
local prefix=${DOCOPT_PREFIX:-''}; unset "${prefix}HOSTNAME" "${prefix}create" \
"${prefix}mount" "${prefix}boot"; eval "${prefix}"'HOSTNAME=${var_HOSTNAME:-}'
eval "${prefix}"'create=${var_create:-false}'
eval "${prefix}"'mount=${var_mount:-false}'
eval "${prefix}"'boot=${var_boot:-false}'; local docopt_i=1
[[ $BASH_VERSION =~ ^4.3 ]] && docopt_i=2; for ((;docopt_i>0;docopt_i--)); do
declare -p "${prefix}HOSTNAME" "${prefix}create" "${prefix}mount" \
"${prefix}boot"; done; }
# docopt parser above, complete command for generating this parser is `docopt.sh --library='"$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh"' bootstrap.sh`
  eval "$(docopt "$@")"

  if [[ $UID != 0 ]]; then
    fatal "Run with sudo"
  fi
  : "${SUDO_UID:?"\$SUDO_UID is not set, run with sudo"}"

  sudo -u "#$SUDO_UID" mkdir -p "$PKGROOT/images"
  # shellcheck disable=SC2154
  if $create; then
    create_image "$HOSTNAME"
  elif $mount; then
    mount_image "$HOSTNAME"
  elif $boot; then
    boot_image "$HOSTNAME"
  fi
}

get_image_path() {
  local hostname=$1
  printf "%s/images/%s.raw" "$PKGROOT" "$hostname"
}

create_image() {
  local hostname=$1 image_path
  image_path=$(get_image_path "$hostname")
  mkdir -p "$PKGROOT/logs"
  ln -s "/var/log/fai/$hostname/last" "$PKGROOT/logs/$hostname"
  env - \
    "PATH=$PATH" \
    "PKGROOT=$PKGROOT" \
    fai-diskimage --verbose --cspace "$PKGROOT/config" --new --size 10G --hostname "$hostname" "$image_path"
  chown "$SUDO_UID:$SUDO_UID" "$image_path"
}

mount_image() {
  local hostname=$1 mountpath image_path devpath
  mountpath=$PKGROOT/mnt/$hostname
  mkdir -p "$mountpath"
  image_path=$(get_image_path "$hostname")
  devpath=$(losetup --show --find --partscan "$image_path")
  # shellcheck disable=SC2064
  trap "umount \"$mountpath/boot/efi\"; umount \"$mountpath\"; losetup --detach \"$devpath\"; exit 1" EXIT SIGINT SIGTERM
  mount "${devpath}p2" "$mountpath"
  mount "${devpath}p1" "$mountpath/boot/efi"
  info "image %s mounted at %s, press <ENTER> to unmount" "${image_path#"$PKGROOT/"}" "${mountpath#"$PKGROOT/"}"
  local _read
  read -r _read
  umount "$mountpath/boot/efi" "$mountpath"
  losetup --detach "$devpath"
  trap "" EXIT
}

boot_image() {
  local hostname=$1 image_path
  image_path=$(get_image_path "$hostname")
  kvm -bios /usr/share/ovmf/OVMF.fd \
    -k en-us -smp 2 -cpu host -m 2000 -name "$hostname" \
    -boot order=c -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
    -drive "file=$image_path,if=none,format=raw,id=nvme1" -device nvme,serial=SN123450001,drive=nvme1
}

main "$@"
