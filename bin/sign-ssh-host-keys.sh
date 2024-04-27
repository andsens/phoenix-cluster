#!/usr/bin/env bash
# shellcheck source-path=..
set -eo pipefail; shopt -s inherit_errexit
PKGROOT=$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/..")

main() {
  source "$PKGROOT/lib/common.sh"

  DOC="sign-ssh-host-keys - Sign SSH host keys with smallstep
Usage:
  sign-ssh-host-keys
"
# docopt parser below, refresh this parser with `docopt.sh sign-ssh-host-keys.sh`
# shellcheck disable=2016,1090,1091,2034
docopt() { source "$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh" '1.0.0' || {
ret=$?; printf -- "exit %d\n" "$ret"; exit "$ret"; }; set -e
trimmed_doc=${DOC:0:82}; usage=${DOC:55:27}; digest=2400d; shorts=(); longs=()
argcounts=(); node_0(){ required ; }; node_1(){ required 0; }
cat <<<' docopt_exit() { [[ -n $1 ]] && printf "%s\n" "$1" >&2
printf "%s\n" "${DOC:55:27}" >&2; exit 1; }'; unset ; parse 1 "$@"; return 0
local prefix=${DOCOPT_PREFIX:-''}; unset ; local docopt_i=1
[[ $BASH_VERSION =~ ^4.3 ]] && docopt_i=2; for ((;docopt_i>0;docopt_i--)); do
declare -p ; done; }
# docopt parser above, complete command for generating this parser is `docopt.sh --library='"$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh"' sign-ssh-host-keys.sh`
  eval "$(docopt "$@")"

  if [[ ! -e "$(step path)/certs/root_ca.crt" ]]; then
    step ca bootstrap \
      --ca-url "pki.$(get_setting cluster.dns.domain):9000" \
      --fingerprint "$(step certificate fingerprint <(kubectl -n smallstep get secret smallstep-root -o=jsonpath='{.data.tls\.crt}' | base64 -d))"
  fi
  local ssh_host_provisioner_password
  ssh_host_provisioner_password=$(kubectl -n smallstep get secret ssh-host-provisioner-password -o=jsonpath='{.data.password}' | base64 -d)
  step ssh certificate --host --sign --force --provisioner=ssh-host --provisioner-password-file=<(printf "%s" "$ssh_host_provisioner_password") \
    "$(hostname -f)" "/etc/ssh/ssh_host_ecdsa_key.pub"
  step ssh certificate --host --sign --force --provisioner=ssh-host --provisioner-password-file=<(printf "%s" "$ssh_host_provisioner_password") \
    "$(hostname -f)" "/etc/ssh/ssh_host_ed25519_key.pub"
  step ssh certificate --host --sign --force --provisioner=ssh-host --provisioner-password-file=<(printf "%s" "$ssh_host_provisioner_password") \
    "$(hostname -f)" "/etc/ssh/ssh_host_rsa_key.pub"
}

main "$@"