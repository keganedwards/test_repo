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

# Check if we're booted in EFI mode
info "Checking boot mode..."
if [ -d /sys/firmware/efi ]; then
    info "✓ System is booted in EFI mode"
    EFI_MODE=true
else
    warn "System is NOT booted in EFI mode (BIOS/Legacy)"
    info "This will use GRUB in BIOS mode instead of systemd-boot"
    EFI_MODE=false
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
info "Partitioning disk for $( [ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS" ) boot..."
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"

if [ "$EFI_MODE" = true ]; then
    # EFI partitioning
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:boot "$DISK"
    sgdisk -n 2:0:0 -t 2:8300 -c 2:root "$DISK"
else
    # BIOS partitioning
    sgdisk -n 1:0:+1M -t 1:ef02 -c 1:bios "$DISK"
    sgdisk -n 2:0:+512M -t 2:8300 -c 2:boot "$DISK"
    sgdisk -n 3:0:0 -t 3:8300 -c 3:root "$DISK"
fi

# Determine partition naming
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    if [ "$EFI_MODE" = true ]; then
        BOOT_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        BIOS_PART="${DISK}p1"
        BOOT_PART="${DISK}p2"
        ROOT_PART="${DISK}p3"
    fi
else
    if [ "$EFI_MODE" = true ]; then
        BOOT_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    else
        BIOS_PART="${DISK}1"
        BOOT_PART="${DISK}2"
        ROOT_PART="${DISK}3"
    fi
fi

# Format partitions
if [ "$EFI_MODE" = true ]; then
    info "Formatting EFI system partition..."
    mkfs.fat -F 32 -n BOOT "$BOOT_PART"
else
    info "Formatting boot partition..."
    mkfs.ext4 -L boot "$BOOT_PART"
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

info "Updating boot.nix at $BOOT_NIX for $( [ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS" ) boot..."

