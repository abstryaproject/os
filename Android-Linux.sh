#!/usr/bin/env bash

build-no-android-linux.sh

Full bash script to build a custom Debian-based Linux Desktop ISO

designed to block Android runtimes (Waydroid/Anbox/binder/ashmem)

and provide a clean XFCE desktop environment.

set -euo pipefail

--- CONFIGURATION ---

DISTRO="bullseye"          # Debian release ARCH="amd64"              # Target architecture DESKTOP="xfce4"           # Desktop environment ISO_NAME="no-android-linux" # Output ISO base name

--- DEPENDENCIES ---

check_deps() { echo "[+] Checking dependencies..." for pkg in live-build debootstrap git sudo; do if ! dpkg -s "$pkg" >/dev/null 2>&1; then echo "Installing missing dependency: $pkg" sudo apt-get update && sudo apt-get install -y "$pkg" fi done }

--- PREPARE BUILD ENVIRONMENT ---

setup_env() { echo "[+] Preparing build environment..." mkdir -p ~/no-android-build/config/includes.chroot/etc/modprobe.d mkdir -p ~/no-android-build/config/includes.chroot/etc/apt/preferences.d mkdir -p ~/no-android-build/config/includes.chroot/usr/local/sbin mkdir -p ~/no-android-build/config/includes.chroot/etc/xdg/autostart mkdir -p ~/no-android-build/config/hooks mkdir -p ~/no-android-build/config/package-lists cd ~/no-android-build }

--- CREATE CONFIG FILES ---

create_files() { echo "[+] Creating configuration files..."

cat > config/includes.chroot/etc/modprobe.d/no-android.conf <<'EOF'

Prevent Android binder and ashmem modules from being loaded

install binder /bin/false install ashmem_linux /bin/false blacklist binder blacklist ashmem_linux EOF

cat > config/includes.chroot/etc/apt/preferences.d/no-android <<'EOF' Package: waydroid* Pin: version * Pin-Priority: -1

Package: anbox* Pin: version * Pin-Priority: -1

Package: libbinder* Pin: version * Pin-Priority: -1

Package: android-tools-* Pin: version * Pin-Priority: -1 EOF

cat > config/includes.chroot/usr/local/sbin/no-android-setup.sh <<'EOF' #!/usr/bin/env bash

Run on first boot to mask services and remove Android packages.

set -euo pipefail

log() { echo "[no-android-setup] $*"; }

for svc in waydroid-container.service waydroid-container@.service anbox.service; do if systemctl list-unit-files --type=service | grep -q "^${svc}"; then log "Masking ${svc}" systemctl mask "$svc" || true fi done

if command -v apt-get >/dev/null 2>&1; then log "Removing Android packages" apt-get update || true apt-get purge -y --allow-change-held-packages waydroid anbox android-tools-adb android-tools-fastboot || true apt-get autoremove -y || true fi

cat >/etc/modprobe.d/no-android.conf <<'EOC' install binder /bin/false install ashmem_linux /bin/false blacklist binder blacklist ashmem_linux EOC

rm -f /etc/xdg/autostart/no-android-setup.desktop || true log "Setup complete." EOF chmod +x config/includes.chroot/usr/local/sbin/no-android-setup.sh

cat > config/includes.chroot/etc/xdg/autostart/no-android-setup.desktop <<'EOF' [Desktop Entry] Type=Application Name=No Android Setup Exec=/usr/local/sbin/no-android-setup.sh X-GNOME-Autostart-enabled=true NoDisplay=true EOF

cat > config/hooks/001_fix_perms.chroot <<'EOF' #!/usr/bin/env bash set -e chmod 0755 /usr/local/sbin/no-android-setup.sh || true chmod 0644 /etc/modprobe.d/no-android.conf || true chmod 0644 /etc/apt/preferences.d/no-android || true exit 0 EOF chmod +x config/hooks/001_fix_perms.chroot

cat > config/package-lists/desktop.list.chroot <<EOF $DESKTOP lightdm lightdm-gtk-greeter firefox-esr network-manager network-manager-gnome sudo locales ca-certificates vim less xterm EOF }

--- BUILD ISO ---

build_iso() { echo "[+] Building ISO image..." sudo lb clean sudo lb config 
--distribution "$DISTRO" 
--architectures "$ARCH" 
--debian-installer live 
--archive-areas "main contrib non-free" 
--bootappend-live "boot=live config quiet splash" 
--binary-images iso-hybrid 
--iso-volume "$ISO_NAME" 
--iso-application "$ISO_NAME" 
--iso-preparer "NoAndroidBuilder" 
--iso-publisher "Abstry Labs"

sudo lb build echo "[+] Build complete! Output ISO: $(ls -1 *.iso 2>/dev/null || echo 'binary.hybrid.iso')" }

--- MAIN EXECUTION ---

check_deps setup_env create_files build_iso

--- DONE ---

echo "=====================================" echo "ISO build completed successfully." echo "====================================="

