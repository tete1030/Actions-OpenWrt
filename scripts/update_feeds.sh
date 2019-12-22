#!/bin/bash

set -eo pipefail

echo "Updating and installing feeds ..."
cd openwrt
[ "x${UPDATE_FEEDS}" != "x1" ] || ./scripts/feeds update -a
./scripts/feeds install -a

mkdir -p package/feeds || true
cd package/feeds

# install_package PACKAGE_DIR GIT_URL
install_package() {
  if (( $# != 2 )); then
    echo "Wrong arguments for install_package" >&2
    exit 1
  fi
  if [ -d "${1}" ]; then
    [ "x${UPDATE_FEEDS}" != "x1" ] || ( git -C "${1}" reset --hard && git -C "${1}" pull --ff )
  else
    git clone "${2}" "${1}"
  fi
}

# Customize here for any additional package you want to install/update
# Note that to have it compiled, you also have to set its CONFIG_* options
install_package mentohust https://github.com/KyleRicardo/MentoHUST-OpenWrt-ipk.git
install_package luci-app-mentohust https://github.com/BoringCat/luci-app-mentohust.git
