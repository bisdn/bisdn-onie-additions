#!/bin/sh

#  Copyright (C) 2014-2015 Curt Brune <curt@cumulusnetworks.com>
#  Copyright (C) 2014-2015 david_yang <david_yang@accton.com>
#
#  SPDX-License-Identifier:     GPL-2.0

set -e

DEBUG=1

cd $(dirname $0)
. ./machine.conf

echo "Demo Installer: platform: $platform"

# Install demo on same block device as ONIE
blk_dev=$(blkid | grep ONIE-BOOT | awk '{print $1}' |  sed -e 's/[1-9][0-9]*:.*$//' | sed -e 's/\([0-9]\)\(p\)/\1/' | head -n 1)

[ -b "$blk_dev" ] || {
    echo "Error: Unable to determine block device of ONIE install"
    exit 1
}

demo_volume_label="BISDN-Linux"

# auto-detect whether BIOS or UEFI
if [ -d "/sys/firmware/efi/efivars" ] ; then
    firmware="uefi"
else
    firmware="bios"
fi

# determine ONIE partition type
onie_partition_type=$(onie-sysinfo -t)
# demo partition size in MB
demo_part_size=4096
if [ "$firmware" = "uefi" ] ; then
    create_demo_partition="create_demo_uefi_partition"
elif [ "$onie_partition_type" = "gpt" ] ; then
    create_demo_partition="create_demo_gpt_partition"
elif [ "$onie_partition_type" = "msdos" ] ; then
    create_demo_partition="create_demo_msdos_partition"
else
    echo "ERROR: Unsupported partition type: $onie_partition_type"
    exit 1
fi

[ -n $DEBUG ] && echo "DEBUG: onie_partition_type=${onie_partition_type}"
[ -n $DEBUG ] && echo "DEBUG: firmware=${firmware}"

# do only restore if backup has been created
DO_RESTORE=false

