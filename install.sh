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

# Check boot mode (UEFI or BIOS)
info "Detecting boot mode..."
if [ -d /sys/firmware/efi/efivars ]; then
    BOOT_MODE="uefi"
    info "✓ System is booted in UEFI mode"
    
    # Ensure efivarfs is mounted
    if ! mount | grep -q efivarfs; then
        info "Mounting efivarfs..."
        mount -t efivarfs efivarfs /sys/firmware/efi/efivars || warn "Could not mount efivarfs"
    fi
else
    BOOT_MODE="bios"
    warn "⚠ System is booted in BIOS/Legacy mode"
    warn "  GRUB will be installed in BIOS mode"
fi

# Prompt for GitHub username (construct full URL)
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

# Partition disk based on boot mode
info "Partitioning disk for $BOOT_MODE mode..."
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"

if [ "$BOOT_MODE" = "uefi" ]; then
    # UEFI: EFI System Partition + root
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:boot "$DISK"
    sgdisk -n 2:0:0 -t 2:8300 -c 2:root "$DISK"
else
    # BIOS: BIOS boot partition + root
    sgdisk -n 1:0:+1M -t 1:ef02 -c 1:bios "$DISK"
    sgdisk -n 2:0:0 -t 2:8300 -c 2:root "$DISK"
fi

# Determine partition naming
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    PART1="${DISK}p1"
    PART2="${DISK}p2"
else
    PART1="${DISK}1"
    PART2="${DISK}2"
fi

if [ "$BOOT_MODE" = "uefi" ]; then
    BOOT_PART="$PART1"
    ROOT_PART="$PART2"
    
    # Format boot partition as FAT32 for UEFI
    info "Formatting EFI System Partition..."
    mkfs.fat -F 32 -n BOOT "$BOOT_PART"
else
    # BIOS mode - PART1 is BIOS boot partition (no filesystem)
    ROOT_PART="$PART2"
    info "BIOS boot partition created (no filesystem needed)"
fi

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

if [ "$BOOT_MODE" = "uefi" ]; then
    mkdir -p /mnt/boot
    mount "$BOOT_PART" /mnt/boot
fi

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
git clone "$GITHUB_REPO" ~/nixos-config || error "Failed to clone repository. Check your username and network connection."

# Check hostname directory exists
[ -d ~/nixos-config/hosts/"$HOSTNAME" ] || error "No configuration found for hostname '$HOSTNAME' in ~/nixos-config/hosts/"

info "Found configuration for $HOSTNAME"

# Setup rbw and extract SOPS key
info "Setting up rbw for SOPS key extraction..."

# Set up environment for rbw in the live USB
export GPG_TTY=$(tty)
export DISPLAY=:0

# Configure and use rbw with retry logic
RBW_SUCCESS=false
RBW_RETRIES=0
MAX_RBW_RETRIES=3

while [ "$RBW_SUCCESS" = false ] && [ $RBW_RETRIES -lt $MAX_RBW_RETRIES ]; do
    nix-shell -p rbw pinentry-curses gnupg --run '
        # Configure GPG to use curses pinentry
        mkdir -p ~/.gnupg
        echo "pinentry-program $(which pinentry-curses)" > ~/.gnupg/gpg-agent.conf
        
        # Kill any existing gpg-agent to force reload of config
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
            
            # Set pinentry to curses for rbw
            rbw config set pinentry pinentry-curses
            
            echo "=== Logging into rbw ==="
            rbw login || exit 1
        fi
        
        echo "=== Unlocking rbw ==="
        rbw unlock || exit 1
        
        echo "=== Extracting NixOS AGE Key ==="
        mkdir -p /root/.config/sops/age
        rbw get "NixOS AGE Key" > /root/.config/sops/age/keys.txt || exit 1
        chmod 600 /root/.config/sops/age/keys.txt
        
        # Verify the key was extracted
        if [ ! -s /root/.config/sops/age/keys.txt ]; then
            echo "ERROR: SOPS key file is empty!"
            exit 1
        fi
        
        echo "SOPS key extracted successfully!"
    ' && RBW_SUCCESS=true || {
        RBW_RETRIES=$((RBW_RETRIES + 1))
        if [ $RBW_RETRIES -lt $MAX_RBW_RETRIES ]; then
            warn "Failed to unlock rbw or extract key. Attempt $RBW_RETRIES of $MAX_RBW_RETRIES. Please try again."
        else
            error "Failed to setup rbw and extract SOPS key after $MAX_RBW_RETRIES attempts. Cannot continue."
        fi
    }
done

