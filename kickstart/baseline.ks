# =============================================================================
# baseline.ks - AlmaLinux 9 reference system kickstart
# =============================================================================
# Hosted kickstart for building the reference system that will later be
# snapshotted and turned into a live ISO. Pulls from official AlmaLinux US
# mirrors. Pass to the AlmaLinux 9 installer with:
#     inst.ks=https://your-server/kickstart/baseline.ks
# =============================================================================

# AlmaLinux 9 minor release pin. Bump these URLs together when moving
# between minor releases. live.ks.template and the Dockerfile FROM line
# must be bumped in lockstep — see README "Bumping the minor release".
url --url=https://repo.almalinux.org/almalinux/9.8/BaseOS/x86_64/os/
repo --name=BaseOS    --baseurl=https://repo.almalinux.org/almalinux/9.8/BaseOS/x86_64/os/
repo --name=AppStream --baseurl=https://repo.almalinux.org/almalinux/9.8/AppStream/x86_64/os/
repo --name=extras    --baseurl=https://repo.almalinux.org/almalinux/9.8/extras/x86_64/os/
repo --name=epel      --baseurl=https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/

# Localization
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts='us'
timezone UTC --utc

# Network - DHCP via NetworkManager
network --bootproto=dhcp --device=link --activate --onboot=on
firewall --enabled --service=ssh

# Security
selinux --enforcing
authselect select sssd with-mkhomedir --force
services --enabled=NetworkManager,firewalld,sshd --disabled=cups,avahi-daemon,bluetooth

# Bootloader and storage - LVM with sensible defaults
bootloader --location=mbr --boot-drive=sda --append="rhgb quiet"
zerombr
clearpart --all --initlabel
autopart --type=lvm

# Users - default password "changeme" (must be changed on first login)
rootpw --plaintext changeme
user --name=localadmin --uid=1000 --groups=wheel --shell=/bin/bash --plaintext --password=changeme

# Default target
xconfig --startxonboot

# Reboot when finished
reboot --eject

%packages
@^minimal-environment
@core
-coreutils-single
coreutils
@base-x
@fonts
@gnome-desktop
@hardware-support
@standard
NetworkManager
firewalld
openssh-server
sudo
bash-completion
vim-enhanced
curl
wget
tar
unzip
zip
git
plymouth
plymouth-plugin-script
plymouth-plugin-label
plymouth-plugin-two-step
plymouth-theme-spinner
dracut-live
glibc-langpack-en
-iwl*-firmware
%end

%post --log=/root/baseline-install.log
set -euxo pipefail

echo "[baseline.ks] post-install starting at $(date -u +%FT%TZ)"

# Set graphical target so the desktop comes up on boot
systemctl set-default graphical.target

# Force a password change for root and localadmin on first login
chage -d 0 root
chage -d 0 localadmin

# Ensure wheel can sudo (uncomment %wheel ALL=(ALL) ALL)
sed -i 's/^# *\(%wheel[[:space:]]*ALL=(ALL)[[:space:]]*ALL\)/\1/' /etc/sudoers

# Make sure firewalld is enabled and NetworkManager owns networking
systemctl enable firewalld NetworkManager sshd

# Disable services not needed on a desktop reference image
for svc in cups avahi-daemon bluetooth; do
    systemctl disable "$svc".service 2>/dev/null || true
    systemctl mask    "$svc".service 2>/dev/null || true
done

# Drop a marker so snapshot.sh can verify it ran against a baseline build
mkdir -p /etc/almalinux-live
cat > /etc/almalinux-live/baseline.info <<EOF
baseline_built_at=$(date -u +%FT%TZ)
baseline_kickstart=baseline.ks
EOF

echo "[baseline.ks] post-install complete at $(date -u +%FT%TZ)"
%end
