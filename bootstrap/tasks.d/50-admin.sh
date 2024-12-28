#!/usr/bin/env bash

PACKAGES+=(sudo adduser)
! $DEBUG || PACKAGES+=(less nano bsdextrautils tree psmisc dnsutils lsof netcat-openbsd)

admin() {
  chmod 0440 /etc/sudoers.d/20_admin_nopass
  useradd -m -s /bin/bash -u 1000 admin
  adduser admin adm
  adduser admin sudo
  mkdir /home/admin/.ssh
  if [[ -e /workspace/embed-configs ]]; then
    info "Copying admin ssh key to /home/admin/.ssh/authorized_keys"
    yq -r '.admin.["ssh-keys"][]' /workspace/embed-configs/cluster.yaml > /home/admin/.ssh/authorized_keys
    local pwhash
    ! pwhash=$(get-config /workspace/embed-configs/cluster.yaml admin.pwhash) || usermod -p "$pwhash" admin
  fi
  usermod -L root
  chown -R admin:admin /home/admin/.ssh
  chmod -R u=rwX,go=rX /home/admin/.ssh
}