# Verify SOPS key exists and is valid
info "Verifying SOPS key..."
[ -s /root/.config/sops/age/keys.txt ] || error "SOPS key file is missing or empty!"
info "SOPS key verified at /root/.config/sops/age/keys.txt"

# Copy SOPS key to the mounted system BEFORE nixos-install
info "Copying SOPS key to installed system at /mnt/root/.config/sops/age/keys.txt..."
mkdir -p /mnt/root/.config/sops/age
cp /root/.config/sops/age/keys.txt /mnt/root/.config/sops/age/keys.txt
chmod 600 /mnt/root/.config/sops/age/keys.txt

# Verify it was copied
[ -s /mnt/root/.config/sops/age/keys.txt ] || error "Failed to copy SOPS key to installed system!"
info "SOPS key successfully copied to installed system"

# Update hardware-configuration.nix
info "Updating hardware-configuration.nix..."
cp /mnt/etc/nixos/hardware-configuration.nix ~/nixos-config/hosts/"$HOSTNAME"/hardware-configuration.nix

# Find and update boot.nix
info "Finding boot.nix..."
BOOT_NIX=$(find ~/nixos-config/hosts/"$HOSTNAME" -name "boot.nix" -type f | head -n 1)

[ -n "$BOOT_NIX" ] || error "boot.nix not found in ~/nixos-config/hosts/$HOSTNAME"

info "Updating boot.nix at $BOOT_NIX for $BOOT_MODE mode..."

# Create boot.nix based on boot mode
if [ "$BOOT_MODE" = "uefi" ]; then
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
else
    # BIOS mode - override the module's UEFI settings
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

  # Override boot loader settings for BIOS mode
  boot.loader = {
    systemd-boot.enable = false;
    grub = {
      enable = true;
      efiSupport = false;  # BIOS mode
      device = "$DISK";     # Install GRUB to disk
    };
    efi.canTouchEfiVariables = false;  # Not available in BIOS mode
  };

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
fi

info "boot.nix updated successfully for $BOOT_MODE mode!"

# Setup Clevis for TPM auto-decryption
prompt "Do you want to enable TPM auto-decryption with Clevis? (y/N)"
read -r ENABLE_CLEVIS

CLEVIS_BOUND=false

if [[ "$ENABLE_CLEVIS" =~ ^[Yy]$ ]]; then
    info "Checking TPM availability..."
    
    # Fix TPM permissions
    info "Setting up TPM device permissions..."
    if [ -e /dev/tpmrm0 ]; then
        chmod 666 /dev/tpmrm0 || warn "Could not change permissions on /dev/tpmrm0"
    fi
    if [ -e /dev/tpm0 ]; then
        chmod 666 /dev/tpm0 || warn "Could not change permissions on /dev/tpm0"
    fi
    
    # Load TPM kernel modules
    modprobe tpm_tis 2>/dev/null || true
    modprobe tpm_crb 2>/dev/null || true
    
    if [ ! -e /dev/tpmrm0 ] && [ ! -e /dev/tpm0 ]; then
        warn "No TPM device found after loading modules"
        ls -la /dev/tpm* 2>/dev/null || echo "No TPM devices found"
        warn "Skipping Clevis setup."
    else
        info "TPM device found. Attempting Clevis binding..."
        
        # Create temporary directory for clevis work
        CLEVIS_TMPDIR=$(mktemp -d)
        
        nix-shell -p clevis luksmeta cryptsetup tpm2-tools tpm2-tss --run "
            export HOME=$CLEVIS_TMPDIR
            
            # Test TPM access
            echo 'Testing TPM access...'
            if tpm2_getcap properties-fixed 2>&1 | grep -q 'TPM2_PT_FAMILY_INDICATOR'; then
                echo 'TPM is accessible!'
            else
                echo 'Warning: TPM may not be fully accessible'
            fi
            
            # Attempt binding
            echo 'Attempting Clevis bind without PCR...'
            if echo -n '$ENCRYPTION_PASSWORD' | clevis luks bind -d '$ROOT_PART' tpm2 '{}' -y 2>&1; then
                echo 'SUCCESS: Bound to TPM'
                exit 0
            fi
            
            echo 'Binding failed'
            exit 1
        " && {
            CLEVIS_BOUND=true
            info "✓ Clevis TPM binding successful!"
            
            # Extract the JWE token and save it
            info "Extracting Clevis JWE token..."
            mkdir -p /mnt/etc/clevis-secrets
            
            nix-shell -p clevis cryptsetup jose --run "
                for slot in {0..7}; do
                    if cryptsetup luksDump '$ROOT_PART' | grep -A 5 \"Key Slot \$slot\" | grep -q clevis; then
                        luksmeta load -d '$ROOT_PART' -s \$slot > /mnt/etc/clevis-secrets/secret.jwe 2>/dev/null || true
                        break
                    fi
                done
                
                if [ -f /mnt/etc/clevis-secrets/secret.jwe ] && [ -s /mnt/etc/clevis-secrets/secret.jwe ]; then
                    echo 'JWE token extracted successfully'
                    chmod 600 /mnt/etc/clevis-secrets/secret.jwe
                fi
            " || warn "Could not extract JWE token"
            
        } || {
            warn "Clevis binding failed in live environment."
        }
        
        rm -rf "$CLEVIS_TMPDIR"
    fi
