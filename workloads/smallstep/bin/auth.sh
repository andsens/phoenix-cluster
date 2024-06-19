#!/usr/bin/env bash
# shellcheck source-path=../../..
set -Eeo pipefail; shopt -s inherit_errexit
PKGROOT=$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../..")

main() {
  source "$PKGROOT/.upkg/records.sh/records.sh"
  source "$PKGROOT/.upkg/path-tools/path-tools.sh"
  PATH=$(path_prepend "$PKGROOT/.upkg/.bin")
  # shellcheck source=workloads/settings/lib/settings-env.shellcheck.sh
  source "$PKGROOT/workloads/settings/lib/settings-env.sh"
  eval_settings

  DOC="auth - Manage cluster authentication
Usage:
  auth [options] init
  auth [options] setup
  auth [options] renew
  auth [options] kubectl-cert

Options:
  -u --username NAME  The Kubernetes username [default: system:admin]
"
# docopt parser below, refresh this parser with `docopt.sh auth.sh`
# shellcheck disable=2016,2086,2317,1090,1091,2034
docopt() { local v='2.0.1'; source \
"$PKGROOT/.upkg/docopt-lib-v$v/docopt-lib.sh" "$v" || { ret=$?;printf -- "exit \
%d\n" "$ret";exit "$ret";};set -e;trimmed_doc=${DOC:0:221};usage=${DOC:37:104}
digest=8184f;options=('-u --username 1');node_0(){ value __username 0;}
node_1(){ switch init a:init;};node_2(){ switch setup a:setup;};node_3(){
switch renew a:renew;};node_4(){ switch kubectl_cert a:kubectl-cert;};node_5(){
sequence 6 1;};node_6(){ optional 0;};node_7(){ sequence 6 2;};node_8(){
sequence 6 3;};node_9(){ sequence 6 4;};node_10(){ choice 5 7 8 9;};cat <<<' \
docopt_exit() { [[ -n $1 ]] && printf "%s\n" "$1" >&2;printf "%s\n" \
"${DOC:37:104}" >&2;exit 1;}';local varnames=(__username init setup renew \
kubectl_cert) varname;for varname in "${varnames[@]}"; do unset "var_$varname"
done;parse 10 "$@";local p=${DOCOPT_PREFIX:-''};for varname in \
"${varnames[@]}"; do unset "$p$varname";done;eval $p'__username=${var___userna'\
'me:-system:admin};'$p'init=${var_init:-false};'$p'setup=${var_setup:-false};'\
$p'renew=${var_renew:-false};'$p'kubectl_cert=${var_kubectl_cert:-false};'
local docopt_i=1;[[ $BASH_VERSION =~ ^4.3 ]] && docopt_i=2;for \
((;docopt_i>0;docopt_i--)); do for varname in "${varnames[@]}"; do declare -p \
"$p$varname";done;done;}
# docopt parser above, complete command for generating this parser is `docopt.sh --library='"$PKGROOT/.upkg/docopt-lib-v$v/docopt-lib.sh"' auth.sh`
  eval "$(docopt "$@")"

  export STEPPATH=${STEPPATH:-$(step path --base)}
  mkdir -p "$STEPPATH"

  # shellcheck disable=SC2154
  local context \
    key_path="$STEPPATH/$__username.key" \
    cert_path="$STEPPATH/$__username.crt"

  # shellcheck disable=2154
  if $init; then

    step crypto keypair --no-password --insecure "$key_path.pub" "$key_path"
    info "Add the following to settings.yaml in the 'cluster:' section:"
    printf "  adminPubkey: |-\n%s" "$(sed 's/^/    /' <"$key_path.pub")"

  elif $renew; then

    step ca renew --context home-cluster-kube-api --force "$cert_path" "$key_path"
    sign_ssh_pubkeys home-cluster-pki $ADMIN_USERNAME

  elif $kubectl_cert; then

    ! step certificate needs-renewal "$cert_path" 2>/dev/null || \
      step ca renew --context home-cluster-kube-api --force "$cert_path" "$key_path" 2>/dev/null
    # shellcheck disable=SC2016
    yq \
      --arg cert "$(cat "$cert_path")" \
      --arg key "$(cat "$key_path")" \
      '.status.clientCertificateData=$cert | .status.clientKeyData=$key' \
      <<<'{"apiVersion": "client.authentication.k8s.io/v1beta1","kind": "ExecCredential"}'

  elif $setup; then

    OLD_KUBECONFIG=$KUBECONFIG

    local profile ca_url fingerprint config_path config

    ################################
    ### Setup kube client API CA ###
    ################################
    context=home-cluster-kube-api
    info "Bootstrapping Smallstep %s context" $context
    ca_url=https://$CLUSTER_KUBEAPISERVERCLIENTCA_FIXEDIPV4:9001
    fingerprint=$(step certificate fingerprint <(curl -s --insecure "$ca_url/roots.pem")) # TOFU for the kube-api CA
    step ca bootstrap --context $context --force --ca-url="$ca_url" --fingerprint="$fingerprint"

    # home-cluster-kube-api context/profile setup
    profile=$context
    config_path=$(step path --profile $profile)/config/defaults.json
    config=$(jq --arg key "$key_path" '.key=$key' <<<'{}')
    printf "%s\n" "$config" >"$config_path"

    # Create a signed kubernetes client API certificate
    step ca sign --context $context --force --provisioner admin \
      --token="$(step ca token system:admin --offline --provisioner admin --key="$key_path")" \
      <(step certificate create --csr --key="$key_path" --force "$__username" /dev/stdout) "$cert_path"

    # Switch to authenticating via the kube-api client CA provisioner
    config=$(jq --arg key "$key_path" --arg cert "$cert_path" '.["x5c-key"] = $key | .["x5c-cert"] = $cert' <<<'{}')
    printf "%s\n" "$config" >"$config_path"

    #########################
    ### Setup kube config ###
    #########################
    local kube_config_path=$HOME/.kube/home-cluster.yaml kube_cluster=home-cluster kube_api_hostname kube_api_addr kube_context
    kube_api_hostname=$(yq -r '[.nodes[] | select((.["node-label"] // [])[] | contains("node-role.cluster.local/control-plane=true"))] | first | .hostname' "$PKGROOT/settings.yaml")
    kube_context=home-cluster
    kube_api_addr="https://$kube_api_hostname:6443"
    kubectl config --kubeconfig "$kube_config_path" set-cluster home-cluster \
      --server="$kube_api_addr" \
      --embed-certs \
      --certificate-authority=<(
        c=$(step certificate inspect --insecure --format pem "$kube_api_addr") && printf -- "-%s\n" "${c##*$'-\n-'}" # TOFU again :-/
      )
    kubectl config --kubeconfig "$kube_config_path" set-credentials "$__username@$kube_cluster" \
      --exec-api-version="client.authentication.k8s.io/v1beta1" \
      --exec-command="$PKGROOT/workloads/smallstep/bin/auth.sh" \
      --exec-arg=kubectl-cert
    kubectl config --kubeconfig "$kube_config_path" set-context $kube_context \
      --cluster "$kube_cluster" --user "$__username@$kube_cluster"

    export KUBECONFIG=$kube_config_path

    ##############################
    ### Setup the home-cluster ###
    ##############################
    context=home-cluster-pki
    info "Bootstrapping Smallstep %s context" $context
    ca_url=https://$CLUSTER_SMALLSTEP_FIXEDIPV4:9000
    # Retrieve the fingerprint by connecting to kubernetes, no TOFU needed
    fingerprint=$(step certificate fingerprint <(kubectl --context "$kube_context" -n smallstep get secret smallstep-root -o=jsonpath='{.data.tls\.crt}' | base64 -d))
    step ca bootstrap --context $context --force --ca-url "$ca_url" --fingerprint="$fingerprint"

    # home-cluster-pki context/profile setup
    profile=$context
    config_path=$(step path --profile $profile)/config/defaults.json
    config=$(jq --arg key "$key_path" --arg crt "$cert_path" '.["x5c-key"]=$key | .["x5c-cert"]=$crt' <"$config_path")
    printf "%s\n" "$config" >"$config_path"

    ####################
    ### Trust SSH CA ###
    ####################
    local hosts="*.local" known_hosts_path="$HOME/.ssh/known_hosts"
    info "Trusting SSH host keys signed by Smallstep"
    # `step ssh config` doesn't work right with --context or --profile: https://github.com/smallstep/cli/issues/1206
    step context select "$context"
    local expected_known_hosts_line current_known_hosts_line
    expected_known_hosts_line="@cert-authority $hosts $(step ssh config --context="$context" --host --roots)"
    if [[ -e "$known_hosts_path" ]] && current_known_hosts_line=$(grep -F "@cert-authority $hosts " "$known_hosts_path"); then
      if [[ $current_known_hosts_line != "$expected_known_hosts_line" ]]; then
        warning "Replacing '@cert-authority $hosts' line in %s, it does not match the current key" "$known_hosts_path"
        local all_other_lines
        all_other_lines=$(grep -vF "@cert-authority $hosts " "$known_hosts_path")
        printf "%s\n%s\n" "$all_other_lines" "$expected_known_hosts_line" >"$known_hosts_path"
      else
        info "The '@cert-authority $hosts' line in %s exists and is correct" "$known_hosts_path"
      fi
    else
      mkdir -p "$(dirname "$known_hosts_path")"
      info "Appending '@cert-authority $hosts ...' to %s" "$known_hosts_path"
      printf "@cert-authority $hosts %s\n" "$expected_known_hosts_line" >>"$known_hosts_path"
    fi

    ########################
    ### Sign SSH pubkeys ###
    ########################
    sign_ssh_pubkeys $context $ADMIN_USERNAME

    if [[ $OLD_KUBECONFIG != *"$HOME/.kube/home-cluster.yaml"* ]]; then
      warning "Remember to add the new client config to your \$KUBECONFIG with KUBECONFIG=\$KUBECONFIG:\$HOME/.kube/home-cluster.yaml"
    fi

  fi
}

sign_ssh_pubkeys() {
  local context=$1 principal=$2
  info "Signing all pubkeys in %s" "$HOME/.ssh"
  for pubkey in "$HOME/.ssh"/id_*.pub; do
    [[ $pubkey != *-cert.pub ]] || continue
    step ssh certificate --context "$context" --force --sign "$principal" "$pubkey"
  done
}

main "$@"