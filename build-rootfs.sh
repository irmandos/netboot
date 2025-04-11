#!/bin/bash
# Build a custom root file system for use with netboot

# Build environment
BASEDIR=$(dirname $(realpath ${0}))
NETWDIR="${BASEDIR}/pumba"
NETWSHR="//pumba.bothahome.co.za/webDavShare/Ubuntu/netboot-build"
SOURCE_FILES="${BASEDIR}/files"
IMG_FILE="${NETWDIR}/rootfs.img"
ROOTFS_MNT="${NETWDIR}/rootfs.mnt"

# Build options for the root image
IMG_SIZE="512m"                 # Image size only matters when not using "squashfs" 
VERSION_CODENAME="noble"
DPKG_ARCH="amd64"
INCLUDE_PACKAGES="zfsutils-linux,gdisk,openssh-server,openssh-client,wget,parted,debootstrap,haveged,auto-apt-proxy"
EXCLUDE_PACKAGES="ubuntu-pro-client"
MIRROR="http://archive.ubuntu.com/ubuntu"    #Using auto-apt-proxy no need to specify proxy here else use http://apt-cacher-ng.bothahome.co.za:3142/archive.ubuntu.com/ubuntu
NETBOOT_HOSTNAME="netboot"
NETBOOT_LOCALE="en_US.UTF-8"
NETBOOT_TIMEZONE="Africa/Johannesburg"
ENABLE_SSH=1                    # Enable sshd in the netboot environment?  Enable=1, Disable=0
ROOT_PASSWORD="password"         # You don't need a value here unless you want local login during netboot

# If "${SOURCE_FILES}/authorized_keys" exists and ENABLE_SSH=1, the keys will be staged in the image
wget https://github.com/irmandos.keys -O ${SOURCE_FILES}/authorized_keys

# Dynamically determine required components for INCLUDE_PACKAGES
COMPONENTS_REQUIRED=$(
    for pkg in ${INCLUDE_PACKAGES}; do
        apt-cache policy "$pkg" 2>/dev/null | \
        grep -Eo 'http.* (main|universe|restricted|multiverse)' | \
        awk '{print $NF}'
    done | sort -u | tr '\n' ','
)
COMPONENTS_REQUIRED=${COMPONENTS_REQUIRED%,}

function fail() {
  printf "%s\n" "${1}"
  exit 1
}

# Sanity checks for the build
[[ $(id -u) -eq 0 ]] || fail "Many steps in this script require root permissions.  Run the script with sudo."
[[ -z "${BASEDIR}" || "${BASEDIR}" = '/' ]] && fail 'Running from "/" or $BASEDIR was not detected.  Please define $BASEDIR'
[[ -z "${ROOTFS_MNT}" || "${ROOTFS_MNT}" = '/' ]] && fail 'Please define a directory path for $ROOTFS_MNT'
[[ -d "${ROOTFS_MNT}" ]] || mkdir -p "${ROOTFS_MNT}"
[[ -d "${ROOTFS_MNT}" ]] || fail "Failed to create the new root at: ${ROOTFS_MNT}"

printf "Preparing and mounting the image file...\n"
truncate -s "${IMG_SIZE}" "${IMG_FILE}" || fail "Failed to create a file to contain the root filesystem: ${IMG_FILE}"
shred -v -n 0 -z "${IMG_FILE}" || fail "Failed to zero out the root filesystem file: ${IMG_FILE}"
mkfs.ext2 -L netboot "${IMG_FILE}" || fail "Failed to create a filesystem inside ${IMG_FILE}"
mount "${IMG_FILE}" "${ROOTFS_MNT}" || fail "Failed to mount ${IMG_FILE} to the mount point: ${ROOTFS_MNT}"

INSIDE_IMAGE="in the root image"

printf "Installing packages in the new root image...\n"
debootstrap \
 --arch="${DPKG_ARCH}" \
 --include="${INCLUDE_PACKAGES}" \
 --exclude "${EXCLUDE_PACKAGES}" \
 --components="${COMPONENTS_REQUIRED}" \
 "${VERSION_CODENAME}" "${ROOTFS_MNT}" "${MIRROR}" || fail "Failed installing the new root with debootstrap"

# Ensure basic filesystem permissions
chmod 700 "${ROOTFS_MNT}/root"
chmod 1777 "${ROOTFS_MNT}/var/tmp"

# Basic configuration in the new root
# Set the hostname
printf "%s" "${NETBOOT_HOSTNAME}" >"${ROOTFS_MNT}/etc/hostname" || fail "Failed to set the hostname ${INSIDE_IMAGE}."

