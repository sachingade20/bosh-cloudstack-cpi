#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash
source $base_dir/lib/prelude_bosh.bash

if [ "${DISTRIB_CODENAME}" == "lucid" ]; then
  pkg_mgr install wireless-crda
  mkdir -p $chroot/tmp

  cp $assets_dir/lucid/*.deb $chroot/tmp/

  run_in_chroot $chroot "dpkg -i /tmp/linux-headers-3.0.0-32_3.0.0-32.51~lucid1_all.deb"
  run_in_chroot $chroot "dpkg -i /tmp/linux-headers-3.0.0-32-virtual_3.0.0-32.51~lucid1_amd64.deb"
  run_in_chroot $chroot "dpkg -i /tmp/linux-image-3.0.0-32-virtual_3.0.0-32.51~lucid1_amd64.deb"

  rm $chroot/tmp/*.deb

elif [ "${DISTRIB_CODENAME}" == "trusty" ]; then
  pkg_mgr install wireless-crda
  mkdir -p $chroot/tmp

  cp $assets_dir/trusty/*.deb $chroot/tmp/

  run_in_chroot $chroot "dpkg -i /tmp/linux-headers-3.13.0-32_3.13.0-32.56_all.deb"
  run_in_chroot $chroot "dpkg -i /tmp/linux-headers-3.13.0-32-generic_3.13.0-32.56_amd64.deb"
  run_in_chroot $chroot "dpkg -i /tmp/linux-image-3.13.0-32-generic_3.13.0-32.56_amd64.deb"
  run_in_chroot $chroot "dpkg -i /tmp/linux-image-extra-3.13.0-32-generic_3.13.0-32.56_amd64.deb"

  rm $chroot/tmp/*.deb

elif [ "${DISTRIB_CODENAME}" == "precise" ]; then
  pkg_mgr install linux-image-virtual linux-image-extra-virtual linux-headers-virtual
else
  echo "Unknown OS, exiting"
  exit 2
fi

