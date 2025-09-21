#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }
echo_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# ============================================
# CONFIGURATION PHASE
# ============================================

echo_step "Configuration Phase"

read -p "Enter your GitHub repo URL (https): " GITHUB_REPO
read -p "Enter hostname for this machine: " HOSTNAME
read -p "Enter your username: " USERNAME

# Password prompts
while true; do
    read -sp "Enter user/root password: " USER_PASSWORD
    echo
    read -sp "Confirm password: " USER_PASSWORD_CONFIRM
    echo
    [ "$USER_PASSWORD" = "$USER_PASSWORD_CONFIRM" ] && break
    echo_error "Passwords don't match! Try again."
done

while true; do
    read -sp "Enter disk encryption password: " ENCRYPTION_PASSWORD
    echo
    read -sp "Confirm encryption password: " ENCRYPTION_PASSWORD_CONFIRM
    echo
    [ "$ENCRYPTION_PASSWORD" = "$ENCRYPTION_PASSWORD_CONFIRM" ] && break
    echo_error "Encryption passwords don't match! Try again."
done

# ============================================
# DISK SELECTION
# ============================================

echo_step "Disk Selection"
echo_info "Available disks:"
lsblk -d -p -n -l -o NAME,SIZE,TYPE | grep -w disk

read -p "Enter full disk path (e.g., /dev/nvme0n1 or /dev/sda): " DISK

if [ ! -b "$DISK" ]; then
    echo_error "Disk $DISK not found!"
    exit 1
fi

echo_warn "⚠️  WARNING: This will ERASE ALL DATA on $DISK ⚠️"
read -p "Type 'YES' in capitals to continue: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo_error "Aborted."
    exit 1
fi

# ============================================
# DISK SETUP
# ============================================

echo_step "Setting up disk partitions"

# Unmount if already mounted
umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

# Partition the disk
parted "$DISK" -- mklabel gpt
parted "$DISK" -- mkpart ESP fat32 1MiB 1GiB
parted "$DISK" -- set 1 esp on
parted "$DISK" -- mkpart primary 1GiB 100%

# Determine partition paths
if [[ "$DISK" =~ "nvme" ]] || [[ "$DISK" =~ "mmcblk" ]]; then
    BOOT_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    BOOT_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# Setup LUKS encryption
echo_info "Setting up LUKS encryption on $ROOT_PART"
echo -n "$ENCRYPTION_PASSWORD" | cryptsetup luksFormat --type luks2 "$ROOT_PART" -
echo -n "$ENCRYPTION_PASSWORD" | cryptsetup open "$ROOT_PART" cryptroot -

# Format filesystems
echo_info "Formatting filesystems..."
mkfs.fat -F 32 -n BOOT "$BOOT_PART"
mkfs.ext4 -L nixos /dev/mapper/cryptroot

# Mount filesystems
echo_info "Mounting filesystems..."
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot

# Get UUID for boot.nix
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
echo_info "Root partition UUID: $ROOT_UUID"

# ============================================
# SWAPFILE FOR HIBERNATION
# ============================================

echo_step "Creating swapfile for hibernation"
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
SWAP_GB=$((RAM_GB + 2))
echo_info "Creating ${SWAP_GB}GB swapfile (${RAM_GB}GB RAM + 2GB)"

dd if=/dev/zero of=/mnt/swapfile bs=1G count="$SWAP_GB" status=progress
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

# ============================================
# GENERATE BASE CONFIG
# ============================================

echo_step "Generating base NixOS configuration"
nixos-generate-config --root /mnt

# ============================================
# CLONE AND SETUP REPOSITORY
# ============================================

echo_step "Cloning configuration repository"
git clone "$GITHUB_REPO" /mnt/root/nixos-config

# Check if hostname directory exists
if [ ! -d "/mnt/root/nixos-config/hosts/$HOSTNAME" ]; then
    echo_error "Host directory not found: /mnt/root/nixos-config/hosts/$HOSTNAME"
    echo_error "Available hosts:"
    ls -1 /mnt/root/nixos-config/hosts/
    exit 1
fi

# ============================================
# UPDATE CONFIGURATION FILES
# ============================================

echo_step "Updating configuration files"

