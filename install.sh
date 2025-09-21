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

# Setup Clevis for TPM auto-decryption
prompt "Do you want to enable TPM auto-decryption with Clevis? (y/N)"
read -r ENABLE_CLEVIS

CLEVIS_BOUND=false

if [[ "$ENABLE_CLEVIS" =~ ^[Yy]$ ]]; then
    info "Checking TPM availability..."
    
    # Check if TPM devices exist and are accessible
    TPM_AVAILABLE=false
    if [ -e /dev/tpm0 ]; then
        if [ -r /dev/tpm0 ] && [ -w /dev/tpm0 ]; then
            TPM_AVAILABLE=true
            info "Found accessible TPM at /dev/tpm0"
        else
            warn "TPM at /dev/tpm0 exists but is not readable/writable"
        fi
    elif [ -e /dev/tpmrm0 ]; then
        if [ -r /dev/tpmrm0 ] && [ -w /dev/tpmrm0 ]; then
            TPM_AVAILABLE=true
            info "Found accessible TPM at /dev/tpmrm0"
        else
            warn "TPM at /dev/tpmrm0 exists but is not readable/writable"
            # Try to fix permissions
            info "Attempting to fix TPM permissions..."
            chmod 666 /dev/tpmrm0 2>/dev/null || warn "Could not fix TPM permissions"
            if [ -r /dev/tpmrm0 ] && [ -w /dev/tpmrm0 ]; then
                TPM_AVAILABLE=true
                info "TPM permissions fixed"
            fi
        fi
    else
        warn "No TPM devices found"
        ls -la /dev/tpm* 2>/dev/null || echo "No TPM devices available"
    fi

    if [ "$TPM_AVAILABLE" = false ]; then
        warn "TPM is not available or accessible. Skipping Clevis setup."
        warn "This could be because:"
        warn "  - TPM is disabled in BIOS"
        warn "  - TPM resource manager is not running"
        warn "  - Permission issues in live environment"
    else
        info "TPM is available. Setting up Clevis..."
        
        # Create dummy secret first (your config expects this file to exist)
        mkdir -p /mnt/etc/clevis-secrets
        
        # Create a dummy secret that we'll encrypt with TPM
        DUMMY_SECRET="nixos-boot-secret-$(date +%s)"
        
        # Try to encrypt the dummy secret and bind LUKS
        nix-shell -p clevis luksmeta cryptsetup tpm2-tools tpm2-tss --run "
            set -e
            
            echo '=== Testing TPM access ==='
            tpm2_pcrread sha256:7 || echo 'Warning: Could not read PCR 7'
            
            echo '=== Creating encrypted secret for boot ==='
            # Create the JWE file that your config expects
            echo -n '$DUMMY_SECRET' | clevis encrypt tpm2 '{}' > /mnt/etc/clevis-secrets/secret.jwe
            
            if [ ! -s /mnt/etc/clevis-secrets/secret.jwe ]; then
                echo 'ERROR: Failed to create JWE secret file'
                exit 1
            fi
            
            echo 'JWE secret file created successfully'
            
            echo '=== Binding LUKS partition to TPM ==='
            # Now bind the LUKS partition
            echo -n '$ENCRYPTION_PASSWORD' | clevis luks bind -d '$ROOT_PART' tpm2 '{}' -y
            
            echo 'LUKS binding successful'
            
        " && {
            CLEVIS_BOUND=true
            info "Clevis setup complete!"
            info "Created JWE secret at /etc/clevis-secrets/secret.jwe"
            info "Bound LUKS partition to TPM"
        } || {
            warn "Clevis setup failed. Creating fallback configuration..."
            
            # Create a placeholder JWE file so the build doesn't fail
            mkdir -p /mnt/etc/clevis-secrets
            echo '{"placeholder":"true"}' > /mnt/etc/clevis-secrets/secret.jwe
            
            warn "Created placeholder JWE file to allow build to complete"
            warn "You'll need to set up Clevis manually after first boot"
        }
    fi
else
    info "Skipping Clevis setup."
    
    # Still need to create the directory structure so the build doesn't fail
    mkdir -p /mnt/etc/clevis-secrets
    echo '{"disabled":"true"}' > /mnt/etc/clevis-secrets/secret.jwe
    info "Created placeholder JWE file (Clevis disabled)"
