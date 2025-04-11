#!/bin/bash
# Install Ubuntu 22.04 or later to ZFS root - Boot from either Live media or netboot and run
# Ref: https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html

# Installation parameters
ROOT_DISK=/dev/vda              # All data on this disk will be destroyed
NEW_HOSTNAME=ubuzfs             # The hostname to be assigned to the new system
HIBERNATION=Y                   # Enable hibernation (requires a traditional swap partition outside of ZFS) Y/N
SWAP_SIZE=0                     # Swap size in GB.  Swap will use a ZFS volume unless HIBERNATION=Y
ROOT_PASSWD=password            # Initial password for the new root user
NEW_LOCALE="en_US.UTF-8"        # Set the locale
NEW_TIMEZONE="Africa/Johannesburg"       # Set the timezone
REBOOT=Y                        # Reboot automatically after completion (Y/N)


# Options for debootstrap
VERSION_CODENAME="noble"
DPKG_ARCH="amd64"
INCLUDE_PACKAGES="ubuntu-minimal,openssh-server,wget,nano,auto-apt-proxy"
EXCLUDE_PACKAGES="ubuntu-pro-client"
MIRROR="http://apt-cacher-ng.bothahome.co.za:3142/archive.ubuntu.com/ubuntu"    #No auto-apt-proxy, using full apt-cacher-ng url to make use of it

#echo 'Acquire::http::Proxy "http://apt-cacher-ng.bothahome.co.za:3142";' > /etc/apt/apt.conf.d/00aptproxy

# Re-run with sudo if not running as root
if [[ $(id -u) -ne 0 ]]
  then
  sudo ${BASH_SOURCE}
fi
[[ $(id -u) -ne 0 ]] && exit

function fail() {
  # Print the given message and exit
  printf "%s\n" "${1}"
  exit 1
}

[[ -b "${ROOT_DISK}" ]] || fail "${ROOT_DISK} is not a block device."

# Hibernation requires swap space on a traditional swap volume outside of ZFS
MEM_SIZE_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_SIZE_GB=$(( (MEM_SIZE_KB + 1048575) / 1048576 ))
if [[ ${HIBERNATION^^} = Y ]]
  then
  [[ $SWAP_SIZE -gt $MEM_SIZE_GB ]] || SWAP_SIZE=${MEM_SIZE_GB}
fi

printf "Updating package indexes...\n"
apt-get -qq update &>/dev/null || fail "Failed connection to package repository"

printf "Installing ZFS and installation packages...\n"
apt-get -qq install --yes debootstrap net-tools gdisk zfsutils-linux &>/dev/null || fail "Failed to install required packages."

# Prep the disk by destroying existing data and partitions
wipefs -a "${ROOT_DISK}" &>/dev/null
blkdiscard -f "${ROOT_DISK}" &>/dev/null
sgdisk --zap-all "${ROOT_DISK}" &>/dev/null || fail "Failed to destroy disk partitions."
partprobe &>/dev/null || fail "partprobe failed."

