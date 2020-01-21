#!/bin/bash
#
#  Copyright (C) 2013,2014,2015 Curt Brune <curt@cumulusnetworks.com>
#  Copyright (C) 2015 david_yang <david_yang@accton.com>
#  Copyright (C) 2016 Pankaj Bansal <pankajbansal3073@gmail.com>
#
#  SPDX-License-Identifier:     GPL-2.0

#defaults if not set; overridden by platform.conf
[ -z "$CONSOLE_SPEED" ] &&  export CONSOLE_SPEED=115200
[ -z "$CONSOLE_DEV" ] && export CONSOLE_DEV=1
[ -z "$CONSOLE_PORT" ] && export CONSOLE_PORT=0x2f8
[ -z "$BISDN_ARCH" ] && export BISDN_ARCH=x86_64

[ -z "$BISDN_ONIE_MACHINE" ] && export BISDN_ONIE_MACHINE="unknown_machine"
[ -z "$BISDN_ONIE_PLATFORM" ] && export BISDN_ONIE_PLATFORM="unknown_platform"

MACHINE=$1
shift

rootfs_arch=${BISDN_ARCH}
machine=${BISDN_ONIE_MACHINE}
platform=${BISDN_ONIE_PLATFORM}
installer_dir="./bisdn/installer/"
platform_conf="./bisdn/machine/${PLATFORM_VENDOR}/${MACHINE}/platform.conf"
output_file="onie-bisdn-${MACHINE}.bin"
demo_type="OS"

if  [ ! -d $installer_dir ] || \
    [ ! -r $installer_dir/sharch_body.sh ] ; then
    echo "Error: Invalid installer script directory: $installer_dir"
    exit 1
fi

arch_dir="$rootfs_arch"

if  [ ! -d $installer_dir/$arch_dir ] || \
    [ ! -r $installer_dir/$arch_dir/install.sh ] ; then
    echo "Error: Invalid arch installer directory: $installer_dir/$arch_dir"
    exit 1
fi

[ -r "$platform_conf" ] || {
    echo "Error: Unable to read installer platform configuration file: $platform_conf"
    exit 1
}

[ $# -gt 0 ] || {
    echo "Error: No OS image files found"
    exit 1
}

case $demo_type in
    OS|DIAG)
        # These are supported
        ;;
    *)
        echo "Error: Unsupported demo type: $demo_type"
        exit 1
esac

tmp_dir=
clean_up()
{
    rm -rf $tmp_dir
    exit $1
}

# make the data archive
# contents:
#   - kernel and initramfs
#   - install.sh
#   - $platform_conf

echo -n "Building self-extracting install image ."
tmp_dir=$(mktemp --directory)
tmp_installdir="$tmp_dir/installer"
mkdir $tmp_installdir || clean_up 1

cp $installer_dir/$arch_dir/install.sh $tmp_installdir || clean_up 1

# Tailor the demo installer for OS mode or DIAG mode
sed -i -e "s/%%DEMO_TYPE%%/$demo_type/g" \
    $tmp_installdir/install.sh || clean_up 1
echo -n "."
cp $* $tmp_installdir || clean_up 1
echo -n "."
cp $platform_conf $tmp_installdir || clean_up 1
echo "machine=$machine" > $tmp_installdir/machine.conf
echo "platform=$platform" >> $tmp_installdir/machine.conf
echo -n "."

sharch="$tmp_dir/sharch.tar"
tar -C $tmp_dir -cf $sharch installer || {
    echo "Error: Problems creating $sharch archive"
    clean_up 1
}
echo -n "."

[ -f "$sharch" ] || {
    echo "Error: $sharch not found"
    clean_up 1
}
sha1=$(cat $sharch | sha1sum | awk '{print $1}')
echo -n "."
cp $installer_dir/sharch_body.sh $output_file || {
    echo "Error: Problems copying sharch_body.sh"
    clean_up 1
}

# Replace variables in the sharch template
sed -i -e "s/%%IMAGE_SHA1%%/$sha1/" $output_file
echo -n "."
cat $sharch >> $output_file
rm -rf $tmp_dir
echo " Done."

echo "Success:  Demo install image is ready in ${output_file}:"
ls -l ${output_file}

clean_up 0