# Create boot configuration based on boot mode
if [ "$EFI_MODE" = true ]; then
    # EFI boot configuration
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

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = false;  # Safer for live USB installs
    };
    
    initrd = {
      systemd.enable = true;
      kernelModules = ["tpm_crb" "tpm_tis" "tpm_tis_core" "tpm"];
    };
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
else
    # BIOS boot configuration
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

  boot = {
    loader = {
      systemd-boot.enable = false;
      grub = {
        enable = true;
        device = "$DISK";  # Install GRUB to disk
        efiSupport = false;  # BIOS mode
      };
    };
    
    initrd = {
      systemd.enable = true;
      kernelModules = ["tpm_crb" "tpm_tis" "tpm_tis_core" "tpm"];
    };
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

info "boot.nix updated successfully!"

# Skip Clevis for now since it's causing issues
info "Skipping Clevis setup during installation (you can set it up after first boot)"
mkdir -p /mnt/etc
touch /mnt/etc/skip-clevis-on-first-boot

# Also update your boot module to handle the missing boot config
# We need to modify the boot.nix to not conflict with the custom module

# Update boot.nix to not have conflicting boot settings
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

# Install NixOS with special handling for EFI issues
info "Installing NixOS with flake configuration..."
info "This may take a while..."

# For EFI installations that might have variable issues, we'll install without touching EFI vars first
export NIXOS_INSTALL_BOOTLOADER=""

if nixos-install --flake ~/nixos-config#"$HOSTNAME" --root /mnt --no-root-passwd --no-bootloader 2>&1; then
    info "✓ System installed successfully (without bootloader)"
    
    # Now try to install the bootloader manually
    info "Installing bootloader manually..."
    
    if [ "$EFI_MODE" = true ]; then
        # Install systemd-boot manually
        nixos-enter --root /mnt -c "
            bootctl --path=/boot install || {
                echo 'bootctl failed, trying alternative method...'
                mkdir -p /boot/EFI/systemd
                mkdir -p /boot/loader/entries
                # Copy systemd-boot files manually if available
                find /nix/store -name 'systemd-boot*.efi' -exec cp {} /boot/EFI/systemd/systemd-bootx64.efi \\; 2>/dev/null || true
            }
            
            # Generate boot entries
            nixos-rebuild switch --install-bootloader || echo 'Warning: Could not update bootloader, but system should still boot'
        " || warn "Bootloader installation had issues, but system may still boot"
    else
        # Install GRUB manually
        nixos-enter --root /mnt -c "
            grub-install --target=i386-pc '$DISK' || echo 'GRUB install failed'
            grub-mkconfig -o /boot/grub/grub.cfg || echo 'GRUB config failed'
            nixos-rebuild switch || echo 'Warning: Could not run nixos-rebuild, but bootloader should work'
        " || warn "GRUB installation had issues"
    fi
else
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
cp /root/.config/sops/age/keys.txt /mnt/home/"$REGULAR_USER"/.config/sops/age/keys.txt
nixos-enter --root /mnt -c "chown -R $REGULAR_USER:users /home/$REGULAR_USER/.config" 2>/dev/null || true

# Create post-install setup scripts
cat > /mnt/root/setup-clevis.sh << EOF
#!/usr/bin/env bash
# Run this after first boot to set up Clevis TPM auto-decryption

set -euo pipefail

echo "Setting up Clevis for TPM auto-decryption..."

# Load TPM modules
sudo modprobe tpm_tis || true
sudo modprobe tpm_crb || true

prompt "Enter your disk encryption password:"
read -sr DISK_PASSWORD

# Try with PCR 7 (Secure Boot)
if echo -n "\$DISK_PASSWORD" | sudo clevis luks bind -d $ROOT_PART tpm2 '{"pcr_ids":"7"}' -y; then
    echo "✓ Success! Clevis bound to TPM with PCR 7"
    echo "✓ Auto-decryption should work on next boot"
    
    # Update bootloader to include clevis in initrd
    sudo nixos-rebuild switch
    exit 0
fi

# Fallback: try without PCR
echo "PCR 7 failed, trying without PCR binding..."
if echo -n "\$DISK_PASSWORD" | sudo clevis luks bind -d $ROOT_PART tpm2 '{}' -y; then
    echo "✓ Success! Clevis bound to TPM (no PCR)"
    sudo nixos-rebuild switch
    exit 0
fi

echo "✗ Failed to bind Clevis"
exit 1
EOF
chmod +x /mnt/root/setup-clevis.sh

cat > /mnt/root/fix-bootloader.sh << EOF
#!/usr/bin/env bash
# Run this if you have boot issues

echo "Fixing bootloader configuration..."

if [ -d /sys/firmware/efi ]; then
    echo "EFI mode detected"
    sudo bootctl --path=/boot install
    sudo nixos-rebuild switch --install-bootloader
else
    echo "BIOS mode detected"
    sudo grub-install --target=i386-pc $DISK
    sudo nixos-rebuild switch
fi

echo "Bootloader should be fixed!"
EOF
chmod +x /mnt/root/fix-bootloader.sh

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
info "  - Boot mode: $( [ "$EFI_MODE" = true ] && echo "EFI (systemd-boot)" || echo "BIOS (GRUB)" )"
info "  - Root: $ROOT_PART (UUID: $ROOT_UUID)"
info "  - Swap: ${SWAP_GB}GB"
info "  - Clevis: Will be set up after first boot"
info ""
info "Post-install scripts:"
info "  - /root/setup-clevis.sh - Enable TPM auto-decryption"
info "  - /root/fix-bootloader.sh - Fix boot issues if needed"
info "  - /root/setup-git-ssh.sh - Switch to SSH for git"
info ""
info "Next steps:"
info "  1. Reboot and test the system boots"
info "  2. Enter encryption password when prompted"
info "  3. Run the setup scripts as needed"
info ""

prompt "Reboot now? (y/N)"
read -r REBOOT
if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    reboot
fi
