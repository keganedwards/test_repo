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
echo "  systemd-boot + systemd-cryptenroll"
echo "=================================="
echo -e "${NC}"

# Check if we're booted in EFI mode
if [ ! -d /sys/firmware/efi ]; then
    error "This script requires EFI boot mode. Please boot the live USB in EFI mode, not Legacy/BIOS."
fi

info "✓ System is booted in EFI mode"

# Prompt for GitHub username
prompt "Enter your GitHub username:"
read -r GITHUB_USERNAME
GITHUB_REPO="https://github.com/${GITHUB_USERNAME}/nixos-config"
info "Will clone from: $GITHUB_REPO"

# Prompt for hostname
prompt "Enter hostname for this machine:"
read -r HOSTNAME

# Prompt for user password with retry logic
while true; do
    prompt "Enter password for your user (will also be used for root):"
    read -sr USER_PASSWORD
    echo
    prompt "Confirm password:"
    read -sr USER_PASSWORD_CONFIRM
    echo
    
    if [ "$USER_PASSWORD" = "$USER_PASSWORD_CONFIRM" ]; then
        break
    else
        warn "Passwords do not match! Please try again."
    fi
done

# Prompt for encryption password with retry logic
while true; do
    prompt "Enter disk encryption password:"
    read -sr ENCRYPTION_PASSWORD
    echo
    prompt "Confirm encryption password:"
    read -sr ENCRYPTION_PASSWORD_CONFIRM
    echo
    
    if [ "$ENCRYPTION_PASSWORD" = "$ENCRYPTION_PASSWORD_CONFIRM" ]; then
        break
    else
        warn "Encryption passwords do not match! Please try again."
    fi
done

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

# Partition disk for EFI
info "Partitioning disk for EFI boot..."
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:boot "$DISK"  # Larger EFI partition
sgdisk -n 2:0:0 -t 2:8300 -c 2:root "$DISK"

# Determine partition naming
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    BOOT_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    BOOT_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# Format EFI system partition
info "Formatting EFI system partition..."
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
git clone "$GITHUB_REPO" ~/nixos-config || error "Failed to clone repository."

# Check hostname directory exists
[ -d ~/nixos-config/hosts/"$HOSTNAME" ] || error "No configuration found for hostname '$HOSTNAME'"

info "Found configuration for $HOSTNAME"

# Setup rbw and extract SOPS key
info "Setting up rbw for SOPS key extraction..."
export GPG_TTY=$(tty)

# Configure and use rbw with retry logic
RBW_SUCCESS=false
RBW_RETRIES=0
MAX_RBW_RETRIES=3

while [ "$RBW_SUCCESS" = false ] && [ $RBW_RETRIES -lt $MAX_RBW_RETRIES ]; do
    nix-shell -p rbw pinentry-curses gnupg --run '
        # Configure GPG to use curses pinentry
        mkdir -p ~/.gnupg
        echo "pinentry-program $(which pinentry-curses)" > ~/.gnupg/gpg-agent.conf
        pkill gpg-agent 2>/dev/null || true
        
        if [ ! -f ~/.config/rbw/config.json ]; then
            echo "=== Configuring rbw ==="
            echo "Enter your Bitwarden email:"
            read -r RBW_EMAIL
            rbw config set email "$RBW_EMAIL"
            
            echo "Are you using a self-hosted Bitwarden? (y/N)"
            read -r SELF_HOSTED
            if [[ "$SELF_HOSTED" =~ ^[Yy]$ ]]; then
                echo "Enter base URL:"
                read -r BASE_URL
                rbw config set base_url "$BASE_URL"
            fi
            
            rbw config set pinentry pinentry-curses
            rbw login || exit 1
        fi
        
        rbw unlock || exit 1
        
        mkdir -p /root/.config/sops/age
        rbw get "NixOS AGE Key" > /root/.config/sops/age/keys.txt || exit 1
        chmod 600 /root/.config/sops/age/keys.txt
        
        if [ ! -s /root/.config/sops/age/keys.txt ]; then
            echo "ERROR: SOPS key file is empty!"
            exit 1
        fi
        
        echo "SOPS key extracted successfully!"
    ' && RBW_SUCCESS=true || {
        RBW_RETRIES=$((RBW_RETRIES + 1))
        if [ $RBW_RETRIES -lt $MAX_RBW_RETRIES ]; then
            warn "Failed to unlock rbw. Attempt $RBW_RETRIES of $MAX_RBW_RETRIES. Please try again."
        else
            error "Failed to setup rbw after $MAX_RBW_RETRIES attempts."
        fi
    }