# Try to find the disk path "by-id" as recommended by the ZFS guides
if [[ -d /dev/disk/by-id ]]; then
  for LINK in /dev/disk/by-id/*; do
    LINK_TARGET=$(readlink $LINK)
    [[ ${LINK_TARGET##*/} = ${ROOT_DISK##*/} ]] && DISK_BY_ID="${LINK}" && break
  done
fi
ZFS_DISK=${DISK_BY_ID:-$ROOT_DISK}

# EFI firmware, hibernation, and ZFS encryption have specific partitioning requirements
EFI_PART=1
BIOS_PART=1
BOOT_PART=2
SWAP_PART=3
ZFS_PART=4
EFI_DEV="${ROOT_DISK}${EFI_PART}"
BIOS_DEV="${ROOT_DISK}${BIOS_PART}"
SWAP_DEV="${ROOT_DISK}${SWAP_PART}"
if [[ $ZFS_DISK = *by-id* ]]
  then
  RPOOL_DEV="${ZFS_DISK}-part${ZFS_PART}"
  BPOOL_DEV="${ZFS_DISK}-part${BOOT_PART}"
else
  RPOOL_DEV="${ZFS_DISK}${ZFS_PART}"
  BPOOL_DEV="${ZFS_DISK}${BOOT_PART}"
fi

# For BIOS firmware with no hibernation or encryption we can initialize the ZFS pool using the entire disk
# This will use different partitioning than defined above
if [[ ! -d /sys/firmware/efi && $HIBERNATION != "Y" ]]
  then
  printf "\nCreating ZFS rpool on device ${ZFS_DISK}...\n"
  zpool create -f \
    -o compatibility=grub2 \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O xattr=sa \
    -O relatime=on \
    -O canmount=off \
    -O compression=lz4 \
    -O normalization=formD \
    -O mountpoint=none \
    -R /mnt rpool ${ZFS_DISK} || fail "Failed to create ZFS pool on ${ZFS_DISK}."

    # Default ZFS partitioning leaves a small space free at the beginning of the disk that we will use for bios_boot
    printf "Creating the bios_boot partition for the GPT labeled disk...\n"
    sgdisk -a 1 -n 2:34:2047 -t 2:EF02 "${ROOT_DISK}" &>/dev/null || fail "Failed to create bios_boot partition."
else
  # Create an ESP or bios_boot partition as needed
  if [[ -d /sys/firmware/efi ]]
    then
    # EFI boot starts at 1M offset and 100M size
    printf "Creating the EFI system partition...\n"
    sgdisk -n ${EFI_PART}:1M:+100M -t ${EFI_PART}:EF00 "${ROOT_DISK}" &>/dev/null || fail "Failed to create EFI system partition."
  else
    # BIOS boot partition on blocks 34-2047
    printf "Creating the bios_boot partition for the GPT labeled disk...\n"
    sgdisk -a 1 -n ${BIOS_PART}:34:2047 -t ${BIOS_PART}:EF02 "${ROOT_DISK}" &>/dev/null || fail "Failed to create bios_boot partition."
  fi

  # Create the swap partition if hibernation was enabled
  if [[ ${HIBERNATION^^} = Y && $SWAP_SIZE -gt 0 ]]
    then
    printf "Creating a swap partition of ${SWAP_SIZE}GB size...\n"
    sgdisk -n ${SWAP_PART}:0:+${SWAP_SIZE}G -t ${SWAP_PART}:8200 "${ROOT_DISK}" &>/dev/null || fail "Failed to create swap partition."
  fi

  # Create a separate ZFS partition for /boot
  printf "Creating a separate partition for a ZFS boot pool...\n"
  sgdisk -n ${BOOT_PART}:0:+2G -t ${BOOT_PART}:BF00 "${ROOT_DISK}" &>/dev/null || fail "Failed to create the /boot partition."

  # All remaining space is used for the ZFS root pool
  sgdisk -n ${ZFS_PART}:0:0 -t ${ZFS_PART}:BF00 "${ROOT_DISK}" &>/dev/null || fail "Failed to create the ZFS data partition."

  sleep 3
  [[ -b $RPOOL_DEV ]] || fail "Device not available for root ZFS pool: ${RPOOL_DEV}"

  # All features are available since /boot will be on a separate zpool
  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O xattr=sa \
    -O dnodesize=auto \
    -O relatime=on \
    -O canmount=off \
    -O compression=lz4 \
    -O normalization=formD \
    -O mountpoint=none \
    -R /mnt rpool ${RPOOL_DEV} || fail "Failed to create ZFS pool on ${RPOOL_DEV}."
fi

# Filesystem layout separates user data from the OS
printf "Creating additional ZFS datasets...\n"
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=/ -o com.ubuntu.zsys:bootfs=yes -o com.ubuntu.zsys:last-used=$(date +%s) rpool/ROOT/ubuntu
# The 'var' dataset is only used as a container for other datasets and is not mounted as file system itself
zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off -o setuid=off -o exec=off -o devices=off rpool/ROOT/ubuntu/var
zfs create -o exec=on rpool/ROOT/ubuntu/var/lib
zfs create rpool/ROOT/ubuntu/var/log
zfs create rpool/ROOT/ubuntu/var/spool
zfs create rpool/ROOT/ubuntu/var/mail
zfs create -o com.sun:auto-snapshot=false rpool/ROOT/ubuntu/var/cache
zfs create -o com.sun:auto-snapshot=false -o mountpoint=/var/lib/nfs rpool/ROOT/ubuntu/var/nfs
zfs create -o com.sun:auto-snapshot=false -o exec=on rpool/ROOT/ubuntu/var/tmp
zfs create -o com.sun:auto-snapshot=false -o com.ubuntu.zsys:bootfs=no -o exec=on rpool/ROOT/ubuntu/tmp
zfs create -o com.ubuntu.zsys:bootfs-datasets=rpool/ROOT/ubuntu -o setuid=off -o devices=off -o mountpoint=/home rpool/home
zfs create -o mountpoint=/root rpool/home/root
if [[ ${HIBERNATION^^} != Y && $SWAP_SIZE -gt 0 ]]
  then
  # Create a ZFS volume for swap since we don't care about hibernation support
  zfs create -V ${SWAP_SIZE}G -o compression=zle \
    -o logbias=throughput -o sync=always \
    -o primarycache=metadata -o secondarycache=none \
    -o com.ubuntu.zsys:bootfs-datasets=rpool/ROOT/ubuntu \
    -o com.sun:auto-snapshot=false rpool/swap
fi

# Set basic filesystem permissions
chmod 700 /mnt/root
chmod 1777 /mnt/var/tmp

# apt will be unhappy later if these are missing
mkdir -p /mnt/var/lib/dpkg || fail "Failed to create /var/lib/dpkg"
touch /mnt/var/lib/dpkg/status || fail "Failed to create /var/lib/dpkg/status"

[[ -d /mnt/run ]] || mkdir /mnt/run
mount -t tmpfs tmpfs /mnt/run
[[ -d /mnt/run/lock ]] || mkdir /mnt/run/lock

printf "\nInstalling to the ZFS root using debootstrap...\n\n"
debootstrap \
 --arch="${DPKG_ARCH}" \
 --include="${INCLUDE_PACKAGES}" \
 --exclude="${EXCLUDE_PACKAGES}" \
 "${VERSION_CODENAME}" /mnt "${MIRROR}" \
  || fail "Installation failed running debootstrap"

printf "Performing system configuration...\n"
echo 'Acquire::http::Proxy "http://apt-cacher-ng.bothahome.co.za:3142";' > /mnt/etc/apt/apt.conf.d/00aptproxy
printf %b "root:${ROOT_PASSWD}" | sudo chroot /mnt chpasswd || fail "Failed to set the root password."
printf "${NEW_HOSTNAME}\n" >/mnt/etc/hostname || fail "Failed to set the system hostname."

# Configure package sources
cat << EOF >/mnt/etc/apt/sources.list || fail "Failed to setup apt sources.list"
# Generated by zfs-installer
deb http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${VERSION_CODENAME}-security main restricted universe multiverse
EOF

# Configuring network plan for the new system to use DHCP on all ethernet interfaces
cat << EOF >/mnt/etc/netplan/01-networkd-dhcp-all.yaml || fail "Failed to define the default network plan."
---
network:
  version: 2
  renderer: networkd
  ethernets:
    all_ethernet:
      match:
        name: e*
      dhcp4: true
EOF

# Set up /boot as a separate ZFS pool if a dedicated partition was created
if [[ -b $BPOOL_DEV ]]
  then
  zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -o compatibility=grub2 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O devices=off \
    -O acltype=posixacl -O xattr=sa \
    -O compression=off \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=none \
    -R /mnt bpool ${BPOOL_DEV} || fail "Failed to create ZFS bpool on ${BPOOL_DEV}."
fi
zfs create -o mountpoint=/boot bpool/boot

# Set up the swap partition or ZFS volume per user input
if [[ -b /dev/zvol/rpool/swap ]]
  then
  # Configure swap using a ZFS volume
  mkswap -f /dev/zvol/rpool/swap &>/dev/null || fail "Failed mkswap on ZFS swap volume."
  printf "/dev/zvol/rpool/swap none swap defaults 0 0\n" >> /mnt/etc/fstab
elif [[ -b ${SWAP_DEV} ]]
  then
  # Using the dedicated swap partition
  mkswap --label SWAP $SWAP_DEV &>/dev/null || fail "Failed mkswap on ${SWAP_DEV}"
  printf "/dev/disk/by-label/SWAP none swap defaults 0 0\n" >> /mnt/etc/fstab
fi


CHROOT_SCRIPT='/mnt/zfs-init'
##### BEGIN CHROOT SCRIPT #################################
cat << EOF > ${CHROOT_SCRIPT} || fail "Failed to write the helper script in the new ZFS root."
function fail() {
  printf %b "${1}\n"
  exit 1
}

printf "Setting locale to en_US.UTF-8 and timezone to US/Central...\n"
locale-gen --purge "${NEW_LOCALE}" &>/dev/null || fail "Failed running locale-gen"
update-locale LANG="${NEW_LOCALE}" &>/dev/null || fail "Failed running update-locale"
printf "${NEW_TIMEZONE}" > "/etc/timezone" || fail "Failed to update /etc/timezone"
dpkg-reconfigure --frontend noninteractive tzdata &>/dev/null || fail "Failed setting timezone"

printf "Updating apt sources in the new installation...\n"
apt-get clean
apt-get update -qq &>/dev/null || fail "Failed updating apt cache."
 
printf "   Enable SSH root login with password...\n"
sed -i 's/^#PermitRootLogin .*/PermitRootLogin Yes/g' /etc/ssh/sshd_config &>/dev/null

printf "   linux-image-generic...\n"
apt-get -qq install --yes --no-install-recommends linux-image-generic &>/dev/null || fail "Failed to install linux-image-generic"

printf "   zfsutils-linux...\n"
apt-get -qq install --yes zfsutils-linux &>/dev/null || fail "Failed to install zfsutils-linux"

printf "   zfs-initramfs...\n"
apt-get -qq install --yes zfs-initramfs &>/dev/null || fail "Failed to install zfs-initramfs"

printf "   zsys...\n"
apt-get -qq install --yes zsys &>/dev/null || fail "Failed to install zsys"

function configure_grub() {
  printf "   initramfs-tools grub-pc...\n"
  apt-get -qq install --yes initramfs-tools grub-pc &>/dev/null || fail "Failed installing initramfs-tools or grub-pc"
  apt purge --yes os-prober &>/dev/null || fail "Failed to remove os-prober"
  if [[ -b /dev/zvol/rpool/swap ]]
    then
    # Disable resume from hibernation as ZVOL is not imported when resume script runs
    echo 'RESUME=none' >/etc/initramfs-tools/scripts/local-premount/resume
  fi
  update-initramfs -c -k all &>/dev/null || fail "Failed running command: update-initramfs -c -k all"
  sed -i 's/"quiet splash"/""/g' /etc/default/grub
  sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/g' /etc/default/grub
  sed -i 's/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=tty0,115200 console=ttyS0,115200"/g' /etc/default/grub
  update-grub &>/dev/null || fail "Failed running command: update-grub"
}

# Configure grub for either EFI or BIOS
if [[ -d /sys/firmware/efi ]]; then
  printf "   dosfstools...\n"
  apt-get -qq install --yes dosfstools &>/dev/null
  mkdosfs -F 32 -s 1 -n EFI ${EFI_DEV} &>/dev/null || fail "Failed to create fat32 filesystem on ${EFI_DEV}"
  mkdir /boot/efi
  mount -t vfat ${EFI_DEV} /boot/efi || fail "Failed to mount /boot/efi"
  printf "/dev/disk/by-label/EFI /boot/efi vfat defaults 0 0\n" >> /etc/fstab
  apt-get -qq install --yes grub-efi-amd64 grub-efi-amd64-signed shim-signed &>/dev/null || fail "Failed to install grub packages."
  configure_grub
  printf "Running grub-install...\n"
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy || fail "grub-install failed!"

  # These steps establish correct mount order for bpool and the EFI partition
  mkdir /etc/zfs/zfs-list.cache
  touch /etc/zfs/zfs-list.cache/{bpool,rpool}
  zed -F &
  zfs set canmount=on bpool/boot
  zfs set canmount=on rpool/ROOT/ubuntu
  zpool set cachefile=/etc/zfs/zpool.cache rpool
  zpool set cachefile=/etc/zfs/zpool.cache bpool
  sleep 3
  pkill zed
  /usr/lib/systemd/system-generators/zfs-mount-generator
  sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*
else
  configure_grub
  printf "Running grub-install...\n"
  grub-install "${ROOT_DISK}" || fail "grub-install failed!"
fi

# Clean-up
[[ -d "${IMG_FILE_MNT}/bin.usr-is-merged" ]] && rmdir "${IMG_FILE_MNT}/bin.usr-is-merged"
[[ -d "${IMG_FILE_MNT}/lib.usr-is-merged" ]] && rmdir "${IMG_FILE_MNT}/lib.usr-is-merged"
[[ -d "${IMG_FILE_MNT}/sbin.usr-is-merged" ]] && rmdir "${IMG_FILE_MNT}/sbin.usr-is-merged"

EOF
##### END CHROOT SCRIPT ###################################


printf "\nSwitching to the new ZFS root for basic configuration.\n"
# Bind virtual filesystems from the LiveCD environment to the new system and chroot into it:
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys

if grep -q 'netboot=' /proc/cmdline
  then
  mkdir -p /mnt/run/systemd/resolve
  cat /etc/resolv.conf >/mnt/run/systemd/resolve/stub-resolv.conf
fi

# Run the config script in the change root
chmod +x "${CHROOT_SCRIPT}"
chroot /mnt bash -c "/${CHROOT_SCRIPT##*/}" || fail "Failure in the helper script."
rm -f "${CHROOT_SCRIPT}"

printf "\nExited ZFS root environment...\n\n"

printf "Un-mounting the alternate root and exporting the ZFS pool...\n\n"
if [[ -d /sys/firmware/efi && -d /mnt/boot/efi ]]
  then
  umount /mnt/boot/efi || fail "Failed to unmount /mnt/boot/efi"
fi
if zfs list bpool &>/dev/null
  then
  zfs snapshot -r bpool@shiny_new
  zpool export -f bpool
fi
umount -f /mnt/run
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zfs snapshot -r rpool@shiny_new
zpool export -f rpool

printf "Installation complete.  You should be able to reboot into the new system.\n"
printf "Remember to run host-namer.sh for proper hostnameing ELSE auto-apt-proxy WILL NOT WORK.\n"
printf "Once host-namer.sh has done it's job and auto-apt-proxy is installed you can remove /etc/apt/apt.conf.d/00aptproxy.\n"
if [[ $REBOOT = Y ]]; then
  printf "Rebooting...\n"
  reboot
fi