fi

# Install NixOS
info "Installing NixOS with fl ake configuration..."
info "This may take a while..."

nixos-install --flake ~/nixos-config#"$HOSTNAME" --root /mnt --no-root-passwd 2>&1 || {
    error "nixos-install failed! Check the error messages above.
    
Check if these files exist:
  - /mnt/root/.config/sops/age/keys.txt ($([ -f /mnt/root/.config/sops/age/keys.txt ] && echo "✓ exists" || echo "✗ missing"))
  - /mnt/etc/clevis-secrets/secret.jwe ($([ -f /mnt/etc/clevis-secrets/secret.jwe ] && echo "✓ exists" || echo "✗ missing"))
    
Common issues:
  - SOPS decryption failed (check age key)
  - Flake evaluation error (syntax error in configs)  
  - Missing clevis secrets"
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

# Copy SOPS key to user's home if they need it
mkdir -p /mnt/home/"$REGULAR_USER"/.config/sops/age
cp /root/.config/sops/age/keys.txt /mnt/home/"$REGULAR_USER"/.config/sops/age/keys.txt
nixos-enter --root /mnt -c "chown -R $REGULAR_USER:users /home/$REGULAR_USER/.config" 2>/dev/null || true

# Create post-install clevis setup script if needed
if [ "$CLEVIS_BOUND" != true ]; then
    cat > /mnt/root/setup-clevis.sh << EOF
#!/usr/bin/env bash
# Run this after first boot to set up Clevis TPM auto-decryption properly

echo "Setting up Clevis for TPM auto-decryption..."

# Create proper secret
BOOT_SECRET="nixos-boot-secret-\$(date +%s)"

# Encrypt the secret with TPM
echo -n "\$BOOT_SECRET" | clevis encrypt tpm2 '{}' > /etc/clevis-secrets/secret.jwe && {
    echo "Created new JWE secret file"
} || {
    echo "Failed to create JWE secret"
    exit 1
}

# Bind LUKS partition to TPM
echo "Please enter your disk encryption password:"
clevis luks bind -d $ROOT_PART tpm2 '{}' && {
    echo "Success! LUKS partition bound to TPM"
    echo "Auto-decryption should work on next boot"
    
    # Test decryption
    echo "Testing auto-decryption..."
    clevis luks unlock -d $ROOT_PART && {
        echo "Auto-decryption test successful!"
    } || {
        echo "Auto-decryption test failed"
    }
} || {
    echo "Failed to bind LUKS partition"
    exit 1
}
EOF
    chmod +x /mnt/root/setup-clevis.sh
fi

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

# Create debug info file
cat > /mnt/root/install-info.txt << EOF
NixOS Installation Information
==============================
Date: $(date)
Hostname: $HOSTNAME
Disk: $DISK
Root Partition: $ROOT_PART
Root UUID: $ROOT_UUID
LUKS Name: $LUKS_NAME
Swap Size: ${SWAP_GB}GB
Clevis Bound: ${CLEVIS_BOUND}

Files created:
- SOPS Key: /root/.config/sops/age/keys.txt
- Clevis Secret: /etc/clevis-secrets/secret.jwe
- Config: /root/nixos-config

$(if [ "$CLEVIS_BOUND" != true ]; then
    echo "Clevis was NOT properly set up during install."
    echo "A placeholder JWE file was created to allow the build to complete."
    echo "To enable auto-decryption, run: sudo /root/setup-clevis.sh"
else
    echo "Clevis auto-decryption should be working."
fi)

Manual unlock command: cryptsetup open /dev/disk/by-uuid/$ROOT_UUID cryptroot
EOF

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
if [ "$CLEVIS_BOUND" = true ]; then
    info "  - TPM auto-decryption: ENABLED ✓"
else
    info "  - TPM auto-decryption: PLACEHOLDER CREATED"
    info "    Run 'sudo /root/setup-clevis.sh' after first boot"
fi
info "  - SOPS key: /root/.config/sops/age/keys.txt"
info "  - Clevis secret: /etc/clevis-secrets/secret.jwe"
info ""
info "Installation details saved to /root/install-info.txt"
info ""

prompt "Press Enter to reboot or Ctrl+C to stay in live environment..."
read -r
reboot
