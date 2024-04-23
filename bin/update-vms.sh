#!/usr/bin/env bash
# shellcheck source-path=..
set -eo pipefail; shopt -s inherit_errexit
PKGROOT=$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/..")

main() {
  source "$PKGROOT/lib/common.sh"

  DOC="update-vms.sh - Bootstrap a VM disk image and replace the current one
Usage:
  update-vms.sh [options] MACHINE...
"
# docopt parser below, refresh this parser with `docopt.sh update-vms.sh`
# shellcheck disable=2016,1090,1091,2034,2154
docopt() { source "$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh" '1.0.0' || {
ret=$?; printf -- "exit %d\n" "$ret"; exit "$ret"; }; set -e
trimmed_doc=${DOC:0:113}; usage=${DOC:70:43}; digest=e0342; shorts=(); longs=()
argcounts=(); node_0(){ value MACHINE a true; }; node_1(){ optional ; }
node_2(){ optional 1; }; node_3(){ oneormore 0; }; node_4(){ required 2 3; }
node_5(){ required 4; }; cat <<<' docopt_exit() {
[[ -n $1 ]] && printf "%s\n" "$1" >&2; printf "%s\n" "${DOC:70:43}" >&2; exit 1
}'; unset var_MACHINE; parse 5 "$@"; local prefix=${DOCOPT_PREFIX:-''}
unset "${prefix}MACHINE"; if declare -p var_MACHINE >/dev/null 2>&1; then
eval "${prefix}"'MACHINE=("${var_MACHINE[@]}")'; else
eval "${prefix}"'MACHINE=()'; fi; local docopt_i=1
[[ $BASH_VERSION =~ ^4.3 ]] && docopt_i=2; for ((;docopt_i>0;docopt_i--)); do
declare -p "${prefix}MACHINE"; done; }
# docopt parser above, complete command for generating this parser is `docopt.sh --library='"$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh"' update-vms.sh`
  eval "$(docopt "$@")"
  confirm_machine_id truenas

  log_forward_to_journald true

  local bootstrapper_vm
  bootstrapper_vm=$(get_setting "machines.bootstrapper.vm")

  cache_all_vms

  # shellcheck disable=2086
  printf -- '#!/usr/bin/env bash\nMACHINE=(%s)\n' "${MACHINE[*]}" > "$PKGROOT/bootstrap-vms.args.sh"
  # shellcheck disable=2064
  trap "rm -f \"$PKGROOT/bootstrap-vms.args.sh\"" EXIT

  # shellcheck disable=2154
  start_vm "$bootstrapper_vm"
  # shellcheck disable=2064
  trap "rm -f \"$PKGROOT/bootstrap-vms.args.sh\"; stop_vm \"$bootstrapper_vm\"" EXIT

  info "Waiting for bootstrapping to complete"
  while [[ -e "$PKGROOT/bootstrap-vms.args.sh" ]]; do
    sleep 1
  done
  info "Bootstrapping completed"
  stop_vm "$bootstrapper_vm"
  trap "" EXIT

  local machine diskpath ret=0 latest_imgpath current_imgpath
  for machine in "${MACHINE[@]}"; do
    vmname=$(get_setting "machines[\"$machine\"].vm")
    diskpath=$(get_setting "machines[\"$machine\"].disk")

    latest_imgpath="$PKGROOT/images/$machine.raw"
    current_imgpath="$PKGROOT/images/$machine.current.raw"
    if [[ -e "$latest_imgpath" ]]; then
      info "Image for '%s' found, replacing disk and then renaming to '%s'" "$vmname" "$current_imgpath"
      local res=0
      replace_vm_disk "$vmname" "$latest_imgpath" "$diskpath" || res=$?
      if [[ $res = 0 ]]; then
        info "Successfully replaced disk for '%s', renaming image to .current.raw" "$vmname"
        mv "$latest_imgpath" "$current_imgpath"
      else
        error "Failed to replace disk for '%s'" "$vmname"
        ret=$res
      fi
    else
      error "Image for '%s' not found, '%s' failed to create an image" "$vmname" "$bootstrapper_vm"
      ret=1
    fi
  done
  if [[ $ret = 0 ]]; then
    info "Successfully replaced the disks on all of the specified VMs"
  else
    error "Failed to replace the disks on some VMs"
  fi
  return $ret
}

main "$@"
