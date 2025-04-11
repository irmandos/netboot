#!/bin/bash

# Build environment
BASEDIR=$(dirname $(realpath ${0}))
NETWDIR="${BASEDIR}/pumba"
NETWSHR="//pumba.bothahome.co.za/webDavShare/Ubuntu/netboot-build"
SOURCE_FILES="${BASEDIR}/files"
IMG_FILE="${NETWDIR}/rootfs.img"
ROOTFS_MNT="${NETWDIR}/rootfs.mnt"

#Ensure hostname is properly set to FQDN using host-namer.sh script in order for auto-apt-proxy to work corrctly
chmod +x ${SOURCE_FILES}/host-namer.sh
${SOURCE_FILES}/host-namer.sh fqdn

#Ensure we have the tools we need
apt install cifs-utils squashfs-tools initramfs-tools git wget nano auto-apt-proxy debootstrap -y

mkdir -p ${NETWDIR}
mount -t cifs ${NETWSHR} ${NETWDIR} -o username=irmandos,uid=$(id -u),gid=$(id -g)
cp /boot/vmlinuz ${NETWDIR}/vmlinuz
chmod +x *.sh
./build-initrd.sh
./build-rootfs.sh