# Creates a backup of current network configuration files
#
# arg $1 -- block device
#
# arg $2 -- partition number
#
# sets flag 'DO_RESTORE' to true to enable config restoration at the end
backup_cfg()
{
    echo "Existing network configuration found!"

    backup_tmp_dir=$(mktemp -d)
    network="etc/systemd/network"
    mkdir -p $backup_tmp_dir/$network

    bisdn_linux_old=$(mktemp -d)
    mount $1$2 $bisdn_linux_old

    echo "Creating backup of existing /$network/ directory"
    cp -r $bisdn_linux_old/$network/* $backup_tmp_dir/$network

    umount $bisdn_linux_old

    DO_RESTORE=true
}

# Creates a new partition for the DEMO OS.
#
# arg $1 -- base block device
#
# Returns the created partition number in $demo_part
demo_part=
create_demo_gpt_partition()
{
    blk_dev="$1"

    # See if demo partition already exists
    demo_part=$(sgdisk -p $blk_dev | grep "$demo_volume_label" | awk '{print $1}')
    if [ -n "$demo_part" ] ; then
	# backup existing config
        backup_cfg $blk_dev $demo_part
	# delete existing partition
        sgdisk -d $demo_part $blk_dev || {
            echo "Error: Unable to delete partition $demo_part on $blk_dev"
            exit 1
        }
        partprobe
    fi

    # Find next available partition
    last_part=$(sgdisk -p $blk_dev | tail -n 1 | awk '{print $1}')
    demo_part=$(( $last_part + 1 ))

    # Create new partition
    echo "Creating new demo partition ${blk_dev}$demo_part ..."

    attr_bitmask="0x0"

    sgdisk --new=${demo_part}::+${demo_part_size}MB \
        --attributes=${demo_part}:=:$attr_bitmask \
        --change-name=${demo_part}:$demo_volume_label $blk_dev || {
        echo "Error: Unable to create partition $demo_part on $blk_dev"
        exit 1
    }
    partprobe
}

create_demo_msdos_partition()
{
    blk_dev="$1"

    # See if demo partition already exists -- look for the filesystem
    # label.
    part_info="$(blkid | grep $demo_volume_label | awk -F: '{print $1}')"
    if [ -n "$part_info" ] ; then
        # delete existing partition
        demo_part="$(echo -n $part_info | sed -e s#${blk_dev}##)"
        parted -s $blk_dev rm $demo_part || {
            echo "Error: Unable to delete partition $demo_part on $blk_dev"
            exit 1
        }
        partprobe
    fi

    # Find next available partition
    last_part_info="$(parted -s -m $blk_dev unit s print | tail -n 1)"
    last_part_num="$(echo -n $last_part_info | awk -F: '{print $1}')"
    last_part_end="$(echo -n $last_part_info | awk -F: '{print $3}')"
    # Remove trailing 's'
    last_part_end=${last_part_end%s}
    demo_part=$(( $last_part_num + 1 ))
    demo_part_start=$(( $last_part_end + 1 ))
    # sectors_per_mb = (1024 * 1024) / 512 = 2048
    sectors_per_mb=2048
    demo_part_end=$(( $demo_part_start + ( $demo_part_size * $sectors_per_mb ) - 1 ))

    # Create new partition
    echo "Creating new demo partition ${blk_dev}$demo_part ..."
    parted -s --align optimal $blk_dev unit s \
      mkpart primary $demo_part_start $demo_part_end set $demo_part boot on || {
        echo "ERROR: Problems creating demo msdos partition $demo_part on: $blk_dev"
        exit 1
    }
    partprobe

}

# For UEFI systems, create a new partition for the DEMO OS.
#
# arg $1 -- base block device
#
# Returns the created partition number in $demo_part
create_demo_uefi_partition()
{
    create_demo_gpt_partition "$1"

    # erase any related EFI BootOrder variables from NVRAM.
    for b in $(efibootmgr | grep "$demo_volume_label" | awk '{ print $1 }') ; do
        local num=${b#Boot}
        # Remove trailing '*'
        num=${num%\*}
        efibootmgr -b $num -B > /dev/null 2>&1
    done
}

# Install legacy BIOS GRUB for DEMO OS
demo_install_grub()
{
    local demo_mnt="$1"
    local blk_dev="$2"

    # Pretend we are a major distro and install GRUB into the MBR of
    # $blk_dev.
    grub-install --boot-directory="$demo_mnt" --recheck "$blk_dev" || {
        echo "ERROR: grub-install failed on: $blk_dev"
        exit 1
    }
}

# Install UEFI BIOS GRUB for DEMO OS
demo_install_uefi_grub()
{
    local demo_mnt="$1"
    local blk_dev="$2"

    # Look for the EFI system partition UUID on the same block device as
    # the ONIE-BOOT partition.
    local uefi_part=0
    for p in $(seq 8) ; do
        if sgdisk -i $p $blk_dev | grep -q C12A7328-F81F-11D2-BA4B-00A0C93EC93B ; then
            uefi_part=$p
            break
        fi
    done

    [ $uefi_part -eq 0 ] && {
        echo "ERROR: Unable to determine UEFI system partition"
        exit 1
    }

    grub_install_log=$(mktemp)
    grub-install \
        --no-nvram \
        --bootloader-id="$demo_volume_label" \
        --efi-directory="/boot/efi" \
        --boot-directory="$demo_mnt" \
        --recheck \
        "$blk_dev" > /$grub_install_log 2>&1 || {
        echo "ERROR: grub-install failed on: $blk_dev"
        cat $grub_install_log && rm -f $grub_install_log
        exit 1
    }
    rm -f $grub_install_log

    # Configure EFI NVRAM Boot variables.  --create also sets the
    # new boot number as active.
    efibootmgr --quiet --create \
        --label "$demo_volume_label" \
        --disk $blk_dev --part $uefi_part \
        --loader "/EFI/$demo_volume_label/grubx64.efi" || {
        echo "ERROR: efibootmgr failed to create new boot variable on: $blk_dev"
        exit 1
    }

}

eval $create_demo_partition $blk_dev
demo_dev=$(echo $blk_dev | sed -e 's/\(mmcblk[0-9]\)/\1p/')$demo_part
partprobe
fs_type="ext4"

[ -n $DEBUG ] && echo "DEBUG: demo_dev=${demo_dev}"
[ -n $DEBUG ] && echo "DEBUG: fs_type=${fs_type}"

# Create filesystem on demo partition with a label
mkfs.$fs_type -L $demo_volume_label $demo_dev || {
    echo "Error: Unable to create file system on $demo_dev"
    exit 1
}

demo_part_uuid=$(blkid | grep 'LABEL="'$demo_volume_label'"' | sed -e 's/^.*UUID="//' -e 's/".*//')

[ -n $DEBUG ] && echo "DEBUG: demo_part_uuid=${demo_part_uuid}"
[ -n $DEBUG ] && echo "DEBUG: demo_part=${demo_part}"

# Mount demo filesystem
demo_mnt=$(mktemp -d) || {
    echo "Error: Unable to create demo file system mount point"
    exit 1
}
mount -t $fs_type -o defaults,rw $demo_dev $demo_mnt || {
    echo "Error: Unable to mount $demo_dev on $demo_mnt"
    exit 1
}

# install fs
if [ -f rootfs.cpio.gz ] ; then
    image_archive=$(realpath rootfs.cpio.gz)
    cd $demo_mnt
    zcat $image_archive | cpio -i
    cd -
elif [ -f "rootfs.$fs_type" ] ; then
    umount $demo_mnt
    dd if=rootfs.$fs_type of=$demo_dev
    mount -t $fs_type -o defaults,rw $demo_dev $demo_mnt || {
        echo "Error: Unable to mount $demo_dev on $demo_mnt"
        exit 1
    }
elif [ -f rootfs.tar.xz ] ; then
    xzcat rootfs.tar.xz | tar xf - -C $demo_mnt
    if [ ! -f $demo_mnt/boot/bzImage ] ; then
	echo "Error: No kernel image in root fs"
	exit 1
    fi
    if [ ! -f $demo_mnt/lib/systemd/systemd ] ; then
	echo "Error: No systemd found in root fs"
	exit 1
    fi
else
    echo "Error: Invalid root fs"
    exit 1
fi

#[ -f bzImage ] && cp bzImage $demo_mnt/boot/
#[ -f initramfs ] && cp initramfs $demo_mnt/boot/
#[ -f modules.tgz ] && tar xzf modules.tgz -C $demo_mnt

# update fstab
#sed -ie "s#rootfs#${demo_dev}#" $demo_mnt/etc/fstab

# store installation log in demo file system
onie-support $demo_mnt

if [ "$firmware" = "uefi" ] ; then
    demo_install_uefi_grub "$demo_mnt/boot" "$blk_dev"
else
    demo_install_grub "$demo_mnt/boot" "$blk_dev"
fi

# Create a minimal grub.cfg that allows for:
#   - configure the serial console
#   - allows for grub-reboot to work
#   - a menu entry for the DEMO OS
#   - menu entries for ONIE

grub_cfg=$(mktemp)

# Set a few GRUB_xxx environment variables that will be picked up and
# used by the 50_onie_grub script.  This is similiar to what an OS
# would specify in /etc/default/grub.
#
# GRUB_SERIAL_COMMAND
# GRUB_CMDLINE_LINUX

[ -r ./platform.conf ] && . ./platform.conf

DEFAULT_GRUB_SERIAL_COMMAND="serial --port=%%CONSOLE_PORT%% --speed=%%CONSOLE_SPEED%% --word=8 --parity=no --stop=1"
DEFAULT_GRUB_CMDLINE_LINUX="console=tty0 console=ttyS%%CONSOLE_DEV%%,%%CONSOLE_SPEED%%n8 %%EXTRA_CMDLINE_LINUX%%"
DEFAULT_EXTRA_CMDLINE_LINUX=""
GRUB_SERIAL_COMMAND=${GRUB_SERIAL_COMMAND:-"$DEFAULT_GRUB_SERIAL_COMMAND"}
GRUB_CMDLINE_LINUX=${GRUB_CMDLINE_LINUX:-"$DEFAULT_GRUB_CMDLINE_LINUX"}
EXTRA_CMDLINE_LINUX=${EXTRA_CMDLINE_LINUX:-"$DEFAULT_EXTRA_CMDLINE_LINUX"}
export GRUB_SERIAL_COMMAND
export GRUB_CMDLINE_LINUX
export EXTRA_CMDLINE_LINUX

# Add common configuration, like the timeout and serial console.
(cat <<EOF
$GRUB_SERIAL_COMMAND
terminal_input serial
terminal_output serial

set timeout=5

EOF
) > $grub_cfg

# Add the logic to support grub-reboot
(cat <<EOF
if [ -s \$prefix/grubenv ]; then
  load_env
fi
if [ "\${next_entry}" ] ; then
   set default="\${next_entry}"
   set next_entry=
   save_env next_entry
   set boot_once=true
else
   set default="\${saved_entry}"
fi

if [ "\${prev_saved_entry}" ]; then
  set saved_entry="\${prev_saved_entry}"
  save_env saved_entry
  set prev_saved_entry=
  save_env prev_saved_entry
  set boot_once=true
fi

EOF
) >> $grub_cfg

(cat <<EOF
onie_partition_type=${onie_partition_type}
export onie_partition_type

function entry_start {
  insmod gzio
  insmod ext2
  if [ "\$onie_partition_type" = "gpt" ] ; then
    insmod part_gpt
    set root='(hd0,gpt${demo_part})'
  else
    insmod part_msdos
    set root='(hd0,msdos${demo_part})'
  fi
}

EOF
) >> $grub_cfg

# Add a menu entry for the DEMO OS
demo_grub_entry="BISDN Linux"
part_unique_guid=$(sgdisk -i ${demo_part} /dev/sda | grep 'Partition unique GUID' | cut -d\  -f 4)
# XXX eventually s/rootwait/rootdelay/
(cat <<EOF
menuentry '$demo_grub_entry' {
        entry_start
        search --no-floppy --fs-uuid --set=root $demo_part_uuid
        echo    'Loading BISDN Linux...'
        linux   /boot/bzImage $GRUB_CMDLINE_LINUX rootfstype=${fs_type} root=PARTUUID=${part_unique_guid} rootwait $EXTRA_CMDLINE_LINUX
}
EOF
) >> $grub_cfg

# Add menu entries for ONIE -- use the grub fragment provided by the
# ONIE distribution.
/mnt/onie-boot/onie/grub.d/50_onie_grub >> $grub_cfg

cp $grub_cfg $demo_mnt/boot/grub/grub.cfg

# Restore the network configuration from previous installation
if [ "${DO_RESTORE}" = true ]; then
  echo "Restoring backup of existing /$network/ directory"
  cp -r $backup_tmp_dir/$network/* $demo_mnt/$network
fi;

# clean up
umount $demo_mnt || {
    echo "Error: Problems umounting $demo_mnt"
}

cd /

