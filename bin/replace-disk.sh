#!/usr/bin/env bash
# shellcheck source-path=..
set -eo pipefail; shopt -s inherit_errexit
PKGROOT=$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/..")

main() {
  source "$PKGROOT/lib/common.sh"

  DOC="replace-disk.sh - Replace a VM disk in TrueNAS
Usage:
  replace-disk.sh [options] MACHINE [IMGPATH]

Options:
  -S --no-start  Don't start the VM if it was stopped to replace the disk
"
# docopt parser below, refresh this parser with `docopt.sh replace-disk.sh`
# shellcheck disable=2016,1090,1091,2034
docopt() { source "$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh" '1.0.0' || {
ret=$?; printf -- "exit %d\n" "$ret"; exit "$ret"; }; set -e
trimmed_doc=${DOC:0:183}; usage=${DOC:47:52}; digest=3498f; shorts=(-S)
longs=(--no-start); argcounts=(0); node_0(){ switch __no_start 0; }; node_1(){
value MACHINE a; }; node_2(){ value IMGPATH a; }; node_3(){ optional 0; }
node_4(){ optional 3; }; node_5(){ optional 2; }; node_6(){ required 4 1 5; }
node_7(){ required 6; }; cat <<<' docopt_exit() {
[[ -n $1 ]] && printf "%s\n" "$1" >&2; printf "%s\n" "${DOC:47:52}" >&2; exit 1
}'; unset var___no_start var_MACHINE var_IMGPATH; parse 7 "$@"
local prefix=${DOCOPT_PREFIX:-''}; unset "${prefix}__no_start" \
"${prefix}MACHINE" "${prefix}IMGPATH"
eval "${prefix}"'__no_start=${var___no_start:-false}'
eval "${prefix}"'MACHINE=${var_MACHINE:-}'
eval "${prefix}"'IMGPATH=${var_IMGPATH:-}'; local docopt_i=1
[[ $BASH_VERSION =~ ^4.3 ]] && docopt_i=2; for ((;docopt_i>0;docopt_i--)); do
declare -p "${prefix}__no_start" "${prefix}MACHINE" "${prefix}IMGPATH"; done; }
# docopt parser above, complete command for generating this parser is `docopt.sh --library='"$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh"' replace-disk.sh`
  eval "$(docopt "$@")"
  confirm_machine_id truenas

  cache_all_vms

  local imgpath vmname diskpath
  # shellcheck disable=2153
  vmname=$(get_setting "machines[\"$MACHINE\"].vm")
  imgpath=${IMGPATH:-$PKGROOT/images/$MACHINE.raw}
  diskpath=$(get_setting "machines[\"$MACHINE\"].disk")

  local start_again=false
  # shellcheck disable=2154
  $__no_start || start_again=true

  # shellcheck disable=2153
  replace_vm_disk "$vmname" "$imgpath" "$diskpath" "$start_again"
}

main "$@"
