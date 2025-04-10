#!/bin/bash
# Build a custom initrd file for netboot

BASEDIR=$(dirname $(realpath ${0}))
NETWDIR=="${BASEDIR}/pumba"
CONFDIR="${BASEDIR}/initramfs"
OUTFILE="${NETWDIR}/initrd.gz"

function fail() {
  printf "%s\n" "${1}"
  exit 1
}

[[ -d ${CONFDIR} ]] || fail "CONFDIR not found: ${CONFDIR}"
echo "Building initramfs at ${OUTFILE}..."
mkinitramfs -d "${CONFDIR}" -o "${OUTFILE}" || fail "Error running mkinitramfs."

