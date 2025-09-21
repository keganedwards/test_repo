#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}INFO: $1${NC}"
}

warn() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

prompt() {
    echo -e "${BLUE}$1${NC}"
}

# Banner
echo -e "${GREEN}"
echo "=================================="
echo "  NixOS Installation Script"
echo "=================================="
echo -e "${NC}"

# Prompt for GitHub repo
prompt "Enter your GitHub repo URL (HTTPS):"
read -r GITHUB_REPO

# Prompt for hostname
prompt "Enter hostname for this machine:"
read -r HOSTNAME

# Prompt for user password
prompt "Enter password for your user (will also be used for root):"
read -sr USER_PASSWORD
echo
prompt "Confirm password:"
read -sr USER_PASSWORD_CONFIRM
echo

[ "$USER_PASSWORD" = "$USER_PASSWORD_CONFIRM" ] || error "Passwords do not match!"

# Prompt for encryption password
prompt "Enter disk encryption password:"
read -sr ENCRYPTION_PASSWORD
echo
prompt "Confirm encryption password:"
read -sr ENCRYPTION_PASSWORD_CONFIRM
echo

[ "$ENCRYPTION_PASSWORD" = "$ENCRYPTION_PASSWORD_CONFIRM" ] || error "Encryption passwords do not match!"

# Prompt for Bitwarden/rbw configuration
prompt "Enter your Bitwarden email address:"
read -r BITWARDEN_EMAIL

prompt "Enter your Bitwarden server URL (or press Enter for default bitwarden.com):"
read -r BITWARDEN_URL
BITWARDEN_URL=${BITWARDEN_URL:-"https://vault.bitwarden.com"}

# Detect and select disk
info "Available disks:"
lsblk -dno NAME,SIZE,TYPE | grep disk

prompt "Enter disk to install to (e.g., nvme0n1, sda):"
read -r DISK_NAME
DISK="/dev/$DISK_NAME"

[ -b "$DISK" ] || error "Disk $DISK does not exist!"

warn "This will ERASE ALL DATA on $DISK!"
prompt "Type 'YES' to continue:"
read -r CONFIRM
[ "$CONFIRM" = "YES" ] || error "Installation cancelled"

# Partition and encrypt disk
info "Partitioning disk..."
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:boot "$DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:root "$DISK"

# Determine partition naming
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    BOOT_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    BOOT_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# Format boot partition
info "Formatting boot partition..."
mkfs.fat -F 32 -n BOOT "$BOOT_PART"

# Encrypt root partition
info "Encrypting root partition..."
echo -n "$ENCRYPTION_PASSWORD" | cryptsetup luksFormat --type luks2 "$ROOT_PART" -
echo -n "$ENCRYPTION_PASSWORD" | cryptsetup open "$ROOT_PART" cryptroot -

# Format encrypted partition
info "Formatting encrypted partition..."
mkfs.ext4 -L nixos /dev/mapper/cryptroot

# Get UUIDs
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
LUKS_NAME="luks-${ROOT_UUID}"

# Mount filesystems
info "Mounting filesystems..."
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot

# Create swap file
info "Creating swap file for hibernation..."
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
SWAP_GB=$((RAM_GB + 2))
dd if=/dev/zero of=/mnt/swapfile bs=1G count=$SWAP_GB status=progress
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

# Generate initial config
info "Generating initial NixOS configuration..."
nixos-generate-config --root /mnt

# Clone nixos-config
info "Cloning nixos-config from $GITHUB_REPO..."
git clone "$GITHUB_REPO" ~/nixos-config

# Check hostname directory exists
[ -d ~/nixos-config/hosts/"$HOSTNAME" ] || error "No configuration found for hostname '$HOSTNAME' in ~/nixos-config/hosts/"

info "Found configuration for $HOSTNAME"

# Setup rbw and extract SOPS key with proper error handling
info "Setting up rbw for SOPS key extraction..."
export HOME=/root
mkdir -p /root/.config/rbw

# Configure rbw properly
nix-shell -p rbw --run "
    rbw config set email '$BITWARDEN_EMAIL'
    rbw config set base_url '$BITWARDEN_URL'
    
    echo 'Please log into rbw...'
    if ! rbw login; then
        echo 'ERROR: Failed to login to rbw'
        exit 1
    fi
    
    echo 'Unlocking rbw...'
    if ! rbw unlock; then
        echo 'ERROR: Failed to unlock rbw'
        exit 1
    fi
    
    echo 'Testing rbw access...'
    if ! rbw list >/dev/null 2>&1; then
        echo 'ERROR: rbw is not working properly'
        exit 1
    fi
    
    echo 'Extracting NixOS AGE Key...'
    mkdir -p /root/.config/sops/age
    if ! rbw get 'NixOS AGE Key' > /root/.config/sops/age/keys.txt; then
        echo 'ERROR: Failed to extract NixOS AGE Key'
        exit 1
    fi
    chmod 600 /root/.config/sops/age/keys.txt
    
    # Verify the key was extracted
    if [ ! -s /root/.config/sops/age/keys.txt ]; then
        echo 'ERROR: SOPS key file is empty'
        exit 1
    fi
    
    echo 'SOPS key extracted successfully!'
"

# Verify SOPS key was extracted
[ -f /root/.config/sops/age/keys.txt ] && [ -s /root/.config/sops/age/keys.txt ] || error "SOPS key extraction failed!"

