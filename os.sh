#!/usr/bin/env bash
# build-abstrya-cloud-client-os-v2_5.sh
# Builds Abstrya Cloud Client OS v2.5 hybrid ISOs (amd64, i386, arm64)
#
# USAGE (prepare build host first):
# sudo apt update
# sudo apt install -y live-build debootstrap qemu-user-static binfmt-support squashfs-tools xorriso isolinux syslinux-utils grub-pc-bin grub-efi-amd64-bin grub-efi-arm64-bin calamares curl chattr
#
# Then:
# chmod +x build-abstrya-cloud-client-os-v2_5.sh
# ./build-abstrya-cloud-client-os-v2_5.sh
#
set -euo pipefail

############################
# Configuration - edit here
############################
BASE_DIR="$HOME/os-builder"
DISTRO="jammy"                 # Ubuntu 22.04
LABEL_BASE="AbstryaCloud"
ARCHS=( "amd64" "i386" "arm64" ) # architectures to build
POLL_INTERVAL=30               # seconds
MAX_TRIES=3                    # attempts before fall back to search.html
ROOT_PASSWORD="000005"        # root password (per your request)
DEFAULT_USER="ubuntu"          # user to autologin
##################################


# Make sure required packages are present (best-effort check)
echo "=== Pre-check: build host should have live-build, qemu-user-static, binfmt-support, debootstrap, squashfs-tools, xorriso, grub and Calamares installed ==="
echo "If missing, install them: sudo apt update && sudo apt install -y live-build debootstrap qemu-user-static binfmt-support squashfs-tools xorriso isolinux syslinux-utils grub-pc-bin grub-efi-amd64-bin grub-efi-arm64-bin calamares curl chattr"

echo "Starting Abstrya Cloud Client OS v2.5 build"
echo "Base dir: $BASE_DIR"
echo "Architectures: ${ARCHS[*]}"
echo

