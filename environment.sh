#!/bin/bash

# Build environment
BASEDIR=$(dirname $(realpath ${0}))
NETWDIR="${BASEDIR}/pumba"
NETWSHR="//pumba.bothahome.co.za/webDavShare/Ubuntu/netboot-build"
SOURCE_FILES="${BASEDIR}/files"
IMG_FILE="${NETWDIR}/rootfs.img"
ROOTFS_MNT="${NETWDIR}/rootfs.mnt"

#Ensure we have the tools we need
echo 'Acquire::http::Proxy "http://apt-cacher-ng.bothahome.co.za:3142";'>/etc/apt/apt.conf.d/00aptproxy
apt install cifs-utils squashfs-tools initramfs-tools git wget nano -y

mkdir -p ${NETWDIR}
mount -t cifs ${NETWSHR} ${NETWDIR} -o username=irmandos,uid=$(id -u),gid=$(id -g)
./build-initrd.sh
./build-rootfs.sh
