#!/bin/bash

set -eux

BIN2CBUNDLE="../libkrunfw/bin2cbundle.py"
LIB_DIR="../libkrun/lib"

FULL_VERSION="0.1.2"
ABI_VERSION=4

FW_BASE=libkrunfw-mewz.so
FW_BINARY=$FW_BASE.$FULL_VERSION
FW_SONAME=$FW_BASE.$ABI_VERSION

python3 $BIN2CBUNDLE -t vmlinux zig-out/bin/mewz.qemu.elf mewz.c
cc -fPIC -DABI_VERSION=$ABI_VERSION -shared -Wl,-soname,$FW_SONAME -o $FW_BINARY mewz.c
strip $FW_BINARY

install -d $LIB_DIR/
install -m 755 $FW_BINARY $LIB_DIR/
cd $LIB_DIR
ln -sf $FW_BINARY $FW_SONAME
ln -sf $FW_SONAME $FW_BASE