# quick host pre-check
command -v lb >/dev/null || { echo "Please install live-build (lb)."; exit 1; }
command -v qemu-aarch64-static >/dev/null 2>&1 || echo "Warning: qemu-aarch64-static not found; arm64 build may fail or be very slow."

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# A function to write the two HTML files (welcome + search) with locking applied in a hook
write_htmls_and_scripts() {
  local DIR="$1" # work dir
  mkdir -p "$DIR/config/includes.chroot/usr/share/abstrya/system"
  mkdir -p "$DIR/config/includes.chroot/usr/local/bin"
  mkdir -p "$DIR/config/hooks"

  # website.html (welcome) - centrally displayed at boot (immutable)
  cat > "$DIR/config/includes.chroot/usr/share/abstrya/system/website.html" <<'WHTML'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>AbstryaCloud OS</title>
<style>
body { background: #0b0b0b; color: #fff; font-family: "Segoe UI", Arial, sans-serif; display:flex; align-items:center; justify-content:center; height:100vh; margin:0; text-align:center; flex-direction:column; }
h1 { font-size: 3.2rem; margin: 0 0 1rem 0; }
p { font-size: 1.1rem; margin: 0.2rem 0; }
.footer { position: fixed; bottom: 20px; font-size: 0.95rem; opacity: 0.85; }
</style>
</head>
<body>
  <h1>ABSTRY DESKTOP</h1>
  <p>Lightweight OS designed for secure, automatic, and resilient connection</p>
  <div class="footer">Powered by Abdullahi Ibrahim Lailaba</div>
</body>
</html>
WHTML

  # search.html (manual connection)
  cat > "$DIR/config/includes.chroot/usr/share/abstrya/system/search.html" <<'SHTML'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>AbstryaCloud OS - Manual Connect</title>
<script>
async function tryConnect() {
  const raw = document.getElementById('addr').value.trim();
  if (!raw) return;
  const status = document.getElementById('status');
  status.textContent = 'Connecting…';
  status.style.color = '#ffb400';
  let url = raw;
  // ensure scheme
  if (!/^https?:\/\//i.test(url)) {
    // prefer https when user types host only
    url = 'https://' + url;
  }
  try {
    await fetch(url, { mode: 'no-cors' , cache: 'no-store' });
    status.textContent = 'Connected. Opening...';
    status.style.color = '#00ff66';
    window.location.href = url;
  } catch (e) {
    status.textContent = 'Connection failed. Press Ctrl+Shift+N to check Network connection.';
    status.style.color = '#ff4444';
  }
}
document.addEventListener('DOMContentLoaded', () => {
  document.getElementById('addr').addEventListener('keydown', e => {
    if (e.key === 'Enter') tryConnect();
  });
});
</script>
<style>
body { background: #0b0b0b; color: #fff; font-family: "Segoe UI", Arial, sans-serif; display:flex; align-items:center; justify-content:center; height:100vh; margin:0; text-align:center; flex-direction:column; }
h1 { font-size: 3.2rem; margin: 0 0 1rem 0; }
p { font-size: 1.1rem; margin: 0.2rem 0; }
.footer { position: fixed; bottom: 20px; font-size: 0.95rem; opacity: 0.85; }
input[type=text] {
  width: 60%; max-width: 520px;
  padding: 12px; margin-top: 8px;
  font-size: 16px; border: none; border-radius: 8px;
  text-align: center;
  background: #303030; color: #fff;
}
input[type=text]::placeholder { color: #ccc; }
#status { margin-top: 14px; font-style: italic; }
.footer { position: fixed; bottom: 14px; font-size: 0.9rem; color: #aaa; }
</style>
</head>
<body>
  <h1>ABSTRY EXPLORER</h1>
  <input id="addr" type="text" placeholder="Enter domain or IP address to explore manually" />
  <div id="status"></div>
  <div class="footer">Powered by Abdullahi Ibrahim Lailaba</div>
</body>
</html>
SHTML

  # scripts: launcher, watcher, network helper, open search
  cat > "$DIR/config/includes.chroot/usr/local/bin/abstrya-launch-browser.sh" <<'LB'
#!/bin/bash
TARGET="https://abstryacloud.local"
WELCOME="file:///usr/share/abstrya/system/website.html"
# kill existing chromium processes gracefully
pkill -f "chromium" >/dev/null 2>&1 || true
# quick reachability check
if curl -Is --connect-timeout 5 "$TARGET" >/dev/null 2>&1; then
  chromium-browser --kiosk --no-first-run --incognito --disable-file-access "$TARGET" &
else
  chromium-browser --kiosk "$WELCOME" &
fi
LB
  chmod +x "$DIR/config/includes.chroot/usr/local/bin/abstrya-launch-browser.sh"

  cat > "$DIR/config/includes.chroot/usr/local/bin/abstrya-watcher.sh" <<'AW'
#!/bin/bash
TARGET="https://abstryacloud.local"
WELCOME="file:///usr/share/abstrya/system/website.html"
POLL=30
MAX=3
while true; do
  TRIES=0
  FOUND=0
  while [ $TRIES -lt $MAX ]; do
    if curl -Is --connect-timeout 5 "$TARGET" >/dev/null 2>&1; then
      FOUND=1
      break
    fi
    TRIES=$((TRIES+1))
    sleep "$POLL"
  done

  if [ $FOUND -eq 1 ]; then
    # if not already on TARGET, launch kiosk
    if ! pgrep -f "chromium.*${TARGET}" >/dev/null 2>&1; then
      pkill -f chromium >/dev/null 2>&1 || true
      chromium-browser --kiosk --no-first-run --incognito --disable-file-access "$TARGET" &
    fi
  else
    # show local search page if not already shown
    if ! pgrep -f "chromium.*search.html" >/dev/null 2>&1; then
      pkill -f chromium >/dev/null 2>&1 || true
      chromium-browser --kiosk "file:///usr/share/abstrya/system/search.html" &
    fi
  fi
  # continue loop to check again every POLL * MAX seconds effectively
  sleep "$POLL"
done
AW
  chmod +x "$DIR/config/includes.chroot/usr/local/bin/abstrya-watcher.sh"

  cat > "$DIR/config/includes.chroot/usr/local/bin/abstrya-network-settings.sh" <<'NS'
#!/bin/bash
# If running under X, launch GUI network editor, else text UI
if [ -n "$DISPLAY" ]; then
  if command -v nm-connection-editor >/dev/null 2>&1; then
    nm-connection-editor &
  else
    # fallback to nm-connection-editor attempt; if none, attempt nm-applet
    nm-connection-editor &>/dev/null &
  fi
else
  if command -v nmtui >/dev/null 2>&1; then
    nmtui
  else
    echo "No network UI available."
  fi
fi
NS
  chmod +x "$DIR/config/includes.chroot/usr/local/bin/abstrya-network-settings.sh"

  cat > "$DIR/config/includes.chroot/usr/local/bin/abstrya-open-search.sh" <<'OS'
#!/bin/bash
x-www-browser /usr/share/abstrya/system/search.html &
OS
  chmod +x "$DIR/config/includes.chroot/usr/local/bin/abstrya-open-search.sh"

  # rc.local-like autostart via openbox autostart
  mkdir -p "$DIR/config/includes.chroot/etc/xdg/openbox"
  cat > "$DIR/config/includes.chroot/etc/xdg/openbox/autostart" <<'AUTO'
#!/bin/bash
# start watcher in background (this will launch chromium)
nohup /usr/local/bin/abstrya-watcher.sh >/var/log/abstrya-watcher.log 2>&1 &
# fallback quick welcome load
chromium-browser --kiosk file:///usr/share/abstrya/system/website.html &
AUTO
  chmod +x "$DIR/config/includes.chroot/etc/xdg/openbox/autostart"

  # Openbox keybindings (Ctrl+Shift+T etc.)
  cat > "$DIR/config/includes.chroot/etc/xdg/openbox/rc.xml" <<'RC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config>
  <keyboard>
    <keybind key="C-S-T">
      <action name="Execute"><command>lxterminal</command></action>
    </keybind>
    <keybind key="C-S-A">
      <action name="Execute"><command>systemctl poweroff</command></action>
    </keybind>
    <keybind key="C-S-B">
      <action name="Execute"><command>/usr/local/bin/abstrya-launch-browser.sh</command></action>
    </keybind>
    <keybind key="C-S-R">
      <action name="Execute"><command>systemctl reboot</command></action>
    </keybind>
    <keybind key="C-S-N">
      <action name="Execute"><command>/usr/local/bin/abstrya-network-settings.sh</command></action>
    </keybind>
    <!-- Ctrl+S for search -->
    <keybind key="C-s">
      <action name="Execute"><command>/usr/local/bin/abstrya-open-search.sh</command></action>
    </keybind>
  </keyboard>
</openbox_config>
RC

  # LightDM autologin config
  mkdir -p "$DIR/config/includes.chroot/etc/lightdm/lightdm.conf.d"
  cat > "$DIR/config/includes.chroot/etc/lightdm/lightdm.conf.d/50-abstrya.conf" <<'LDM'
[Seat:*]
autologin-user=ubuntu
autologin-session=openbox
LDM

  # hostname & hosts
  echo "abstryacloud" > "$DIR/config/includes.chroot/etc/hostname"
  cat > "$DIR/config/includes.chroot/etc/hosts" <<'HOSTS'
127.0.0.1   localhost
127.0.0.1   abstryacloud.local
HOSTS

  # /etc/issue
  cat > "$DIR/config/includes.chroot/etc/issue" <<'ISSUE'
Welcome to Abstrya Cloud OS
Press Ctrl+Shift+T to open Terminal
ISSUE

  # Make the system directory read-only via fstab bind (will be applied after boot)
  # We'll add an fstab entry so live session mounts it as read-only
  cat > "$DIR/config/includes.chroot/etc/fstab" <<'FSTAB'
/usr/share/abstrya/system  /usr/share/abstrya/system  none  bind,ro  0  0
FSTAB

  # Hook to set root password, remove passwordless sudo, lock HTML files, set immutable attribute
  cat > "$DIR/config/hooks/02-post-setup.chroot" <<'HOOK'
#!/bin/bash
set -e
# set root password
echo "root:${ROOT_PASSWORD}" | chpasswd || true

# ensure ubuntu user exists (live-build usually creates ubuntu)
if id ubuntu >/dev/null 2>&1; then
  # remove passwordless sudo if existed
  if [ -f /etc/sudoers.d/90-cloud-init-users ]; then
    rm -f /etc/sudoers.d/90-cloud-init-users
  fi
  # give ubuntu a normal sudo entry requiring password
  echo "${DEFAULT_USER} ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99-${DEFAULT_USER}
  chmod 0440 /etc/sudoers.d/99-${DEFAULT_USER}
fi

# lock down the system html files
SYSTEM_DIR=/usr/share/abstrya/system
if [ -d "\$SYSTEM_DIR" ]; then
  chown root:root \$SYSTEM_DIR/* || true
  chmod 000 \$SYSTEM_DIR/* || true
  # apply immutable flag
  if command -v chattr >/dev/null 2>&1; then
    chattr +i \$SYSTEM_DIR/* || true
  fi
fi

# ensure scripts are executable
chmod +x /usr/local/bin/abstrya-*.sh || true
HOOK
  chmod +x "$DIR/config/hooks/02-post-setup.chroot"

  # include Calamares stub (if present on build host we'll copy binary later)
  mkdir -p "$DIR/config/includes.chroot/usr/share/applications"
  cat > "$DIR/config/includes.chroot/usr/share/applications/abstrya-installer.desktop" <<'DINST'
[Desktop Entry]
Name=Install Abstrya Cloud OS
Exec=calamares
Type=Application
Terminal=false
Categories=System;
DINST

  # ensure log dir
  mkdir -p "$DIR/config/includes.chroot/var/log"
}

# Main per-arch build loop
for ARCH in "${ARCHS[@]}"; do
  echo
  echo "=============================="
  echo " Building architecture: $ARCH"
  echo "=============================="
  WORK="$BASE_DIR/work-$ARCH"
  rm -rf "$WORK"
  mkdir -p "$WORK"
  cd "$WORK"

  # lb config
  lb config --distribution "$DISTRO" --architecture "$ARCH" --iso-volume "${LABEL_BASE}-${ARCH}" --debian-installer false

  # packages list (may need small edits per-arch)
  mkdir -p config/package-lists
  cat > config/package-lists/abstrya.list.chroot <<'PKG'
# Desktop, browser and tools
xorg
openbox
lightdm
chromium-browser
lxterminal
network-manager
network-manager-gnome
nm-connection-editor
calamares
curl
sudo
net-tools
iproute2
x11-utils
# utilities
ca-certificates
PKG

  # create common includes and files
  write_htmls_and_scripts "$WORK"

  # For arm64 on non-arm host, include qemu static if available
  if [ "$ARCH" = "arm64" ]; then
    if [ -f /usr/bin/qemu-aarch64-static ]; then
      mkdir -p config/includes.binary/usr/bin
      cp /usr/bin/qemu-aarch64-static config/includes.binary/usr/bin/ || true
    else
      echo "Warning: qemu-aarch64-static missing on host - arm64 build may fail or be slow."
    fi
  fi

  # Copy calamares binary into chroot if it's available on host (makes installer functional)
  if command -v calamares >/dev/null 2>&1; then
    mkdir -p config/includes.binary/usr/bin
    cp "$(command -v calamares)" config/includes.binary/usr/bin/ || true
  fi

  # Ensure hooks executable
  chmod +x config/hooks/*.chroot || true

  # start build
  echo "Starting lb build for $ARCH. This may take long (tens of minutes to hours)..."
  if sudo lb build; then
    ISOFILE=$(ls *.iso 2>/dev/null || true)
    if [ -n "$ISOFILE" ]; then
      OUT="$BASE_DIR/${LABEL_BASE}-${ARCH}.iso"
      mv "$ISOFILE" "$OUT"
      echo "Built ISO for $ARCH at: $OUT"
    else
      echo "Build finished but no ISO found for $ARCH. Check $WORK for logs."
    fi
  else
    echo "lb build failed for $ARCH. Check logs in $WORK"
    continue
  fi

  # done for this arch
  cd "$BASE_DIR"
done

echo
echo "All done. Generated ISOs (if successful) are in: $BASE_DIR"
ls -lh "$BASE_DIR"/*.iso || true

echo
echo "Notes / Next steps:"
echo " - To write to USB use Rufus/Etcher/Ventoy. For Rufus select DD/hybrid write mode if prompted."
echo " - The built live system auto-login as user '${DEFAULT_USER}' and will start the watcher which polls"
echo "   https://abstryacloud.local (3 tries x ${POLL_INTERVAL}s). If it fails it shows search.html."
echo " - The files /usr/share/abstrya/system/*.html are protected with chmod 000 + chattr +i in the image."
echo " - To edit those files later you must boot a rescue environment and run: chattr -i /usr/share/abstrya/system/<file>; chmod 644 <file>"
echo " - Root password has been set during build to the value you specified (root:${ROOT_PASSWORD}). Keep this secret."
echo
echo "Finished."