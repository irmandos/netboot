#!/bin/bash
# Called by the systemd "bootscript.service" to run once inside the netboot environment
#
# This script will parse kernel arguments for a "bootscript" option and will attempt to
# download and execute the target script.

function fail() {
    # Fail and exit, logging error message and returning optional exit code
    MESSAGE="${1:-Unexpected failure}"
    printf "%s\n" "${MESSAGE}"
    # Use the second arg as the exit code if present and an integer, else exit 1
    [[  $2 -eq $2 ]] &>/dev/null && RC=${2} || RC=1
    exit ${RC}
}


function parse_cmdline() {
    # Export SCRIPT_URL variable with the value of "bootscript" from kernel boot parameters
    for x in $(cat /proc/cmdline); do
        case $x in
            bootscript=*)
                export SCRIPT_URL="${x#bootscript=}" ;;
            *) ;;
        esac
    done
}


function download_file() {
    # Download the input file and export a LOCAL_FILE variable with the path of the local file
    RETRY=3
    [[ -n ${1} ]] || fail "download_file() requires a URL."
    TARGET_URL="${1}"
    FILE_NAME=$(basename "${1}")
    export LOCAL_FILE="/root/${FILE_NAME}"
    while [[ $RETRY -ne 0 ]]; do
        wget "${TARGET_URL}" -O "${LOCAL_FILE}"
        [[ $? -eq 0 && -s "${LOCAL_FILE}" ]] && return 0
        RETRY=$((RETRY -1))
        printf "Retrying download. ${RETRY} tries remaining.\n"
        sleep 2
    done
    fail "Download failed from: ${TARGET_URL}"
}


function run_script() {
    [[ -n ${1} ]] || fail "run_script() requires a file argument."
    SCRIPT="${1}"
    [[ -f "${SCRIPT}" ]] || fail "The script file does not exist: ${SCRIPT}"
    LOGFILE="${SCRIPT%.*}.log"
    chmod +x "${SCRIPT}" || fail "Failed setting execute bit on ${SCRIPT}"
    printf "Running script '%s' and logging to '%s'" "${SCRIPT}" "${LOGFILE}"
    "${SCRIPT}" | tee -a "${LOGFILE}"
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        printf "Boot script completed OK." 
    else
        printf "Failure running the boot script: '%s'" "${SCRIPT}"
    fi
}


parse_cmdline
[[ -n "${SCRIPT_URL}" ]] || fail "No bootscript defined."
download_file "${SCRIPT_URL}"
run_script "${LOCAL_FILE}"

