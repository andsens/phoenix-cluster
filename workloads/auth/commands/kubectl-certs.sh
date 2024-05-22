#!/usr/bin/env bash
# shellcheck source-path=../../../
set -Eeo pipefail; shopt -s inherit_errexit
PKGROOT=$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../..")

main() {
  source "$PKGROOT/lib/common.sh"
  source "$PKGROOT/workloads/auth/lib/auth.sh"
  # shellcheck disable=SC2016
  yq \
    --arg crt "$(cat "$(get_client_crt_path "$STEP_KUBE_API_CONTEXT")")" \
    --arg key "$(cat "$(get_client_key_path "$STEP_KUBE_API_CONTEXT")")" \
    '.status.clientCertificateData=$crt | .status.clientKeyData=$key' \
    <<<'{"apiVersion": "client.authentication.k8s.io/v1beta1","kind": "ExecCredential"}'

}

main "$@"