# Copy hardware-configuration.nix
echo_info "Updating hardware-configuration.nix..."
cp /mnt/etc/nixos/hardware-configuration.nix \
   "/mnt/root/nixos-config/hosts/$HOSTNAME/hardware-configuration.nix"

# Update boot.nix
BOOT_NIX="/mnt/root/nixos-config/hosts/$HOSTNAME/boot.nix"

if [ ! -f "$BOOT_NIX" ]; then
    echo_error "boot.nix not found at $BOOT_NIX"
    exit 1
fi

echo_info "Updating boot.nix with UUID $ROOT_UUID..."

cat > "$BOOT_NIX" << EOF
# Auto-generated during installation - $(date)
let
  laptopRootLuksName = "luks-${ROOT_UUID}";
  laptopRootLuksDevicePath = "/dev/disk/by-uuid/${ROOT_UUID}";
in {
  swapDevices = [
    {
      device = "/swapfile";
      size = ${SWAP_GB}; # ${RAM_GB}GB RAM + 2GB for hibernation
    }
  ];

  custom.boot.luksPartitions = {
    root = {
      luksName = laptopRootLuksName;
      devicePath = laptopRootLuksDevicePath;
    };
  };
}
EOF

echo_info "boot.nix updated successfully"

# ============================================
# SECRETS MANAGEMENT
# ============================================

echo_step "Setting up secrets with rbw"
mkdir -p /root/.config/sops/age

nix-shell -p rbw --run bash << 'RBWSCRIPT'
    echo "Logging into Bitwarden via rbw..."
    rbw login
    
    echo "Unlocking vault..."
    rbw unlock
    
    echo "Extracting NixOS AGE Key..."
    rbw get "NixOS AGE Key" > /root/.config/sops/age/keys.txt
    chmod 600 /root/.config/sops/age/keys.txt
    
    echo "AGE key extracted successfully"
RBWSCRIPT

# Copy AGE key to mounted system
mkdir -p /mnt/root/.config/sops/age
cp /root/.config/sops/age/keys.txt /mnt/root/.config/sops/age/keys.txt
chmod 600 /mnt/root/.config/sops/age/keys.txt

# ============================================
# CLEVIS/TPM SETUP
# ============================================

echo_step "Setting up Clevis for auto-decryption"
echo_info "Enrolling TPM2 for automatic LUKS unlock..."

# Check if TPM2 is available
if [ -e /dev/tpmrm0 ]; then
    echo -n "$ENCRYPTION_PASSWORD" | \
        systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 "$ROOT_PART" -
    echo_info "TPM2 enrollment successful"
else
    echo_warn "No TPM2 device found, skipping auto-unlock enrollment"
    echo_warn "You'll need to enter encryption password on each boot"
fi

# ============================================
# NIXOS INSTALLATION
# ============================================

echo_step "Installing NixOS"

# Link config to expected location
rm -rf /mnt/etc/nixos
ln -sf /mnt/root/nixos-config /mnt/etc/nixos

# Install with flakes
echo_info "Running nixos-install with flake..."
nixos-install --flake "/mnt/root/nixos-config#$HOSTNAME" --no-root-passwd

# ============================================
# SET PASSWORDS
# ============================================

echo_step "Setting user passwords"

echo "root:$USER_PASSWORD" | nixos-enter --root /mnt -c chpasswd
echo "$USERNAME:$USER_PASSWORD" | nixos-enter --root /mnt -c chpasswd

echo_info "Passwords set for root and $USERNAME"

# ============================================
# COMPLETION
# ============================================

echo ""
echo_info "═══════════════════════════════════════════════"
echo_info "Installation complete! 🎉"
echo_info "═══════════════════════════════════════════════"
echo ""
echo_warn "Post-installation checklist:"
echo "  ✓ System is encrypted with LUKS"
echo "  ✓ Swapfile configured for hibernation"
echo "  ✓ SOPS age key installed"
if [ -e /dev/tpmrm0 ]; then
    echo "  ✓ TPM2 auto-unlock enrolled"
fi
echo ""
echo_warn "After first boot:"
echo "  1. Update git remote to use SSH:"
echo "     cd ~/nixos-config"
echo "     git remote set-url origin git@github.com:user/repo.git"
echo "  2. Test hibernation: systemctl hibernate"
echo "  3. Verify auto-unlock on reboot"
echo ""

read -p "Reboot now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo_info "Rebooting..."
    reboot
fi
