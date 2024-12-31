#!/usr/bin/env bash
# shellcheck source-path=../../..
set -Eeo pipefail; shopt -s inherit_errexit
PKGROOT=$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../..")

main() {
  source "$PKGROOT/.upkg/path-tools/path-tools.sh"
  PATH=$(path_prepend "$PKGROOT/.upkg/.bin")
  local bundle
  bundle=$(mktemp --suffix .tar.gz)
  # shellcheck disable=SC2064
  trap "rm \"$bundle\"" EXIT
  "$PKGROOT/bootstrap/scripts/bundle" "$bundle"
  kubectl create --dry-run=client -o json configmap bundle --from-file "phxc.tar.gz=$bundle" | \
    jq '{"kind": "ResourceList", "items": [.]}'
}

main "$@"
