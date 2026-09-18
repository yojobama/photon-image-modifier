#!/bin/bash

# Exit on errors, print commands, ignore unset variables
set -ex +u

# silence log spam from dpkg
cat > /etc/apt/apt.conf.d/99dpkg.conf << EOF
Dpkg::Progress-Fancy "0";
APT::Color "0";
Dpkg::Use-Pty "0";
EOF

# run Photonvision install script
chmod +x ./install.sh
./install.sh --control-networking=yes --arch=aarch64 --version="$1"

echo "Installing additional things"
apt-get --yes -qq install libc6 libstdc++6

# this adds `strings` so that users can check the version of U-Boot with `sudo strings /dev/mtd0 | grep "^U-Boot"``
apt-get --yes -qq install binutils

# this isn't required, but is useful for monitoring temperature from the command line
apt-get --yes -qq install  lm-sensors

# modify photonvision.service to enable big cores
sed -i 's/# AllowedCPUs=4-7/AllowedCPUs=4-7/g' /lib/systemd/system/photonvision.service
cp -f /lib/systemd/system/photonvision.service /etc/systemd/system/photonvision.service
chmod 644 /etc/systemd/system/photonvision.service
cat /etc/systemd/system/photonvision.service

# try to 'fix' slow boot on Armbian images
# sed -i s/verbosity=1/verbosity=7/g /boot/armbianEnv.txt
sed -i 's/extraargs=/&initcall_debug ignore_loglevel cryptomgr.notests=1 nokprobes initcall_blacklist=init_kprobe_trace,crypto_kdf108_init,init_blk_tracer trace_buf_size=1 /' /boot/armbianEnv.txt

# Enable Vulkan-capable GPU acceleration on the Mali-G610 (RK3588/RK3588S).
#
# The vendor kernel's kbase interface doesn't expose the GPU to Mesa at all
# until the panthor-gpu device-tree overlay is active - without it, Vulkan
# enumerates nothing but the llvmpipe software rasterizer (see Armbian
# configng PR #886, "enable panthor-gpu DT overlay on rk3588 vendor-kernel
# desktops": https://github.com/armbian/configng/pull/886). Armbian only
# auto-enables that overlay when a desktop environment is installed via
# armbian-config, which this minimal/headless image build never does - so
# without this, every PhotonVision Orange Pi 5 image ships with a Mali GPU
# that Vulkan can never see, regardless of what's installed in userspace.
#
# mesa-vulkan-drivers on Debian trixie (25.0.7-2, arm64) already includes
# PanVK/Panfrost Vulkan support for Mali-G610 - no third-party PPA needed on
# this base, unlike Ubuntu.
apt-get --yes -qq install mesa-vulkan-drivers libvulkan1

# Idempotent append: add the token to an existing overlays= line if one is
# present (whether or not it already lists other overlays), otherwise add a
# fresh line. Skips entirely if panthor-gpu is already listed, so re-running
# this script against an already-patched image is a no-op.
if grep -q '\bpanthor-gpu\b' /boot/armbianEnv.txt; then
    echo "panthor-gpu overlay already present in /boot/armbianEnv.txt"
elif grep -q '^overlays=' /boot/armbianEnv.txt; then
    sed -i '/^overlays=/ s/$/ panthor-gpu/' /boot/armbianEnv.txt
else
    echo 'overlays=panthor-gpu' >> /boot/armbianEnv.txt
fi

# networkd isn't being used, this causes an unnecessary delay
# systemctl disable systemd-networkd-wait-online.service

# PhotonVision server is managing the network, so it doesn't need to wait for online
systemctl disable NetworkManager-wait-online.service

# disable wireless by blacklisting broadcom drivers
cat > /etc/modprobe.d/disable-wireless.conf << EOF
# Disable wireless drivers to prevent them from loading
blacklist brcmfmac
blacklist brcmutil
blacklist rtw88_core
blacklist rtw88_pci
blacklist rtw89_core
blacklist rtw89_pci
EOF

# mask the bluetooth and wpa services to preven them from being started
systemctl mask bluetooth.service
systemctl mask wpa_supplicant.service

# disable NetworkManager from managing wireless interfaces
mkdir -p /etc/NetworkManager/conf.d
echo -e "[keyfile]\nunmanaged-devices=interface-name:wlan*" > /etc/NetworkManager/conf.d/disable-wifi.conf


# set the hostname
echo "photonvision" > /etc/hostname
sed -i "s/127.0.1.1.*/127.0.1.1    photonvision/g" /etc/hosts

# Prevent the firstlogin script from running when root logs in for the first time.
# The script changes settings and overrides the photon user password.
# Remove the sentinel file
rm -f /root/.not_logged_in_yet

# Erase the firstlogin script
sudo rm -f /usr/lib/armbian/armbian-firstlogin

# Create a blank, dummy script in its place to prevent "file not found" profile errors
printf '#!/bin/bash\necho "First login script disabled"\nexit 0\n' > /usr/lib/armbian/armbian-firstlogin
sudo chmod +x /usr/lib/armbian/armbian-firstlogin

# disable the Armbian motd sripts
chmod -x /etc/update-motd.d/*

# Clean up apt cache and remove unnecessary files to reduce image size
rm -rf /var/lib/apt/lists/*
apt-get --yes -qq clean

# rm -rf /usr/share/doc
rm -rf /usr/share/locale/

rm -rf /usr/lib/firmware/qcom
