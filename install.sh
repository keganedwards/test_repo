#!/usr/bin/env bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

prompt() {
    echo -e "${BLUE}[PROMPT]${NC} $1"
}

# Function to get user input
get_input() {
    local prompt="$1"
    local var_name="$2"
    local secret="${3:-false}"
    
    while true; do
        if [ "$secret" = "true" ]; then
            read -s -p "$prompt" value
            echo
        else
            read -p "$prompt" value
        fi
        
        if [ -n "$value" ]; then
            eval "$var_name='$value'"
            break
        else
            warn "Please enter a value."
        fi
    done
}

# Function to detect disks and let user choose
choose_disk() {
    log "Available disks:"
    lsblk -d -n -o NAME,SIZE,MODEL | grep -E "^(sd|nvme|vd)" | nl -v 0
    echo
    
    local disks=($(lsblk -d -n -o NAME | grep -E "^(sd|nvme|vd)"))
    
    while true; do
        read -p "Select disk number: " disk_num
        if [[ "$disk_num" =~ ^[0-9]+$ ]] && [ "$disk_num" -lt "${#disks[@]}" ]; then
            DISK="/dev/${disks[$disk_num]}"
            log "Selected disk: $DISK"
            break
        else
            warn "Invalid selection. Please try again."
        fi
    done
}

# Function to setup disk encryption and partitioning
setup_disks() {
    log "Setting up disk partitioning and encryption..."
    
    # Unmount any existing mounts
    umount -R /mnt 2>/dev/null || true
    
    # Wipe the disk
    warn "This will completely erase $DISK!"
    read -p "Are you sure? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        error "Aborted by user"
    fi
    
    log "Wiping disk $DISK..."
    wipefs -af "$DISK"
    
    # Create partition table
    parted "$DISK" --script -- mklabel gpt
    parted "$DISK" --script -- mkpart ESP fat32 1MiB 512MiB
    parted "$DISK" --script -- set 1 esp on
    parted "$DISK" --script -- mkpart primary 512MiB 100%
    
    # Set partition variables based on disk type
    if [[ "$DISK" == *"nvme"* ]]; then
        BOOT_PARTITION="${DISK}p1"
        ROOT_PARTITION="${DISK}p2"
    else
        BOOT_PARTITION="${DISK}1"
        ROOT_PARTITION="${DISK}2"
    fi
    
    log "Boot partition: $BOOT_PARTITION"
    log "Root partition: $ROOT_PARTITION"
    
    # Setup LUKS encryption
    log "Setting up LUKS encryption..."
    echo -n "$ENCRYPTION_PASSWORD" | cryptsetup luksFormat "$ROOT_PARTITION" -
    echo -n "$ENCRYPTION_PASSWORD" | cryptsetup open "$ROOT_PARTITION" cryptroot -
    
    # Create filesystems
    log "Creating filesystems..."
    mkfs.fat -F 32 -n boot "$BOOT_PARTITION"
    mkfs.ext4 -L nixos /dev/mapper/cryptroot
    
    # Mount filesystems
    log "Mounting filesystems..."
    mount /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/boot
    mount "$BOOT_PARTITION" /mnt/boot
    
    # Create swapfile
    log "Creating swapfile for hibernation..."
    dd if=/dev/zero of=/mnt/swapfile bs=1M count=16384 status=progress
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
    swapon /mnt/swapfile
    
    # Store partition info for later use
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PARTITION")
    LUKS_NAME="luks-$ROOT_UUID"
    
    log "Root partition UUID: $ROOT_UUID"
    log "LUKS name: $LUKS_NAME"
}

# Function to generate initial NixOS configuration
generate_nixos_config() {
    log "Generating initial NixOS configuration..."
    nixos-generate-config --root /mnt
}

# Function to clone and setup the configuration
setup_config() {
    log "Cloning NixOS configuration from $GITHUB_REPO..."
    cd /mnt
    git clone "$GITHUB_REPO" nixos-config
    cd nixos-config
    
    # Check if hostname directory exists
    if [ ! -d "hosts/$HOSTNAME" ]; then
        error "Host directory 'hosts/$HOSTNAME' not found in the repository!"
    fi
    
    log "Found host configuration for $HOSTNAME"
    
    # Replace hardware-configuration.nix
    log "Updating hardware-configuration.nix..."
    if [ -f "/mnt/etc/nixos/hardware-configuration.nix" ]; then
        cp "/mnt/etc/nixos/hardware-configuration.nix" "hosts/$HOSTNAME/hardware-configuration.nix"
    else
        error "Generated hardware-configuration.nix not found!"
    fi
}

