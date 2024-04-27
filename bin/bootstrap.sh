#!/usr/bin/env bash
# shellcheck source-path=../
set -eo pipefail; shopt -s inherit_errexit
PKGROOT=$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/..")

main() {
  source "$PKGROOT/lib/common.sh"

  DOC="bootstrap.sh - Bootstrap images
Usage:
  bootstrap.sh [options] MACHINE

Options:
  --cachepath=PATH  Path to the cache dir [default: \$PKGROOT/cache]
"
# docopt parser below, refresh this parser with `docopt.sh bootstrap.sh`
# shellcheck disable=2016,1090,1091,2034
docopt() { source "$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh" '1.0.0' || {
ret=$?; printf -- "exit %d\n" "$ret"; exit "$ret"; }; set -e
trimmed_doc=${DOC:0:149}; usage=${DOC:32:39}; digest=bf50b; shorts=('')
longs=(--cachepath); argcounts=(1); node_0(){ value __cachepath 0; }; node_1(){
value MACHINE a; }; node_2(){ optional 0; }; node_3(){ optional 2; }; node_4(){
required 3 1; }; node_5(){ required 4; }; cat <<<' docopt_exit() {
[[ -n $1 ]] && printf "%s\n" "$1" >&2; printf "%s\n" "${DOC:32:39}" >&2; exit 1
}'; unset var___cachepath var_MACHINE; parse 5 "$@"
local prefix=${DOCOPT_PREFIX:-''}; unset "${prefix}__cachepath" \
"${prefix}MACHINE"
eval "${prefix}"'__cachepath=${var___cachepath:-'"'"'$PKGROOT/cache'"'"'}'
eval "${prefix}"'MACHINE=${var_MACHINE:-}'; local docopt_i=1
[[ $BASH_VERSION =~ ^4.3 ]] && docopt_i=2; for ((;docopt_i>0;docopt_i--)); do
declare -p "${prefix}__cachepath" "${prefix}MACHINE"; done; }
# docopt parser above, complete command for generating this parser is `docopt.sh --library='"$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh"' bootstrap.sh`
  eval "$(docopt "$@")"
  confirm_machine_id bootstrapper

  # shellcheck disable=2153
  local env=env ln=ln rm=rm imgpath=$PKGROOT/images/$MACHINE.raw
  if [[ $UID != 0 ]]; then
    env="sudo env"
    ln="sudo ln"
    rm="sudo rm"
    chown="sudo chown"
  fi
  [[ $__cachepath != "\$PKGROOT/cache" ]] || __cachepath=$PKGROOT/cache
  mkdir -p "$PKGROOT/images" "$PKGROOT/logs" "$__cachepath"

  if ! is_machine_id bootstrapper; then
    [[ -L "$PKGROOT/logs/fai" ]] || ln -s "/var/log/fai" "$PKGROOT/logs/fai"
  else
    $rm -rf "$PKGROOT/logs/fai"
    $ln -s "$PKGROOT/logs/fai" "/var/log/fai"
  fi
  # shellcheck disable=SC2086
  $env - \
    "PATH=$PATH" \
    "PKGROOT=$PKGROOT" \
    "CACHEPATH=$__cachepath" \
    fai-diskimage --cspace "$PKGROOT/bootstrap" --new --size "$(get_setting "machines[\"$HOSTNAME\"].disksize")" --hostname "$MACHINE" "$imgpath"
  $chown "$(stat -c %u:%g "$(dirname "$imgpath")")" "$imgpath"
  if [[ $__cachepath = "$PKGROOT"/* ]]; then
    $chown -R "$(stat -c %u:%g "$(dirname "$__cachepath")")" "$__cachepath"
  fi
}

main "$@"