fi

# Install NixOS
info "Installing NixOS with flake configuration..."
info "This may take a while..."

nixos-install --flake ~/nixos-config#"$HOSTNAME" --root /mnt --no-root-passwd 2>&1 || {
    error "nixos-install failed! Check the error messages above."
}

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

# Copy SOPS key to user's home
mkdir -p /mnt/home/"$REGULAR_USER"/.config/sops/age
cp /root/.config/sops/age/keys.txt /mnt/home/"$REGULAR_USER"/.config/sops/age/keys.txt
nixos-enter --root /mnt -c "chown -R $REGULAR_USER:users /home/$REGULAR_USER/.config" 2>/dev/null || true

# Create post-install scripts
cat > /mnt/root/setup-clevis.sh << CLEVISEOF
#!/usr/bin/env bash
# Run this after first boot to set up Clevis TPM auto-decryption

set -euo pipefail

echo "Setting up Clevis for TPM auto-decryption..."

# Ensure TPM modules are loaded
sudo modprobe tpm_tis 2>/dev/null || true
sudo modprobe tpm_crb 2>/dev/null || true

# Get encryption password
read -sp "Enter disk encryption password: " DISK_PASSWORD
echo

if echo -n "\$DISK_PASSWORD" | sudo clevis luks bind -d $ROOT_PART tpm2 '{}' -y; then
    echo "✓ Clevis bound to TPM"
    
    # Extract JWE token
    sudo mkdir -p /etc/clevis-secrets
    for slot in {0..7}; do
        if sudo cryptsetup luksDump $ROOT_PART | grep -A 5 "Key Slot \$slot" | grep -q clevis; then
            sudo luksmeta load -d $ROOT_PART -s \$slot > /tmp/secret.jwe 2>/dev/null || true
            if [ -s /tmp/secret.jwe ]; then
                sudo mv /tmp/secret.jwe /etc/clevis-secrets/secret.jwe
                sudo chmod 600 /etc/clevis-secrets/secret.jwe
                echo "✓ JWE token saved"
                break
            fi
        fi
    done
    
    echo "✓ Run 'sudo nixos-rebuild switch' to enable auto-unlock"
    exit 0
fi

echo "✗ Failed to bind Clevis"
exit 1
CLEVISEOF
chmod +x /mnt/root/setup-clevis.sh

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

# Create info file
cat > /mnt/root/install-info.txt << EOF
NixOS Installation
==================
Date: $(date)
Hostname: $HOSTNAME
Boot Mode: $BOOT_MODE
Disk: $DISK
Root: $ROOT_PART (UUID: $ROOT_UUID)
LUKS: $LUKS_NAME
Swap: ${SWAP_GB}GB
Clevis: ${CLEVIS_BOUND}

SOPS Key: /root/.config/sops/age/keys.txt
Config: /root/nixos-config

$(if [ "$BOOT_MODE" = "bios" ]; then
    echo "⚠ System installed in BIOS mode"
    echo "  To use UEFI, enable it in BIOS and reinstall"
fi)

$(if [ "$CLEVIS_BOUND" != true ]; then
    echo "To enable auto-unlock: sudo /root/setup-clevis.sh"
fi)
EOF

info ""
info "======================================"
info "  Installation Complete!"
info "======================================"
info ""
info "Summary:"
info "  - Hostname: $HOSTNAME"
info "  - Boot mode: $BOOT_MODE"
info "  - Root: $ROOT_PART"
if [ "$CLEVIS_BOUND" = true ]; then
    info "  - Clevis: ✓ Configured"
else
    info "  - Clevis: Run /root/setup-clevis.sh after boot"
fi
info ""
info "Next steps:"
info "  1. Reboot"
info "  2. Enter encryption password"
if [ "$CLEVIS_BOUND" != true ]; then
    info "  3. sudo /root/setup-clevis.sh"
fi
info "  4. sudo /root/setup-git-ssh.sh"
info ""

prompt "Reboot now? (y/N)"
read -r REBOOT
if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    reboot
fi
