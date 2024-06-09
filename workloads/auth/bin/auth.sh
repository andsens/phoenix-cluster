#!/usr/bin/env bash
# shellcheck source-path=../../..
set -Eeo pipefail; shopt -s inherit_errexit
PKGROOT=$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../..")

main() {
  # shellcheck disable=SC1091
  source "$PKGROOT/.upkg/records.sh/records.sh"
  # shellcheck disable=SC1091
  source "$PKGROOT/.upkg/path-tools/path-tools.sh"
  PATH=$(path_prepend "$PKGROOT/.upkg/.bin")
  source "$PKGROOT/workloads/auth/lib/auth.sh"
  # shellcheck source=workloads/settings/lib/settings-env.shellcheck.sh
  source "$PKGROOT/workloads/settings/lib/settings-env.sh"
  eval_settings

  DOC="auth - Manage cluster authentication
Usage:
  auth setup CONFIG
  auth renew

Commands:
setup:
  Requires the kube config generated by the smallstep bootstrapper, which is
  located in smallstep/step-ca-certs/home-cluster.yaml on the workloads share.
  It will configure this workstation to:
    * Create a new kube config in \$HOME/.kube
    * Bootstrap the smallstep client to trust the cluster PKI
    * Bootstrap the smallstep client to trust the kube-apiserver client ca
    * Log docker in to the cluster CR
    * Trust SSH host certificates
    * Create SSH client certificates for any id_*.pub file in \$HOME/.ssh
  Existing files will be replaced.

renew:
  Renew the kube-apiserver client certificate
"
# docopt parser below, refresh this parser with `docopt.sh auth.sh`
# shellcheck disable=2016,2086,2317,1090,1091,2034
docopt() { local v='2.0.1'; source \
"$PKGROOT/.upkg/docopt-lib-v$v/docopt-lib.sh" "$v" || { ret=$?;printf -- "exit \
%d\n" "$ret";exit "$ret";};set -e;trimmed_doc=${DOC:0:708};usage=${DOC:37:39}
digest=9b984;options=();node_0(){ value CONFIG a;};node_1(){ switch setup \
a:setup;};node_2(){ switch renew a:renew;};node_3(){ sequence 1 0;};node_4(){
choice 3 2;};cat <<<' docopt_exit() { [[ -n $1 ]] && printf "%s\n" "$1" >&2
printf "%s\n" "${DOC:37:39}" >&2;exit 1;}';local varnames=(CONFIG setup renew) \
varname;for varname in "${varnames[@]}"; do unset "var_$varname";done;parse 4 \
"$@";local p=${DOCOPT_PREFIX:-''};for varname in "${varnames[@]}"; do unset \
"$p$varname";done;eval $p'CONFIG=${var_CONFIG:-};'$p'setup=${var_setup:-false}'\
';'$p'renew=${var_renew:-false};';local docopt_i=1;[[ $BASH_VERSION =~ ^4.3 ]] \
&& docopt_i=2;for ((;docopt_i>0;docopt_i--)); do for varname in \
"${varnames[@]}"; do declare -p "$p$varname";done;done;}
# docopt parser above, complete command for generating this parser is `docopt.sh --library='"$PKGROOT/.upkg/docopt-lib-v$v/docopt-lib.sh"' auth.sh`
  eval "$(docopt "$@")"

  # shellcheck disable=2154
  if $setup; then
    export STEPPATH=${STEPPATH:-$(step path --base)}
    OLD_KUBECONFIG=$KUBECONFIG
    [[ -r "$CONFIG" ]] || fatal "The file %s does not exist or is not readable" "$CONFIG"

    extract_kube_config_to_smallstep home-cluster-kube-api "$CONFIG"
    setup_kube_config home-cluster-kube-api home-cluster home-cluster
    setup_smallstep_context home-cluster-pki home-cluster "pki.$CLUSTER_DOMAIN:9000" smallstep smallstep-root
    setup_smallstep_context home-cluster-kube-api home-cluster "pki-kube.$CLUSTER_DOMAIN:9001" smallstep kube-apiserver-client-ca
    setup_docker_cred_helper "cr.$CLUSTER_DOMAIN" "$DOCKER_CRED_HELPER" "$HOME/.docker/config.json"
    setup_ssh_host_cert_trust home-cluster-pki "*.local" "$HOME/.ssh/known_hosts"
    sign_ssh_client_keys home-cluster-pki "$ADMIN_USERNAME"
    renew_client_cert home-cluster-kube-api

    if [[ $CONFIG != "$HOME/.kube/home-cluster.yaml" ]]; then
      info "Removing %s" "$CONFIG"
      rm "$CONFIG"
    fi
    if [[ $OLD_KUBECONFIG != *"$HOME/.kube/home-cluster.yaml"* ]]; then
      warning "Remember to add the new client config to your \$KUBECONFIG with KUBECONFIG=\$KUBECONFIG:\$HOME/.kube/home-cluster.yaml"
    fi
  elif $renew; then
    renew_client_cert home-cluster-kube-api
  fi
}

main "$@"
