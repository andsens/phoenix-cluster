#!/usr/bin/env bash
# shellcheck source-path=../..
set -Eeo pipefail; shopt -s inherit_errexit
PKGROOT=/usr/local/lib/upkg
source "$PKGROOT/.upkg/records.sh/records.sh"

main() {
  local src dest tar_mode=-c
  for src in /workspace/embed-configs/*; do
    dest=phxc/$(basename "$src")
    tar ${tar_mode}f /workspace/embed-configs.tar \
      --transform="s#${src#/}#${dest#/}#" \
      "$src"
    tar_mode=-r
  done
  guestfish -xa /workspace/disk.img -m /dev/sda1 -- <<EOF
tar-in /workspace/embed-configs.tar /
EOF
}

main "$@"
