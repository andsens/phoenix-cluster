#!/usr/bin/env bash
# shellcheck source-path=../
set -eo pipefail; shopt -s inherit_errexit
PKGROOT=$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/..")

main() {
  source "$PKGROOT/.upkg/orbit-online/records.sh/records.sh"
  source "$PKGROOT/lib/settings.sh"
  source "$PKGROOT/lib/machine-id.sh"
  source "$PKGROOT/lib/mount.sh"

  DOC="boot-image.sh - Boot images
Usage:
  boot-image.sh HOSTNAME
"
# docopt parser below, refresh this parser with `docopt.sh boot-image.sh`
# shellcheck disable=2016,1090,1091,2034
docopt() { source "$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh" '1.0.0' || {
ret=$?; printf -- "exit %d\n" "$ret"; exit "$ret"; }; set -e
trimmed_doc=${DOC:0:59}; usage=${DOC:28:31}; digest=022a1; shorts=(); longs=()
argcounts=(); node_0(){ value HOSTNAME a; }; node_1(){ required 0; }; node_2(){
required 1; }; cat <<<' docopt_exit() { [[ -n $1 ]] && printf "%s\n" "$1" >&2
printf "%s\n" "${DOC:28:31}" >&2; exit 1; }'; unset var_HOSTNAME; parse 2 "$@"
local prefix=${DOCOPT_PREFIX:-''}; unset "${prefix}HOSTNAME"
eval "${prefix}"'HOSTNAME=${var_HOSTNAME:-}'; local docopt_i=1
[[ $BASH_VERSION =~ ^4.3 ]] && docopt_i=2; for ((;docopt_i>0;docopt_i--)); do
declare -p "${prefix}HOSTNAME"; done; }
# docopt parser above, complete command for generating this parser is `docopt.sh --library='"$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh"' boot-image.sh`
  eval "$(docopt "$@")"

  local imgpath=$PKGROOT/images/$HOSTNAME.raw
  kvm -bios /usr/share/ovmf/OVMF.fd \
    -k en-us -smp 2 -cpu host -m 2000 -name "$HOSTNAME" \
    -boot order=c -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
    -drive "file=$imgpath,if=none,format=raw,id=nvme1" -device nvme,serial=SN123450001,drive=nvme1
}

main "$@"
