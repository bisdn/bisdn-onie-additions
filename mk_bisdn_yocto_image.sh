#!/bin/bash

#defaults if not set; overridden by platform.conf
[ -z "$CONSOLE_SPEED" ] &&  export CONSOLE_SPEED=115200
[ -z "$CONSOLE_DEV" ] && export CONSOLE_DEV=1
[ -z "$CONSOLE_PORT" ] && export CONSOLE_PORT=0x2f8

[ -z "$BISDN_ONIE_MACHINE" ] && export BISDN_ONIE_MACHINE="unknown_machine"
[ -z "$BISDN_ONIE_PLATFORM" ] && export BISDN_ONIE_PLATFORM="unknown_platform"

MACHINE=$1
shift

./build-config/scripts/onie-mk-demo.sh x86_64 ${BISDN_ONIE_MACHINE} ${BISDN_ONIE_PLATFORM} ./bisdn/installer/ bisdn/machine/${PLATFORM_VENDOR}/${MACHINE}/platform.conf onie-bisdn-${MACHINE}.bin OS $*