# Enable network with DHCP for all ethernet interfaces
cp "${SOURCE_FILES}/01-networkd-dhcp.yaml" "${ROOTFS_MNT}/etc/netplan/" || fail "Failed to copy the netplan ${INSIDE_IMAGE}."

# Set locale and timezone
chroot "${ROOTFS_MNT}" sudo sed -i '/^#\?DAEMON_ARGS/ s/^#\?DAEMON_ARGS.*/DAEMON_ARGS="-w 1024"/' /etc/default/haveged
chroot "${ROOTFS_MNT}" update-rc.d haveged defaults
chroot "${ROOTFS_MNT}" locale-gen --purge "${NETBOOT_LOCALE}" || fail "Failed to generate the locale ${INSIDE_IMAGE}."
chroot "${ROOTFS_MNT}" update-locale LANG="${NETBOOT_LOCALE}" || fail "Failed to update the locale ${INSIDE_IMAGE}."
printf "${NETBOOT_TIMEZONE}" > "${ROOTFS_MNT}/etc/timezone" || fail "Failed to update /etc/timezone ${INSIDE_IMAGE}."
chroot "${ROOTFS_MNT}" dpkg-reconfigure --frontend noninteractive tzdata &>/dev/null || fail "Failed setting timezone ${INSIDE_IMAGE}."

# Optionally enable SSH, enable root login, and stage SSH keys
if [[ ${ENABLE_SSH} -eq 1 ]]; then
  chroot "${ROOTFS_MNT}" ln -sf /usr/lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service
  sed -i 's/^#PermitRootLogin .*/PermitRootLogin Yes/g' "${ROOTFS_MNT}/etc/ssh/sshd_config" || fail "Failed to enable root login for sshd ${INSIDE_IMAGE}."
  if [[ -f "${SOURCE_FILES}/authorized_keys" ]]; then
    if [[ -d "${ROOTFS_MNT}/root/.ssh" ]];then
      mkdir -p -m 700 "${ROOTFS_MNT}/root/.ssh" || fail "Failed to prep the root user directory for SSH keys ${INSIDE_IMAGE}."
    fi
    cp "${SOURCE_FILES}/authorized_keys" "${ROOTFS_MNT}/root/.ssh/authorized_keys"|| fail "Failed staging SSH authorized keys ${INSIDE_IMAGE}."
    chmod 0600 "${ROOTFS_MNT}/root/.ssh/authorized_keys" || fail "Failed to set SSH authorized_keys permissions ${INSIDE_IMAGE}."
  fi
fi

# Set the root password
if [[ -n "${ROOT_PASSWORD}" ]]; then
  printf "root:%s" "${ROOT_PASSWORD}" | chroot "${ROOTFS_MNT}" chpasswd || fail "Failed to set the root password ${INSIDE_IMAGE}."
fi

# Setup for systemd service to download and execute content from the "bootscript" kernel option
cp "${SOURCE_FILES}/bootscript.service" "${ROOTFS_MNT}/etc/systemd/system/bootscript.service" \
  || fail "Failed staging bootscript systemd unit file ${INSIDE_IMAGE}"
chroot "${ROOTFS_MNT}" \
  ln -sf "${ROOTFS_MNT}/etc/systemd/system/bootscript.service" /etc/systemd/system/multi-user.target.wants/bootscript.service \
  || fail "Failed to link the bootscript service to systemd startup."
cp "${SOURCE_FILES}/local_bootscript.sh" "${ROOTFS_MNT}/root/local_bootscript.sh" || fail "Failed staging the local bootscript."
chmod +x "${ROOTFS_MNT}/root/local_bootscript.sh" || fail "Failed to set permissions on the local boot script."

# Clean-up
[[ -d "${ROOTFS_MNT}/bin.usr-is-merged" ]] && rmdir "${ROOTFS_MNT}/bin.usr-is-merged"
[[ -d "${ROOTFS_MNT}/lib.usr-is-merged" ]] && rmdir "${ROOTFS_MNT}/lib.usr-is-merged"
[[ -d "${ROOTFS_MNT}/sbin.usr-is-merged" ]] && rmdir "${ROOTFS_MNT}/sbin.usr-is-merged"

# Build squashfs and un-mount the image
SQUASHFS="${IMG_FILE%.*}.squashfs"
mksquashfs "${ROOTFS_MNT}" "${SQUASHFS}" || fail "Failed to create squashfs"
printf "Un-mounting the image file...\n"
umount "${ROOTFS_MNT}" || fail "Failed to un-mount the root image filesystem."

printf "Completed image files at:\n${IMG_FILE}\n${SQUASHFS}\n"