# Function to update boot.nix with correct values
update_boot_config() {
    log "Updating boot.nix configuration..."
    
    # Find boot.nix file
    BOOT_NIX_PATH=$(find "hosts/$HOSTNAME" -name "boot.nix" -type f | head -1)
    
    if [ -z "$BOOT_NIX_PATH" ]; then
        error "boot.nix not found in hosts/$HOSTNAME"
    fi
    
    log "Found boot.nix at: $BOOT_NIX_PATH"
    
    # Create new boot.nix content
    cat > "$BOOT_NIX_PATH" << EOF
# /hosts/$HOSTNAME/boot.nix
let
  # The NEW, CORRECT values from your fresh install
  ${HOSTNAME}RootLuksName = "$LUKS_NAME";
  ${HOSTNAME}RootLuksDevicePath = "/dev/disk/by-uuid/$ROOT_UUID";
in {
  swapDevices = [
    {
      device = "/swapfile";
      size = 16;
    }
  ];

  # This block is all you need. Your custom module will read this
  # and generate the correct boot.initrd.luks.devices and boot.initrd.clevis.devices.
  custom.boot.luksPartitions = {
    root = {
      luksName = \${${HOSTNAME}RootLuksName};
      devicePath = \${${HOSTNAME}RootLuksDevicePath};
    };
  };
}
EOF
    
    log "Updated boot.nix with correct LUKS values"
}

# Function to setup SOPS with rbw
setup_sops() {
    log "Setting up SOPS with rbw..."
    
    # Install rbw in nix-shell
    log "Installing rbw..."
    nix-shell -p rbw --run "
        log 'Please log into rbw:'
        rbw login
        rbw sync
        
        log 'Extracting NixOS AGE Key...'
        mkdir -p /root/.config/sops/age
        rbw get 'NixOS AGE Key' > /root/.config/sops/age/keys.txt
        
        if [ ! -s /root/.config/sops/age/keys.txt ]; then
            error 'Failed to extract AGE key from rbw'
        fi
        
        log 'AGE key successfully extracted'
    "
}

# Function to setup clevis auto-decryption
setup_clevis() {
    log "Setting up Clevis for auto-decryption..."
    
    # This will be handled by your NixOS configuration
    # Just noting it here for the rebuild process
    warn "Clevis setup will be handled during NixOS rebuild"
    warn "Make sure your configuration includes the necessary clevis modules"
}

# Function to rebuild NixOS
rebuild_nixos() {
    log "Rebuilding NixOS..."
    cd /mnt/nixos-config
    
    # Set root password
    echo "root:$PASSWORD" | chpasswd
    
    # Install NixOS with flakes
    log "Installing NixOS with flakes..."
    nixos-install --flake ".#$HOSTNAME" --no-root-passwd
    
    log "Setting user password in chroot..."
    nixos-enter --root /mnt -c "echo '$USERNAME:$PASSWORD' | chpasswd"
}

# Function to setup cryptenroll (post-install)
setup_cryptenroll() {
    log "Setting up systemd-cryptenroll..."
    
    nixos-enter --root /mnt -c "
        # Enroll TPM2 for auto-unlock
        if command -v systemd-cryptenroll >/dev/null 2>&1; then
            systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+2+7 $ROOT_PARTITION
            log 'TPM2 enrollment completed'
        else
            warn 'systemd-cryptenroll not available, skipping TPM enrollment'
        fi
    "
}

# Main script execution
main() {
    log "Starting NixOS installation script..."
    
    # Get user inputs
    get_input "GitHub repository URL (https): " GITHUB_REPO
    get_input "Hostname: " HOSTNAME
    get_input "Username: " USERNAME  
    get_input "Password (will be used for both user and root): " PASSWORD true
    get_input "Disk encryption password: " ENCRYPTION_PASSWORD true
    
    # Choose disk
    choose_disk
    
    # Confirm settings
    echo
    log "Configuration Summary:"
    echo "Repository: $GITHUB_REPO"
    echo "Hostname: $HOSTNAME"
    echo "Username: $USERNAME"
    echo "Disk: $DISK"
    echo
    read -p "Proceed with installation? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        error "Installation aborted"
    fi
    
    # Execute installation steps
    setup_disks
    generate_nixos_config
    setup_config
    setup_sops
    update_boot_config
    rebuild_nixos
    setup_cryptenroll
    
    log "Installation completed successfully!"
    log "You can now reboot into your new NixOS system"
    log "Remember to change your git remote to SSH after first boot"
    
    warn "Post-installation TODO:"
    echo "1. Change git remote to SSH in ~/nixos-config"
    echo "2. Verify Clevis auto-decryption is working"
    echo "3. Test hibernation with the swapfile"
}

# Run main function
main "$@"