done

# Copy SOPS key to installed system
info "Copying SOPS key to installed system..."
mkdir -p /mnt/root/.config/sops/age
cp /root/.config/sops/age/keys.txt /mnt/root/.config/sops/age/keys.txt
chmod 600 /mnt/root/.config/sops/age/keys.txt

# Update hardware-configuration.nix
info "Updating hardware-configuration.nix..."
cp /mnt/etc/nixos/hardware-configuration.nix ~/nixos-config/hosts/"$HOSTNAME"/hardware-configuration.nix

# Find and update boot.nix
info "Finding and updating boot.nix..."
BOOT_NIX=$(find ~/nixos-config/hosts/"$HOSTNAME" -name "boot.nix" -type f | head -n 1)
[ -n "$BOOT_NIX" ] || error "boot.nix not found in ~/nixos-config/hosts/$HOSTNAME"

# Create simple boot configuration
cat > "$BOOT_NIX" << EOF
# /hosts/$HOSTNAME/boot.nix
let
  ${HOSTNAME}RootLuksName = "$LUKS_NAME";
  ${HOSTNAME}RootLuksDevicePath = "/dev/disk/by-uuid/$ROOT_UUID";
in {
  swapDevices = [
    {
      device = "/swapfile";
      size = $((SWAP_GB * 1024));  # Size in MB
    }
  ];

  custom.boot.luksPartitions = {
    root = {
      luksName = ${HOSTNAME}RootLuksName;
      devicePath = ${HOSTNAME}RootLuksDevicePath;
      allowDiscards = true;
    };
  };
}
EOF

info "boot.nix updated successfully!"

# Install NixOS
info "Installing NixOS with flake configuration..."
nixos-install --flake ~/nixos-config#"$HOSTNAME" --root /mnt --no-root-passwd || error "nixos-install failed!"

# Set passwords
info "Setting passwords..."
echo "root:$USER_PASSWORD" | nixos-enter --root /mnt -c 'chpasswd'

prompt "Enter your regular username (not root):"
read -r REGULAR_USER
echo "$REGULAR_USER:$USER_PASSWORD" | nixos-enter --root /mnt -c 'chpasswd' 2>/dev/null || warn "Could not set password for $REGULAR_USER"

# Copy configs to installed system
info "Copying configurations to installed system..."
mkdir -p /mnt/home/"$REGULAR_USER"
cp -r ~/nixos-config /mnt/home/"$REGULAR_USER"/nixos-config
cp -r ~/nixos-config /mnt/root/nixos-config

# Set ownership
nixos-enter --root /mnt -c "chown -R $REGULAR_USER:users /home/$REGULAR_USER/nixos-config" 2>/dev/null || true

# Copy SOPS key to user home
mkdir -p /mnt/home/"$REGULAR_USER"/.config/sops/age
cp /root/.config/sops/age/keys.txt /mnt/home/"$REGULAR_USER"/.config/sops/age/keys.txt
nixos-enter --root /mnt -c "chown -R $REGULAR_USER:users /home/$REGULAR_USER/.config" 2>/dev/null || true

# Create setup scripts
cat > /mnt/root/setup-tpm-unlock.sh << EOF
#!/usr/bin/env bash
# Set up TPM auto-unlock after first successful boot

