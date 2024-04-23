#!/usr/bin/env bash
# shellcheck source-path=..
set -eo pipefail; shopt -s inherit_errexit
PKGROOT=$(realpath "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/..")

main() {
  source "$PKGROOT/lib/common.sh"

  DOC="install-deps - Install dependencies
Usage:
  install-deps [MACHINE]
"
# docopt parser below, refresh this parser with `docopt.sh install-deps.sh`
# shellcheck disable=2016,1090,1091,2034
docopt() { source "$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh" '1.0.0' || {
ret=$?; printf -- "exit %d\n" "$ret"; exit "$ret"; }; set -e
trimmed_doc=${DOC:0:67}; usage=${DOC:36:31}; digest=1c414; shorts=(); longs=()
argcounts=(); node_0(){ value MACHINE a; }; node_1(){ optional 0; }; node_2(){
required 1; }; node_3(){ required 2; }; cat <<<' docopt_exit() {
[[ -n $1 ]] && printf "%s\n" "$1" >&2; printf "%s\n" "${DOC:36:31}" >&2; exit 1
}'; unset var_MACHINE; parse 3 "$@"; local prefix=${DOCOPT_PREFIX:-''}
unset "${prefix}MACHINE"; eval "${prefix}"'MACHINE=${var_MACHINE:-}'
local docopt_i=1; [[ $BASH_VERSION =~ ^4.3 ]] && docopt_i=2
for ((;docopt_i>0;docopt_i--)); do declare -p "${prefix}MACHINE"; done; }
# docopt parser above, complete command for generating this parser is `docopt.sh --library='"$PKGROOT/.upkg/andsens/docopt.sh/docopt-lib.sh"' install-deps.sh`
  eval "$(docopt "$@")"

  # shellcheck disable=2153
  local machine=$MACHINE machine_id
  machine_id=$(cat /etc/machine-id)
  if [[ -n $machine ]] || machine=$(get_machine "$machine_id"); then
    case "$machine" in
      workstation)
        sudo apt-get install -y --no-install-recommends fai-server fai-setup-storage qemu-utils
        wget -qO"$HOME/.local/bin/kpt" https://github.com/kptdev/kpt/releases/download/v1.0.0-beta.49/kpt_linux_amd64
        wget -qO"$HOME/.local/bin/kubectl" https://storage.googleapis.com/kubernetes-release/release/v1.28.4/bin/linux/amd64/kubectl
        wget -qO"$HOME/.local/bin/k9s" https://github.com/derailed/k9s/releases/download/v0.31.9/k9s_linux_amd64.deb
        wget -qO- https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.3.0/kustomize_v5.3.0_linux_amd64.tar.gz | tar xzC "$HOME/.local/bin" kustomize
        wget -qO- https://github.com/ahmetb/kubectx/releases/download/v0.9.5/kubectx_v0.9.5_linux_x86_64.tar.gz | tar xzC "$HOME/.local/bin" kubectx
        wget -qO- https://github.com/ahmetb/kubectx/releases/download/v0.9.5/kubens_v0.9.5_linux_x86_64.tar.gz | tar xzC "$HOME/.local/bin" kubens
        wget -qO- https://github.com/stern/stern/releases/download/v1.28.0/stern_1.28.0_linux_amd64.tar.gz | tar xzC "$HOME/.local/bin" stern
        wget -qO- https://get.helm.sh/helm-v3.14.3-linux-amd64.tar.gz | tar xzC "$HOME/.local/bin" --strip-components 1 linux-amd64/helm
        wget -qO- https://dl.smallstep.com/gh-release/cli/gh-release-header/v0.26.0/step_linux_0.26.0_amd64.tar.gz | tar xzC "$HOME/.local/bin" --strip-components 2 step_0.26.0/bin/step
        chmod +x "$HOME/.local/bin"/{kubectl,kpt,k9s,kustomize,kubectx,kubens,stern,helm,step}
      ;;
      *)
        info "No dependencies defined for %s" "$machine"
      ;;
    esac
  else
    fatal "Unknown machine-id: %s" "$machine_id"
  fi
}

install_common_deps() {
  local dep
  for dep in wget git jq yq; do
    if ! type "$dep" >/dev/null 2>&1; then
      printf "install-deps.sh: dependency %s not found, installing with apt-get\n" "$dep" >&2
      if ! sudo apt-get install -y --no-install-recommends wget ca-certificates git jq yq; then
        if [[ $dep = 'yq' ]]; then
          printf "install-deps.sh: Unable to install yq through apt-get. Installing yq through python venv\n" >&2
          install_yq_pip
          continue
        fi
        printf "install-deps.sh: Unable to install dependencies through apt-get. You will need to install %s manually some other way\n" "$dep" >&2
        return 1
      fi
      break
    fi
  done
  if type upkg >/dev/null 2>&1; then
    bash -ec 'src=$(wget -qO- https://raw.githubusercontent.com/orbit-online/upkg/v0.14.0/upkg.sh); \
    shasum -a 256 -c <(printf "8312d0fa0e47ff22387086021c8b096b899ff9344ca8622d80cc0d1d579dccff  -") <<<"$src"; \
    set - install -g orbit-online/upkg@v0.14.0; eval "$src"'
  fi
  (cd "$PKGROOT"; upkg install)
}

install_yq_pip() (
  python -m venv --without-pip --system-site-packages "$HOME/.local/lib/pyenv"
  # shellcheck disable=1091
  source "$HOME/.local/lib/pyenv/bin/activate"
  wget -qO"$HOME/.local/lib/pyenv/get-pip.py" https://bootstrap.pypa.io/get-pip.py
  python "$HOME/.local/lib/pyenv/get-pip.py"
  rm "$HOME/.local/lib/pyenv/get-pip.py"
  pip install yq
  ln -s ../lib/pyenv/bin/yq "$HOME/.local/bin/yq"
)

install_common_deps
main "$@"
