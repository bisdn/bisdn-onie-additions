#!/bin/sh

#  Copyright (C) 2014-2015 Curt Brune <curt@cumulusnetworks.com>
#  Copyright (C) 2014-2015 david_yang <david_yang@accton.com>
#
#  SPDX-License-Identifier:     GPL-2.0

set -e

DEBUG=1

part_blk_dev() {
    case "$1" in
        *mmcblk*|*nvme*)
            echo "${1}p${2}"
            ;;
        *)
            echo "${1}${2}"
            ;;
    esac
}

# Creates a backup of current network configuration files
#
# arg $1 -- block device
#
# arg $2 -- partition number
#
# sets flag 'DO_RESTORE' to true to enable config restoration at the end
backup_cfg()
{
    echo "Existing installation found!"

    backup_tmp_dir=$(mktemp -d)
    network="etc/systemd/network"
    mkdir -p $backup_tmp_dir/$network

    bisdn_linux_old=$(mktemp -d)
    mount $(part_blk_dev $1 $2) $bisdn_linux_old

    if [ -d "$bisdn_linux_old/$network" ] && grep -q -r "^Name=enp" $bisdn_linux_old/$network; then
        echo "Creating backup of existing management interface configuration"
        for file in $(grep -l -r "^Name=enp" $bisdn_linux_old/$network); do
            case "$file" in
                *.network)
                    cp $file $backup_tmp_dir/$network
                    DO_RESTORE=true
                    ;;
            esac
        done
    fi

    umount $bisdn_linux_old
}

# Creates a new partition for the BISDN Linux OS.
#
# arg $1 -- base block device
#
# Returns the created partition number in $bisdn_linux_part
bisdn_linux_part=
create_bisdn_linux_gpt_partition()
{
    blk_dev="$1"

    # See if BISDN Linux partition already exists
    bisdn_linux_part=$(sgdisk -p $blk_dev | grep "$bisdn_linux_volume_label" | awk '{print $1}')
    if [ -n "$bisdn_linux_part" ] ; then
        # backup existing config
        backup_cfg $blk_dev $bisdn_linux_part
        # delete existing partition
        sgdisk -d $bisdn_linux_part $blk_dev || {
            echo "Error: Unable to delete partition $bisdn_linux_part on $blk_dev"
            exit 1
        }
        partprobe
    fi

    # Find next available partition
    last_part=$(sgdisk -p $blk_dev | tail -n 1 | awk '{print $1}')
    bisdn_linux_part=$(( $last_part + 1 ))

    # Create new partition
    echo "Creating new BISDN Linux partition ${blk_dev}$bisdn_linux_part ..."

    attr_bitmask="0x0"

    sgdisk --new=${bisdn_linux_part}::+${bisdn_linux_part_size}MB \
        --attributes=${bisdn_linux_part}:=:$attr_bitmask \
        --change-name=${bisdn_linux_part}:$bisdn_linux_volume_label $blk_dev || {
        echo "Error: Unable to create partition $bisdn_linux_part on $blk_dev"
        exit 1
    }
    partprobe
}

