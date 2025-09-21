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

# Function to retry password input
retry_password_input() {
    local prompt_text="$1"
    local confirm_text="$2"
    local password1 password2
    
    while true; do
        prompt "$prompt_text"
        read -sr password1
        echo
        prompt "$confirm_text"
        read -sr password2
        echo
        
        if [ "$password1" = "$password2" ]; then
            echo "$password1"
            return 0
        else
            warn "Passwords do not match! Please try again."
            echo
        fi
    done
}

# Banner
echo -e "${GREEN}"
echo "=================================="
echo "  NixOS Installation Script"
echo "=================================="
echo -e "${NC}"

# Prompt for GitHub username (simplified)
prompt "Enter your GitHub username:"
read -r GITHUB_USERNAME
GITHUB_REPO="https://github.com/${GITHUB_USERNAME}/nixos-config"
info "Using repository: $GITHUB_REPO"

# Prompt for hostname
prompt "Enter hostname for this machine:"
read -r HOSTNAME

# Get user password with retry
USER_PASSWORD=$(retry_password_input "Enter password for your user (will also be used for root):" "Confirm password:")

# Get encryption password with retry
ENCRYPTION_PASSWORD=$(retry_password_input "Enter disk encryption password:" "Confirm encryption password:")

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

# Setup rbw and extract SOPS key with retry logic
info "Setting up rbw for SOPS key extraction..."

# Set up environment for rbw in the live USB
export GPG_TTY=$(tty)
export DISPLAY=:0

# Create the target directory for age key (in the mounted system)
mkdir -p /mnt/root/.config/sops/age