info "SOPS key verified successfully!"

# Update hardware-configuration.nix
info "Updating hardware-configuration.nix..."
cp /mnt/etc/nixos/hardware-configuration.nix ~/nixos-config/hosts/"$HOSTNAME"/hardware-configuration.nix

# Find and update boot.nix
info "Finding boot.nix..."
BOOT_NIX=$(find ~/nixos-config/hosts/"$HOSTNAME" -name "boot.nix" -type f | head -n 1)

[ -n "$BOOT_NIX" ] || error "boot.nix not found in ~/nixos-config/hosts/$HOSTNAME"

info "Updating boot.nix at $BOOT_NIX..."

# Get swap file size in MB for the config
SWAP_MB=$((SWAP_GB * 1024))

# Create a more compatible boot.nix
cat > "$BOOT_NIX" << EOF
# /hosts/$HOSTNAME/boot.nix
let
  # The NEW, CORRECT values from your fresh install
  ${HOSTNAME}RootLuksName = "$LUKS_NAME";
  ${HOSTNAME}RootLuksDevicePath = "/dev/disk/by-uuid/$ROOT_UUID";
in {
  swapDevices = [
    {
      device = "/swapfile";
      size = $SWAP_MB;  # Size in MB
    }
  ];

  # This block is all you need. Your custom module will read this
  # and generate the correct boot.initrd.luks.devices and boot.initrd.clevis.devices.
  custom.boot.luksPartitions = {
    root = {
      luksName = ${HOSTNAME}RootLuksName;
      devicePath = ${HOSTNAME}RootLuksDevicePath;
    };
  };
}
EOF

info "boot.nix updated successfully!"

# Create a temporary configuration for the initial install that includes basic LUKS support
info "Creating temporary configuration for initial install..."
cat >> /mnt/etc/nixos/configuration.nix << EOF

# Temporary LUKS configuration for initial boot
boot.initrd.luks.devices."cryptroot" = {
  device = "/dev/disk/by-uuid/$ROOT_UUID";
  allowDiscards = true;
};

# Enable flakes temporarily
nix.settings.experimental-features = [ "nix-command" "flakes" ];
EOF

# Setup Clevis for TPM auto-decryption (but don't fail if TPM isn't available)
info "Setting up Clevis for TPM-based auto-decryption..."
if nix-shell -p clevis luksmeta cryptsetup --run "
    if tpm2_getcap properties-fixed 2>/dev/null; then
        echo 'TPM detected, setting up Clevis binding...'
        echo -n '$ENCRYPTION_PASSWORD' | clevis luks bind -d '$ROOT_PART' tpm2 '{}' -y
        echo 'Clevis TPM binding complete!'
    else
        echo 'WARNING: No TPM detected, skipping Clevis setup'
        exit 0
    fi
"; then
    info "Clevis setup completed"
else
    warn "Clevis setup failed or TPM not available - system will require manual password entry"
fi

# First install with basic configuration
info "Installing NixOS with basic configuration..."
nixos-install --root /mnt

# Set passwords
info "Setting passwords..."
echo "root:$USER_PASSWORD" | nixos-enter --root /mnt -c 'chpasswd'

# Copy nixos-config and SOPS key to installed system
info "Copying nixos-config and SOPS key to installed system..."
cp -r ~/nixos-config /mnt/root/nixos-config
mkdir -p /mnt/root/.config/sops/age
cp /root/.config/sops/age/keys.txt /mnt/root/.config/sops/age/keys.txt
chmod 600 /mnt/root/.config/sops/age/keys.txt

# Create a post-install script for switching to flake configuration
cat > /mnt/root/switch-to-flake.sh << EOF
#!/usr/bin/env bash
set -euo pipefail

echo "Switching to flake configuration..."
cd /root/nixos-config

# Enable flakes if not already enabled
if ! grep -q "experimental-features.*flakes" /etc/nixos/configuration.nix; then
    echo "Enabling flakes..."
    nixos-rebuild switch --flake .#$HOSTNAME
else
    nixos-rebuild switch --flake .#$HOSTNAME
fi

echo "Flake configuration applied successfully!"
EOF

chmod +x /mnt/root/switch-to-flake.sh

# Setup git for SSH (reminder)
cat > /mnt/root/setup-git-ssh.sh << EOF
#!/usr/bin/env bash
# Run this after first boot to switch to SSH
cd ~/nixos-config
git remote set-url origin \$(git remote get-url origin | sed 's|https://github.com/|git@github.com:|')
echo "Git remote updated to use SSH"
EOF
chmod +x /mnt/root/setup-git-ssh.sh

info ""
info "======================================"
info "  Installation Complete!"
info "======================================"
info ""
info "Summary:"
info "  - Hostname: $HOSTNAME"
info "  - Encrypted root: $ROOT_PART (UUID: $ROOT_UUID)"
info "  - LUKS name: $LUKS_NAME"
info "  - Swap file: ${SWAP_GB}GB"
info "  - SOPS key: Extracted and copied"
info ""
info "Next steps after reboot:"
info "  1. Boot should work with password prompt"
info "  2. Run: /root/switch-to-flake.sh"
info "  3. Run: /root/setup-git-ssh.sh"
info "  4. Reboot to test full flake configuration"
info ""

prompt "Press Enter to reboot or Ctrl+C to cancel..."
read -r
reboot
