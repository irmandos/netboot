#!/bin/bash
# lion-name-gen.sh - Dynamic hostname generator and FQDN setup tool
#
# This script can generate a new hostname based on hardware characteristics
# or ensure the Fully Qualified Domain Name (FQDN) is correctly set for
# the existing hostname. It manages the system hostname setting and
# relevant entries in /etc/hosts.
#
# Usage:
#   ./script_name.sh [options] [mode]
#
# Options:
#   -d, --domain <domain_name> : Override the default domain name.
#   -h, --help                 : Display this help message.
#
# Modes:
#   generate   : Generate new hostname based on hardware, set FQDN, update hosts. (For new systems)
#   fqdn       : Check current hostname, ensure FQDN is set correctly, update hosts. (For existing systems)
#   [none]     : (Default) Same as 'fqdn'.

# --- Configuration ---
DEFAULT_DOMAIN="bothahome.co.za" # The default domain used if -d is not specified
HOSTS_FILE="/etc/hosts"         # Path to the hosts file
# --- End Configuration ---

# --- Global Variables ---
# These are exported by generate_hostname so the main logic can use them
export short_name="" # Will hold the generated short hostname (e.g., simba-a1b2)
export fqdn=""       # Will hold the generated FQDN (e.g., simba-a1b2.bothahome.co.za)
# This holds the domain to be used, initialized to default, potentially overridden by -d option
DESIRED_DOMAIN="$DEFAULT_DOMAIN"

# --- Function: Display Help ---
# Shows usage instructions and exits.
usage() {
    echo "Usage: $0 [options] [mode]"
    echo ""
    echo "Options:"
    echo "  -d, --domain <domain_name> : Override the default domain name (default: $DEFAULT_DOMAIN)."
    echo "  -h, --help                 : Display this help message."
    echo ""
    echo "Modes:"
    echo "  generate   : Generate new hostname, set FQDN, update hosts."
    echo "  fqdn       : Check current hostname, ensure FQDN is set correctly, update hosts."
    echo "  [none]     : (Default) Same as 'fqdn'."
    echo ""
    exit 0 # Exit cleanly after showing help
}