set -euo pipefail

echo "Setting up TPM auto-unlock..."

# Load TPM modules
sudo modprobe tpm_crb 2>/dev/null || true
sudo modprobe tpm_tis 2>/dev/null || true

# Check TPM is available
if [ ! -e /dev/tpmrm0 ] && [ ! -e /dev/tpm0 ]; then
    echo "❌ No TPM device found"
    echo "Make sure TPM is enabled in BIOS"
    exit 1
fi

echo "✓ TPM device found"

# Get disk encryption password
echo "Enter your disk encryption password:"
read -sr DISK_PASSWORD

# Add TPM2 unlock to LUKS
echo "Adding TPM2 unlock capability..."
if echo -n "\$DISK_PASSWORD" | sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 $ROOT_PART; then
    echo "✓ TPM2 unlock enrolled successfully!"
    echo "✓ Your disk will auto-unlock on next boot"
    
    # Rebuild to update initrd
    echo "Updating system configuration..."
    sudo nixos-rebuild switch
    
    echo ""
    echo "🎉 Setup complete! Your disk will auto-unlock using TPM on next boot."
    echo "   If it fails, you can still enter your password manually."
else
    echo "❌ Failed to enroll TPM2 unlock"
    echo "This might be because:"
    echo "  - SecureBoot is disabled (PCR 7 changes)"
    echo "  - TPM is owned by another OS"
    echo ""
    echo "Try without PCR binding:"
    if echo -n "\$DISK_PASSWORD" | sudo systemd-cryptenroll --tpm2-device=auto $ROOT_PART; then
        echo "✓ TPM2 enrolled without PCR binding (less secure but should work)"
        sudo nixos-rebuild switch
    else
        echo "❌ TPM enrollment failed completely"
        exit 1
    fi
fi
EOF
chmod +x /mnt/root/setup-tpm-unlock.sh

cat > /mnt/root/setup-git-ssh.sh << 'EOF'
#!/usr/bin/env bash
cd ~/nixos-config
git remote set-url origin $(git remote get-url origin | sed 's|https://github.com/|git@github.com:|')
echo "Git remote updated to use SSH"

if [ -d /home/*/nixos-config ]; then
    for dir in /home/*/nixos-config; do
        cd "$dir"
        git remote set-url origin $(git remote get-url origin | sed 's|https://github.com/|git@github.com:|')
    done
fi
EOF
chmod +x /mnt/root/setup-git-ssh.sh

# Create install summary
cat > /mnt/root/install-summary.txt << EOF
NixOS Installation Summary
==========================
Date: $(date)
Hostname: $HOSTNAME
Boot: systemd-boot (EFI)
Disk: $DISK
Root: $ROOT_PART (UUID: $ROOT_UUID)
LUKS: $LUKS_NAME
Swap: ${SWAP_GB}GB

Next steps after first boot:
1. Run: sudo /root/setup-tpm-unlock.sh
2. Run: sudo /root/setup-git-ssh.sh
3. Test reboot to verify TPM auto-unlock

Files:
- SOPS key: /root/.config/sops/age/keys.txt
- Config: /root/nixos-config
EOF

info ""
info "🎉 Installation Complete!"
info ""
info "Summary:"
info "  - Hostname: $HOSTNAME"
info "  - Boot: systemd-boot"
info "  - Root: $ROOT_PART"
info "  - Swap: ${SWAP_GB}GB"
info ""
info "Next steps:"
info "  1. Reboot into your new system"
info "  2. Enter disk encryption password when prompted"
info "  3. Run: sudo /root/setup-tpm-unlock.sh"
info "  4. Run: sudo /root/setup-git-ssh.sh"
info ""
info "The TPM auto-unlock will be configured after first boot!"
info ""

prompt "Reboot now? (y/N)"
read -r REBOOT
if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    reboot
fi