create_bisdn_linux_msdos_partition()
{
    blk_dev="$1"

    # See if BISDN Linux partition already exists -- look for the filesystem
    # label.
    part_info="$(blkid | grep $bisdn_linux_volume_label | awk -F: '{print $1}')"
    if [ -n "$part_info" ] ; then
        # delete existing partition
        bisdn_linux_part="$(echo -n $part_info | sed -e s#${blk_dev}##)"
        parted -s $blk_dev rm $bisdn_linux_part || {
            echo "Error: Unable to delete partition $bisdn_linux_part on $blk_dev"
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
    bisdn_linux_part=$(( $last_part_num + 1 ))
    bisdn_linux_part_start=$(( $last_part_end + 1 ))
    # sectors_per_mb = (1024 * 1024) / 512 = 2048
    sectors_per_mb=2048
    bisdn_linux_part_end=$(( $bisdn_linux_part_start + ( $bisdn_linux_part_size * $sectors_per_mb ) - 1 ))

    # Create new partition
    echo "Creating new BISDN Linux partition ${blk_dev}$bisdn_linux_part ..."
    parted -s --align optimal $blk_dev unit s \
      mkpart primary $bisdn_linux_part_start $bisdn_linux_part_end set $bisdn_linux_part boot on || {
        echo "ERROR: Problems creating BISDN Linux msdos partition $bisdn_linux_part on: $blk_dev"
        exit 1
    }
    partprobe

}

# For UEFI systems, create a new partition for the BISDN Linux OS.
#
# arg $1 -- base block device
#
# Returns the created partition number in $bisdn_linux_part
create_bisdn_linux_uefi_partition()
{
    create_bisdn_linux_gpt_partition "$1"

    # erase any related EFI BootOrder variables from NVRAM.
    for b in $(efibootmgr | grep "$bisdn_linux_volume_label" | awk '{ print $1 }') ; do
        local num=${b#Boot}
        # Remove trailing '*'
        num=${num%\*}
        efibootmgr -b $num -B > /dev/null 2>&1
    done
}

# Install legacy BIOS GRUB for BISDN Linux OS
bisdn_linux_install_grub()
{
    local bisdn_linux_mnt="$1"
    local blk_dev="$2"

    # Pretend we are a major distro and install GRUB into the MBR of
    # $blk_dev.
    grub-install --boot-directory="$bisdn_linux_mnt" --recheck "$blk_dev" || {
        echo "ERROR: grub-install failed on: $blk_dev"
        exit 1
    }
}

# Install UEFI BIOS GRUB for BISDN Linux OS
bisdn_linux_install_uefi_grub()
{
    local bisdn_linux_mnt="$1"
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
        --bootloader-id="$bisdn_linux_volume_label" \
        --efi-directory="/boot/efi" \
        --boot-directory="$bisdn_linux_mnt" \
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
        --label "$bisdn_linux_volume_label" \
        --disk $blk_dev --part $uefi_part \
        --loader "/EFI/$bisdn_linux_volume_label/grubx64.efi" || {
        echo "ERROR: efibootmgr failed to create new boot variable on: $blk_dev"
        exit 1
    }

}

platform_install()
{
    cd $(dirname $0)
    . ./machine.conf

    echo "BISDN Linux Installer: platform: $platform"

    # Install BISDN Linux on same block device as ONIE
    blk_dev=$(blkid | grep ONIE-BOOT | awk '{print $1}' |  sed -e 's/[1-9][0-9]*:.*$//' | sed -e 's/\([0-9]\)\(p\)/\1/' | head -n 1)

    [ -b "$blk_dev" ] || {
        echo "Error: Unable to determine block device of ONIE install"
        exit 1
    }

    bisdn_linux_volume_label="BISDN-Linux"

    # auto-detect whether BIOS or UEFI
    if [ -d "/sys/firmware/efi/efivars" ] ; then
        firmware="uefi"
    else
        firmware="bios"
    fi

    # determine ONIE partition type
    onie_partition_type=$(onie-sysinfo -t)
    # BISDN Linux partition size in MB
    bisdn_linux_part_size=4096
    if [ "$firmware" = "uefi" ] ; then
        create_bisdn_linux_partition="create_bisdn_linux_uefi_partition"
    elif [ "$onie_partition_type" = "gpt" ] ; then
        create_bisdn_linux_partition="create_bisdn_linux_gpt_partition"
    elif [ "$onie_partition_type" = "msdos" ] ; then
        create_bisdn_linux_partition="create_bisdn_linux_msdos_partition"
    else
        echo "ERROR: Unsupported partition type: $onie_partition_type"
        exit 1
    fi

    [ -n $DEBUG ] && echo "DEBUG: onie_partition_type=${onie_partition_type}"
    [ -n $DEBUG ] && echo "DEBUG: firmware=${firmware}"

    # do only restore if backup has been created
    DO_RESTORE=false


    eval $create_bisdn_linux_partition $blk_dev
    bisdn_linux_dev=$(part_blk_dev $blk_dev $bisdn_linux_part)
    partprobe
    fs_type="ext4"

    [ -n $DEBUG ] && echo "DEBUG: bisdn_linux_dev=${bisdn_linux_dev}"
    [ -n $DEBUG ] && echo "DEBUG: fs_type=${fs_type}"

    # Create filesystem on BISDN Linux partition with a label
    mkfs.$fs_type -L $bisdn_linux_volume_label $bisdn_linux_dev || {
        echo "Error: Unable to create file system on $bisdn_linux_dev"
        exit 1
    }

    bisdn_linux_part_uuid=$(blkid | grep 'LABEL="'$bisdn_linux_volume_label'"' | sed -e 's/^.*UUID="//' -e 's/".*//')

    [ -n $DEBUG ] && echo "DEBUG: bisdn_linux_part_uuid=${bisdn_linux_part_uuid}"
    [ -n $DEBUG ] && echo "DEBUG: bisdn_linux_part=${bisdn_linux_part}"

    # Mount BISDN Linux filesystem
    bisdn_linux_mnt=$(mktemp -d) || {
        echo "Error: Unable to create BISDN Linux file system mount point"
        exit 1
    }
    mount -t $fs_type -o defaults,rw $bisdn_linux_dev $bisdn_linux_mnt || {
        echo "Error: Unable to mount $bisdn_linux_dev on $bisdn_linux_mnt"
        exit 1
    }

    # install fs
    if [ -f rootfs.cpio.gz ] ; then
        image_archive=$(realpath rootfs.cpio.gz)
        cd $bisdn_linux_mnt
        zcat $image_archive | cpio -i
        cd -
    elif [ -f "rootfs.$fs_type" ] ; then
        umount $bisdn_linux_mnt
        dd if=rootfs.$fs_type of=$bisdn_linux_dev
        mount -t $fs_type -o defaults,rw $bisdn_linux_dev $bisdn_linux_mnt || {
            echo "Error: Unable to mount $bisdn_linux_dev on $bisdn_linux_mnt"
            exit 1
        }
    elif [ -f rootfs.tar.xz ] ; then
        xzcat rootfs.tar.xz | tar xf - -C $bisdn_linux_mnt
        if [ ! -f $bisdn_linux_mnt/boot/bzImage ] ; then
        echo "Error: No kernel image in root fs"
        exit 1
        fi
        if [ ! -f $bisdn_linux_mnt/lib/systemd/systemd ] ; then
        echo "Error: No systemd found in root fs"
        exit 1
        fi
    else
        echo "Error: Invalid root fs"
        exit 1
    fi

    #[ -f bzImage ] && cp bzImage $bisdn_linux_mnt/boot/
    #[ -f initramfs ] && cp initramfs $bisdn_linux_mnt/boot/
    #[ -f modules.tgz ] && tar xzf modules.tgz -C $bisdn_linux_mnt

    # update fstab
    #sed -ie "s#rootfs#${bisdn_linux_dev}#" $bisdn_linux_mnt/etc/fstab

    # store installation log in BISDN Linux file system
    onie-support $bisdn_linux_mnt

    if [ "$firmware" = "uefi" ] ; then
        bisdn_linux_install_uefi_grub "$bisdn_linux_mnt/boot" "$blk_dev"
    else
        bisdn_linux_install_grub "$bisdn_linux_mnt/boot" "$blk_dev"
    fi

    # Create a minimal grub.cfg that allows for:
    #   - configure the serial console
    #   - allows for grub-reboot to work
    #   - a menu entry for the BISDN Linux OS
    #   - menu entries for ONIE

    grub_cfg=$(mktemp)

    # Set a few GRUB_xxx environment variables that will be picked up and
    # used by the 50_onie_grub script.  This is similiar to what an OS
    # would specify in /etc/default/grub.
    #
    # GRUB_SERIAL_COMMAND
    # GRUB_CMDLINE_LINUX

    [ -r ./platform.conf ] && . ./platform.conf

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
    set root='(hd0,gpt${bisdn_linux_part})'
  else
    insmod part_msdos
    set root='(hd0,msdos${bisdn_linux_part})'
  fi
}

EOF
    ) >> $grub_cfg

    # Add a menu entry for the BISDN Linux OS
    bisdn_linux_grub_entry="BISDN Linux"
    part_unique_guid=$(sgdisk -i ${bisdn_linux_part} /dev/sda | grep 'Partition unique GUID' | cut -d\  -f 4)
    # XXX eventually s/rootwait/rootdelay/
    (cat <<EOF
menuentry '$bisdn_linux_grub_entry' {
        entry_start
        search --no-floppy --fs-uuid --set=root $bisdn_linux_part_uuid
        echo    'Loading BISDN Linux...'
        linux   /boot/bzImage $GRUB_CMDLINE_LINUX rootfstype=${fs_type} root=PARTUUID=${part_unique_guid} rootwait $EXTRA_CMDLINE_LINUX
}
EOF
    ) >> $grub_cfg

    # Add menu entries for ONIE -- use the grub fragment provided by the
    # ONIE distribution.
    /mnt/onie-boot/onie/grub.d/50_onie_grub >> $grub_cfg

    cp $grub_cfg $bisdn_linux_mnt/boot/grub/grub.cfg

    # Restore the network configuration from previous installation
    if [ "${DO_RESTORE}" = true ]; then
      echo "Restoring backup of existing management configuration"
      cp -r $backup_tmp_dir/$network/* $bisdn_linux_mnt/$network
    fi;

    # clean up
    umount $bisdn_linux_mnt || {
        echo "Error: Problems umounting $bisdn_linux_mnt"
    }

    cd /
}

platform_install