# Configure rbw with retry logic
while true; do
    nix-shell -p rbw pinentry-curses gnupg --run "
        # Configure GPG to use curses pinentry
        mkdir -p ~/.gnupg
        echo 'pinentry-program \$(which pinentry-curses)' > ~/.gnupg/gpg-agent.conf
        
        # Kill any existing gpg-agent to force reload of config
        pkill gpg-agent 2>/dev/null || true
        
        echo '=== Configuring rbw ==='
        echo 'Enter your Bitwarden email:'
        read -r RBW_EMAIL
        rbw config set email \"\$RBW_EMAIL\"
        
        echo 'Are you using a self-hosted Bitwarden? (y/N)'
        read -r SELF_HOSTED
        if [[ \"\$SELF_HOSTED\" =~ ^[Yy]$ ]]; then
            echo 'Enter base URL:'
            read -r BASE_URL
            rbw config set base_url \"\$BASE_URL\"
        fi
        
        # Set pinentry to curses for rbw
        rbw config set pinentry pinentry-curses
        
        echo '=== Logging into rbw ==='
        if ! rbw login; then
            echo 'Login failed!'
            exit 1
        fi
        
        echo '=== Unlocking rbw ==='
        if ! rbw unlock; then
            echo 'Unlock failed!'
            exit 1
        fi
        
        echo '=== Extracting NixOS AGE Key ==='
        # Extract to both locations to ensure it's found
        mkdir -p /root/.config/sops/age
        mkdir -p /mnt/root/.config/sops/age
        
        if ! rbw get 'NixOS AGE Key' > /tmp/age_key.txt; then
            echo 'Failed to extract SOPS key!'
            exit 1
        fi
        
        # Copy to both locations
        cp /tmp/age_key.txt /root/.config/sops/age/keys.txt
        cp /tmp/age_key.txt /mnt/root/.config/sops/age/keys.txt
        chmod 600 /root/.config/sops/age/keys.txt
        chmod 600 /mnt/root/.config/sops/age/keys.txt
        rm /tmp/age_key.txt
        
        # Verify the key was extracted
        if [ ! -s /root/.config/sops/age/keys.txt ] || [ ! -s /mnt/root/.config/sops/age/keys.txt ]; then
            echo 'ERROR: SOPS key file is empty!'
            exit 1
        fi
        
        echo 'SOPS key extracted successfully!'
    " && break || {
        warn "rbw setup failed. This could be due to:"
        warn "  - Incorrect email or password"
        warn "  - Network connectivity issues"
        warn "  - Secret name mismatch (should be exactly 'NixOS AGE Key')"
        echo
        prompt "Try again? (y/N)"
        read -r RETRY
        if [[ ! "$RETRY" =~ ^[Yy]$ ]]; then
            error "Cannot continue without SOPS key"
        fi
    }
done

# Verify SOPS key exists and is valid
info "Verifying SOPS key..."
[ -s /mnt/root/.config/sops/age/keys.txt ] || error "SOPS key file is missing or empty in mounted system!"
info "SOPS key verified!"

# Update hardware-configuration.nix
info "Updating hardware-configuration.nix..."
cp /mnt/etc/nixos/hardware-configuration.nix ~/nixos-config/hosts/"$HOSTNAME"/hardware-configuration.nix

# Find and update boot.nix
info "Finding boot.nix..."
BOOT_NIX=$(find ~/nixos-config/hosts/"$HOSTNAME" -name "boot.nix" -type f | head -n 1)

[ -n "$BOOT_NIX" ] || error "boot.nix not found in ~/nixos-config/hosts/$HOSTNAME"

info "Updating boot.nix at $BOOT_NIX..."
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
      size = $((SWAP_GB * 1024));  # Size in MB
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

# Setup Clevis for TPM auto-decryption with better error handling
prompt "Do you want to enable TPM auto-decryption with Clevis? (y/N)"
read -r ENABLE_CLEVIS

if [[ "$ENABLE_CLEVIS" =~ ^[Yy]$ ]]; then
    info "Setting up Clevis for TPM-based auto-decryption..."
    
    # Check if TPM is available and accessible
    if [ ! -e /dev/tpm0 ] && [ ! -e /dev/tpmrm0 ]; then
        warn "No TPM device found at /dev/tpm0 or /dev/tpmrm0"
        warn "Skipping Clevis setup."
        ENABLE_CLEVIS="n"
    else
        info "TPM device found, proceeding with Clevis setup..."
        
        # Try to set up Clevis with detailed error reporting
        if nix-shell -p clevis luksmeta cryptsetup tpm2-tools tpm2-abrmd --run "
            set -x  # Enable debug output
            
            # Check TPM status
            echo 'Checking TPM status...'
            tpm2_getcap properties-fixed 2>&1 || {
                echo 'TPM2 tools cannot access TPM!'
                exit 1
            }
            
            # Try to bind with clevis
            echo 'Attempting Clevis binding...'
            echo -n '$ENCRYPTION_PASSWORD' | clevis luks bind -d '$ROOT_PART' tpm2 '{}' -y
        "; then
            info "Clevis TPM binding completed successfully!"
        else
            warn "Clevis setup failed. Detailed error information:"
            warn "  - Check that TPM is enabled in BIOS/UEFI"
            warn "  - Verify TPM is not in restricted mode"
            warn "  - Ensure no BitLocker or other TPM usage conflicts"
            warn "  - TPM may need to be cleared/reset"
            warn ""
            warn "You can manually set up Clevis after installation with:"
            warn "  echo -n 'password' | sudo clevis luks bind -d $ROOT_PART tpm2 '{}'"
            
            prompt "Continue without auto-decryption? (y/N)"
            read -r CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                error "Installation cancelled due to Clevis failure"
            fi
            ENABLE_CLEVIS="n"
        fi
    fi
else
    info "Skipping Clevis setup. You'll need to enter encryption password on boot."
fi

# Install NixOS
info "Installing NixOS with flake configuration..."
if ! nixos-install --flake ~/nixos-config#"$HOSTNAME" --root /mnt --no-root-passwd; then
    error "nixos-install failed! Check the error messages above."
fi

# Set passwords
info "Setting passwords..."
echo "root:$USER_PASSWORD" | nixos-enter --root /mnt -c 'chpasswd'

# Determine your regular username
prompt "Enter your regular username (not root):"
read -r REGULAR_USER

echo "$REGULAR_USER:$USER_PASSWORD" | nixos-enter --root /mnt -c 'chpasswd' 2>/dev/null || warn "Could not set password for $REGULAR_USER (user might not exist yet)"

# Copy nixos-config to installed system
info "Copying nixos-config to installed system..."
mkdir -p /mnt/home/"$REGULAR_USER"
cp -r ~/nixos-config /mnt/home/"$REGULAR_USER"/nixos-config
nixos-enter --root /mnt -c "chown -R $REGULAR_USER:users /home/$REGULAR_USER/nixos-config" 2>/dev/null || true

# Also copy to root
cp -r ~/nixos-config /mnt/root/nixos-config

# Copy SOPS key to user's home if they need it
mkdir -p /mnt/home/"$REGULAR_USER"/.config/sops/age
cp /mnt/root/.config/sops/age/keys.txt /mnt/home/"$REGULAR_USER"/.config/sops/age/keys.txt
nixos-enter --root /mnt -c "chown -R $REGULAR_USER:users /home/$REGULAR_USER/.config" 2>/dev/null || true

# Setup git for SSH (reminder)
cat > /mnt/root/setup-git-ssh.sh << 'EOF'
#!/usr/bin/env bash
# Run this after first boot to switch to SSH
cd ~/nixos-config
git remote set-url origin $(git remote get-url origin | sed 's|https://github.com/|git@github.com:|')
echo "Git remote updated to use SSH"

# Also update in user's home directory
if [ -d /home/*/nixos-config ]; then
    for dir in /home/*/nixos-config; do
        cd "$dir"
        git remote set-url origin $(git remote get-url origin | sed 's|https://github.com/|git@github.com:|')
        echo "Git remote updated to use SSH in $dir"
    done
fi
EOF
chmod +x /mnt/root/setup-git-ssh.sh

info ""
info "======================================"
info "  Installation Complete!"
info "======================================"
info ""
info "Summary:"
info "  - Hostname: $HOSTNAME"
info "  - Repository: $GITHUB_REPO"
info "  - Encrypted root: $ROOT_PART (UUID: $ROOT_UUID)"
info "  - LUKS name: $LUKS_NAME"
info "  - Swap file: ${SWAP_GB}GB"
if [[ "$ENABLE_CLEVIS" =~ ^[Yy]$ ]]; then
    info "  - TPM auto-decryption: Enabled"
else
    info "  - TPM auto-decryption: Disabled"
fi
info ""
info "Next steps:"
info "  1. Reboot into your new system"
if [[ ! "$ENABLE_CLEVIS" =~ ^[Yy]$ ]]; then
    info "  2. Enter your encryption password when prompted"
fi
info "  2. Run: sudo /root/setup-git-ssh.sh"
info "  3. Verify your system boots correctly"
info ""

prompt "Press Enter to reboot or Ctrl+C to cancel..."
read -r
reboot