# --- Function: Generate Hostname ---
# Detects system type, picks a name from a themed pool based on type,
# generates short_name and fqdn using MAC suffix and desired domain.
# Uses and sets global variables: DESIRED_DOMAIN, short_name, fqdn.
# Returns 0 on success, 1 on error.
generate_hostname() {
    echo "--- Starting Hostname Generation ---"
    echo "Using domain: ${DESIRED_DOMAIN}" # Inform user which domain is active

    # --- Define MAC address suffix ---
    # Local variables used within this function
    local primary_int mac_address up_int mac_suffix
    primary_int=$(ip route | grep '^default' | awk '{print $5}' | head -n1) # Get interface name from default route
    mac_address="" # Initialize

    # Try getting MAC from the primary interface found via default route
    if [ -n "$primary_int" ] && [ -e "/sys/class/net/${primary_int}/address" ]; then
        mac_address=$(cat "/sys/class/net/${primary_int}/address")
        echo "Using MAC from primary interface (${primary_int}): ${mac_address}"
    # Fallback: Try finding the first non-loopback, UP interface using 'ip link'
    elif command -v ip >/dev/null; then
        up_int=$(ip -o link show | awk -F': ' '$3 !~ /LOOPBACK|DOWN|UNKNOWN/ {print $2; exit}') # Get name of first UP interface
        if [ -n "$up_int" ] && [ -e "/sys/class/net/${up_int}/address" ]; then
            mac_address=$(cat "/sys/class/net/${up_int}/address")
            echo "Using MAC from first UP interface (${up_int}): ${mac_address}"
        fi
    fi

    # Final fallback: Use the first MAC found in /sys/class/net/e* (less reliable)
    if [ -z "$mac_address" ]; then
        echo "Warning: Could not reliably determine primary/UP interface MAC. Using first available e*/address."
        mac_address=$(cat /sys/class/net/e*/address | head -n1)
    fi

    # Error out if no MAC address could be determined
    if [ -z "$mac_address" ]; then
        echo "ERROR: Could not determine any MAC address for hostname generation."
        return 1 # Return error status
    fi

    # Extract the last two octets (4 hex digits) from the MAC address for the suffix
    mac_suffix=$(echo "$mac_address" | awk -F: '{print $5$6}')
    echo "Using MAC suffix: ${mac_suffix}"

    # --- System type detection ---
    echo "Detecting system type..."
    local type="desktop" # Default type if no specific match found
    local chassis_type system_product baseboard_product manufacturer

    # Check 1: Use systemd-detect-virt (most reliable on systemd systems)
    if command -v systemd-detect-virt &>/dev/null && systemd-detect-virt -q; then
        type="vm"
        echo "Detected VM using systemd-detect-virt."
    # Check 2: Look for hypervisor flags in /proc/cpuinfo
    elif grep -qE '(vmx|svm|hypervisor)' /proc/cpuinfo; then
        # If flags found, try to identify specific hypervisor using dmidecode (if available)
        if command -v dmidecode &>/dev/null; then
            manufacturer=$(dmidecode -s system-manufacturer 2>/dev/null)
            # Match against known hypervisor vendor names
            if [[ "$manufacturer" =~ VMware|Microsoft|QEMU|Xen|Oracle.*VirtualBox|Parallels ]]; then
                 type="vm"
                 echo "Detected VM using /proc/cpuinfo and dmidecode manufacturer (${manufacturer})."
            else
                # Flag found, but unknown manufacturer - still likely a VM
                type="vm"
                echo "Detected VM using /proc/cpuinfo (unknown hypervisor manufacturer: ${manufacturer:-N/A})."
            fi
        else
            # dmidecode not available, rely solely on cpuinfo flag
            type="vm"
            echo "Detected VM using /proc/cpuinfo (dmidecode not available)."
        fi
    # Check 3: Physical system types (if not detected as VM)
    else
        echo "System does not appear to be a VM, checking physical type..."
        # Get DMI information if dmidecode is available
        if command -v dmidecode &>/dev/null; then
            chassis_type=$(dmidecode -s chassis-type 2>/dev/null)
            system_product=$(dmidecode -s system-product-name 2>/dev/null)
            baseboard_product=$(dmidecode -s baseboard-product-name 2>/dev/null)
            echo "dmidecode - Chassis: '${chassis_type}', System: '${system_product}', Baseboard: '${baseboard_product}'"
        else
            echo "dmidecode not available, relying on /sys fallbacks."
        fi

        # Check for Small Form Factor (Netbook/Raspberry Pi/Atom/NUC etc.)
        if [[ "$baseboard_product" =~ Raspberry\ Pi ]] || \
           ( [ -e /proc/device-tree/model ] && grep -qi "Raspberry Pi" /proc/device-tree/model ) || \
           [[ "$system_product" =~ Netbook|Atom|NUC|BRIX ]] || \
           [[ "$chassis_type" =~ Embedded|Mini\ PC|Lunch\ Box ]] || \
           grep -qi "netbook\|atom" /sys/class/dmi/id/product_name 2>/dev/null; then # Fallback check
            type="netbook"
            echo "Classified as 'netbook' (Small Form Factor/RPi/Atom)."
        # Check for Laptop/Portable types
        elif [[ "$chassis_type" =~ Laptop|Notebook|Portable|Sub\ Notebook|Hand\ Held|Convertible|Detachable ]] || \
             grep -qi "laptop" /sys/class/dmi/id/chassis_type 2>/dev/null; then # Fallback check
            type="laptop"
            echo "Classified as 'laptop'."
        # Check for Desktop types
        elif [[ "$chassis_type" =~ Desktop|Low\ Profile\ Desktop|Pizza\ Box|Mini\ Tower|Tower|Docking\ Station|All\ in\ One|Space-saving ]]; then
            type="desktop"
            echo "Classified as 'desktop'."
        # Default case if none of the above match
        else
             echo "Could not specifically classify physical type, defaulting to 'desktop'."
             type="desktop" # Ensure default is explicitly set
        fi
    fi
    echo "Final detected system type for generation: ${type}"

    # --- Pick name from themed pool ---
    # Selects an array of names based on the detected system type
    local prefix # Array to hold potential name prefixes
    case "$type" in
      vm) prefix=("scar" "shenzi" "banzai" "ed" "jafar" "ursula" "hades" "maleficent" "sherekhan" "gaston" "cruella" "facilier" "yzma" "gothel");;
      netbook) prefix=("rafiki" "zazu" "kiara" "jiminy" "tinkerbell" "pascal" "chip" "dale" "gus" "jaq" "dory" "olaf" "abu" "meeko" "flit");;
      laptop) prefix=("simba" "nala" "sarabi" "aladdin" "jasmine" "ariel" "belle" "pocahontas" "mulan" "hercules" "tarzan" "kuzco" "rapunzel" "flynn");;
      desktop|*) prefix=("mufasa" "genie" "zeus" "triton" "merlin" "beast" "mickey" "goofy" "donald" "maui" "elsa" "anna" "moana" "baymax");; # Default case includes desktop
    esac

    # --- Generate Hostname Components ---
    # Uses a hash of the MAC suffix digits to pick a name pseudo-randomly from the selected pool
    local index numeric_mac_part folded_mac hash_base
    numeric_mac_part=$(echo "$mac_suffix" | tr -dc '0-9') # Extract only digits from MAC suffix

    # Generate a numeric hash base
    if [[ -z "$numeric_mac_part" ]]; then
        hash_base=$(date +%N) # Fallback to nanoseconds if no digits in MAC suffix
    else
         folded_mac=$(echo "$numeric_mac_part" | fold -w2 | head -n1) # Take first 2 digits
         if [[ -n "$folded_mac" ]]; then
             hash_base=$(( 10#${folded_mac} )) # Convert to base-10 number (prefix 10# handles leading zeros)
         else
             hash_base=$(date +%N) # Fallback if fold produced nothing
         fi
    fi

    # Ensure hash_base is actually a number before using modulo
    if ! [[ "$hash_base" =~ ^[0-9]+$ ]]; then
        echo "Warning: Could not generate numeric hash base from MAC/time. Using 0."
        hash_base=0
    fi
    # Check if the prefix array is valid before calculating index
    if [ ${#prefix[@]} -eq 0 ]; then
        echo "ERROR: Prefix array is empty for type '$type'. Cannot generate name."
        return 1 # Return error
    fi

    # Calculate index into the prefix array using modulo
    index=$((${hash_base} % ${#prefix[@]}))

    # --- Export generated names ---
    # These are exported so the main script part can use them after this function runs
    export short_name=${prefix[$index]}-$mac_suffix # Combine selected prefix and MAC suffix
    # Construct FQDN using the (potentially overridden) DESIRED_DOMAIN
    export fqdn="${short_name}.${DESIRED_DOMAIN}"

    echo "Generated Short Hostname: ${short_name}"
    echo "Generated FQDN: ${fqdn}"
    echo "--- Hostname Generation Complete ---"
    return 0 # Return success
}

# --- Function: Set Hostname and Update Hosts ---
# Takes target_short_name ($1) and target_fqdn ($2) as arguments.
# Sets the system hostname using hostnamectl (preferred) or hostname (fallback).
# Updates /etc/hostname for persistence if using fallback method.
# Rewrites /etc/hosts with standard entries plus the target FQDN/short name.
# Returns 0 on success, 1 on error.
set_hostname_and_hosts() {
    # Assign arguments to descriptive local variables
    local target_short_name="$1"
    local target_fqdn="$2"
    local hostname_set_success=false # Flag to track success
    local TEMP_HOSTS backup_file    # Variables for hosts file update

    # Validate input arguments
    if [ -z "$target_short_name" ] || [ -z "$target_fqdn" ]; then
        echo "ERROR (set_hostname_and_hosts): Missing short name or FQDN argument."
        return 1 # Return error
    fi

    echo "--- Applying Hostname and Hosts Configuration ---"
    echo "Target Short Name: ${target_short_name}"
    echo "Target FQDN: ${target_fqdn}"

    # --- Set the System Hostname (using target_fqdn) ---
    echo "Setting system hostname to ${target_fqdn}..."

    # Method 1: Use hostnamectl (standard for systemd)
    if command -v hostnamectl &> /dev/null; then
        echo "Attempting using 'hostnamectl set-hostname ${target_fqdn}'..."
        if hostnamectl set-hostname "${target_fqdn}"; then
            echo "SUCCESS: System hostname set using hostnamectl."
            hostname_set_success=true
        else
            echo "ERROR: 'hostnamectl set-hostname' command failed."
            echo "Attempting fallback methods..."
        fi
    fi

    # Method 2: Fallback using 'hostname' command (older systems)
    if ! $hostname_set_success && command -v hostname &> /dev/null; then
        echo "WARNING: 'hostnamectl' failed or not found. Using fallback 'hostname' command."
        echo "Attempting using 'hostname ${target_fqdn}'..."
        if hostname "${target_fqdn}"; then
            echo "SUCCESS: System hostname temporarily set."
            hostname_set_success=true # Mark success for now
            # Attempt persistence by writing FQDN to /etc/hostname
            if [ -w /etc/hostname ]; then # Check if file exists and is writable
                echo "Attempting to make change persistent by updating /etc/hostname..."
                # Backup existing /etc/hostname first
                cp /etc/hostname /etc/hostname.bak_$(date +%F_%T) 2>/dev/null || echo "Warning: Could not backup /etc/hostname"
                if echo "${target_fqdn}" > /etc/hostname; then
                     echo "SUCCESS: Updated /etc/hostname."
                else
                     echo "ERROR: Failed to write to /etc/hostname. Hostname change may not persist."
                     hostname_set_success=false # Revert success flag if persistence failed
                fi
            else
                echo "WARNING: Cannot write to /etc/hostname or file does not exist. Hostname change may not persist."
                hostname_set_success=false # Mark as not fully successful
            fi
        else
            echo "ERROR: 'hostname' command failed."
            # hostname_set_success remains false
        fi
    # Error if neither method worked or was found
    elif ! $hostname_set_success; then
         echo "ERROR: Neither 'hostnamectl' nor 'hostname' command succeeded or found. Cannot set hostname automatically."
         echo "WARNING: Hostname may not be correctly set. Continuing with /etc/hosts update."
         # Allow script to continue to fix /etc/hosts even if hostname setting failed
    fi

    # --- Update /etc/hosts ---
    # This section rewrites the hosts file to ensure consistency
    echo "Updating ${HOSTS_FILE}..."
    TEMP_HOSTS=$(mktemp) # Create a temporary file for the new content
    # Set a trap to automatically remove the temp file on exit, error, or interrupt
    trap 'rm -f "$TEMP_HOSTS"' RETURN INT TERM EXIT

    # Write the standard static entries and the dynamic entry to the temp file
    cat > "$TEMP_HOSTS" << EOF
# --- Standard Loopback Entries ---
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback

# --- Dynamic Hostname Entry (Managed by Script) ---
# This line relates the FQDN and short hostname to the loopback address 127.0.1.1
# It is typically used on systems without a permanent IP address to ensure
# applications can resolve the machine's own hostname.
EOF
    # Add the specific 127.0.1.1 line with FQDN first, then short name
    printf "%-15s %s %s\n" "127.0.1.1" "${target_fqdn}" "${target_short_name}" >> "$TEMP_HOSTS"
    # Add standard IPv6 multicast entries
    cat >> "$TEMP_HOSTS" << EOF

# --- Standard IPv6 Multicast Entries ---
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

# --- End of Script Managed Entries ---
# Entries below this line were preserved from the original ${HOSTS_FILE}
# or can be added manually.
# -------------------------------------

EOF

    # Append entries from the original hosts file that don't conflict with the managed ones
    if [ -f "$HOSTS_FILE" ]; then # Check if original file exists
        echo "Preserving additional entries from original ${HOSTS_FILE}..."
        # Use awk to print lines that don't match the IPs/patterns managed by this script
        awk '
        /^[[:space:]]*#/ {next} # Skip comment lines (to avoid duplicating our header comments)
        /^[[:space:]]*$/ {next} # Skip empty lines
        /^[[:space:]]*127\.0\.0\.1[[:space:]]+/ {next} # Skip existing 127.0.0.1 lines
        /^[[:space:]]*::1[[:space:]]+/ {next} # Skip existing ::1 lines
        /^[[:space:]]*127\.0\.1\.1[[:space:]]+/ {next} # Skip existing 127.0.1.1 lines
        /^[[:space:]]*ff02::1[[:space:]]+/ {next} # Skip existing ff02::1 lines
        /^[[:space:]]*ff02::2[[:space:]]+/ {next} # Skip existing ff02::2 lines
        {print} # Print any other lines
        ' "$HOSTS_FILE" >> "$TEMP_HOSTS"
    fi

    # Backup the original hosts file and replace it with the temporary file
    backup_file="${HOSTS_FILE}.bak_$(date +%F_%T)" # Create timestamped backup name
    echo "Backing up current ${HOSTS_FILE} to ${backup_file}"
    # Use cp -a to preserve permissions/ownership during backup
    if cp -a "$HOSTS_FILE" "$backup_file" 2>/dev/null; then
        echo "Backup successful."
        echo "Replacing ${HOSTS_FILE} with newly generated content."
        # Use 'cat' redirection to overwrite the original file with temp file content
        if cat "$TEMP_HOSTS" > "$HOSTS_FILE"; then
            echo "SUCCESS: ${HOSTS_FILE} updated successfully."
            # Ensure correct permissions and ownership
            chmod 644 "$HOSTS_FILE"; chown root:root "$HOSTS_FILE"
        else
            # Error handling: Failed to write new content
            echo "ERROR: Failed to write temporary hosts content to ${HOSTS_FILE}!"
            echo "Attempting to restore backup..."; cp -a "$backup_file" "$HOSTS_FILE" # Restore
            rm -f "$TEMP_HOSTS"; trap - RETURN INT TERM EXIT; return 1 # Clean up trap, return error
        fi
    else
        # Error handling: Failed to create backup
        echo "ERROR: Failed to backup ${HOSTS_FILE}! Proceeding without backup..."
        echo "Replacing ${HOSTS_FILE} with newly generated content (NO BACKUP CREATED)."
        if cat "$TEMP_HOSTS" > "$HOSTS_FILE"; then
            echo "SUCCESS: ${HOSTS_FILE} updated successfully."
            chmod 644 "$HOSTS_FILE"; chown root:root "$HOSTS_FILE"
        else
            # Error handling: Failed to write new content (and no backup exists)
            echo "ERROR: Failed to write temporary hosts content to ${HOSTS_FILE}! File might be inconsistent."
            rm -f "$TEMP_HOSTS"; trap - RETURN INT TERM EXIT; return 1 # Clean up trap, return error
        fi
    fi

    # Cleanup: Remove temporary file and disable the trap on successful completion
    rm -f "$TEMP_HOSTS"
    trap - RETURN INT TERM EXIT # Disable trap
    echo "--- Hostname and Hosts Configuration Complete ---"
    return 0 # Return success
}

# --- Function: Check and Set Current FQDN ---
# Gets the system's current short hostname.
# Constructs the desired FQDN using the current short name and DESIRED_DOMAIN.
# Calls set_hostname_and_hosts to apply the configuration.
# Uses the global DESIRED_DOMAIN variable.
# Returns 0 on success, 1 on error.
check_and_set_current_fqdn() {
    echo "--- Checking and Setting FQDN for Current Hostname ---"
    echo "Using domain: ${DESIRED_DOMAIN}" # Inform user which domain is active
    local current_short_name current_fqdn

    # Get the current short hostname (e.g., 'myhost' from 'myhost.example.com')
    if command -v hostname &>/dev/null; then
        # Try 'hostname -s' first
        current_short_name=$(hostname -s 2>/dev/null)
        # Fallback if '-s' fails or returns empty: get full hostname and cut at first dot
        if [ -z "$current_short_name" ]; then
             current_short_name=$(hostname | cut -d. -f1)
        fi
    else
        # Error if 'hostname' command is not available
        echo "ERROR: 'hostname' command not found. Cannot determine current hostname."
        return 1 # Return error
    fi

    # Error if we couldn't determine the short hostname
    if [ -z "$current_short_name" ]; then
        echo "ERROR: Could not determine current short hostname."
        return 1 # Return error
    fi

    echo "Current detected short hostname: ${current_short_name}"

    # Construct the desired FQDN using the potentially overridden DESIRED_DOMAIN
    current_fqdn="${current_short_name}.${DESIRED_DOMAIN}"
    echo "Desired FQDN based on current hostname: ${current_fqdn}"

    # Call the main function to apply the hostname and update /etc/hosts
    set_hostname_and_hosts "$current_short_name" "$current_fqdn"
    # Pass the return status of set_hostname_and_hosts back up
    return $?
}


# --- Main Script Logic ---

# Step 1: Check for Root Privileges
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root (e.g., using sudo)."
   exit 1 # Exit immediately if not root
fi

# Step 2: Option Parsing using getopt
# Define short options (-h, -d with argument) and long options (--help, --domain with argument)
SHORT_OPTS="hd:"
LONG_OPTS="help,domain:"
# Check if the external 'getopt' command is available
if ! command -v getopt &> /dev/null; then
    echo "ERROR: 'getopt' command not found. Cannot parse options."
    exit 1
fi
# Use getopt to parse the options, handling potential errors and spaces in arguments
# -o: short options, --long: long options, -n: script name for errors, --: separates options from arguments
PARSED_OPTIONS=$(getopt -o "$SHORT_OPTS" --long "$LONG_OPTS" -n "$0" -- "$@")
if [ $? -ne 0 ]; then
    # getopt returns non-zero status if parsing failed (e.g., invalid option)
    usage # Show help message on parsing error
fi
# Reset positional parameters ($1, $2, etc.) to the parsed/reordered output from getopt
eval set -- "$PARSED_OPTIONS"

# Step 3: Process Parsed Options
# Loop through the parsed options until '--' is encountered
while true; do
    case "$1" in
        -h|--help)
            usage # Show help and exit
            ;;
        -d|--domain)
            DESIRED_DOMAIN="$2" # Override the default domain with the provided argument
            shift 2 # Consume the option (-d) and its argument (<domain_name>)
            ;;
        --)
            shift # Consume the '--' marker
            break # Exit the loop, options are processed
            ;;
        *)
            # This case should not be reached if getopt works correctly
            echo "ERROR: Internal option parsing error!"
            exit 1
            ;;
    esac
done

# Step 4: Determine Execution Mode
# The first remaining positional parameter ($1) is the mode (generate/fqdn)
# Default to 'fqdn' if no mode is specified after options.
MODE="${1:-fqdn}"

# Step 5: Execute Based on Mode
exit_status=0 # Initialize exit status
case "$MODE" in
    generate)
        # Generate new hostname and set FQDN
        echo "Mode: generate"
        if generate_hostname; then # Call generation function, check its return status
            # Check if generation actually produced names (should always if function returns 0)
            if [ -n "$short_name" ] && [ -n "$fqdn" ]; then
                # Call function to set hostname and update hosts, store its exit status
                set_hostname_and_hosts "$short_name" "$fqdn"
                exit_status=$?
            else
                # Should not happen if generate_hostname returns 0, but good practice to check
                echo "ERROR: Hostname generation function succeeded but did not export names."
                exit_status=1
            fi
        else
             # generate_hostname returned an error
             echo "ERROR: Hostname generation failed."
             exit_status=1
        fi
        ;;
    fqdn)
        # Check/Set FQDN for the current hostname
        echo "Mode: fqdn (Check/Set FQDN for current hostname)"
        check_and_set_current_fqdn # Call check/set function, store its exit status
        exit_status=$?
        ;;
    *)
        # Handle invalid mode argument
        echo "ERROR: Invalid mode specified: '$1'"
        usage # Show help message
        exit_status=1
        ;;
esac

# Step 6: Final Exit
echo "--- Script Finished (Exit Status: $exit_status) ---"
exit $exit_status # Exit with the final status code

