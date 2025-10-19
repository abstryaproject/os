#!/usr/bin/env bash
# build-abstry-desktop-v2_6.sh
# Builds ABSTRY DESKTOP v2.6 hybrid ISO(s) with built-in installer and post-install protection.
#
# Run on Ubuntu 22.04 build host.
# Prereqs: see top of file (live-build, qemu-user-static, calamares, zenity, chattr...).
#
set -euo pipefail
IFS=$'\n\t'

############################
# Configuration - edit here
############################
BUILD_ROOT="$HOME/abstry-desktop-builder"
DISTRO="jammy"                             # Ubuntu 22.04 LTS
LABEL_BASE="ABSTRY-DESKTOP"
ARCHS=( "amd64" "i386" "arm64" )           # arches to build
IMAGE_OUTPUT_DIR="$BUILD_ROOT/output"
ROOT_PASSWORD="5000039"                    # root password in installed systems
FALLBACK_USER="guest"                      # fallback username if installer user omitted
FALLBACK_PASS_LENGTH=12
POLL_INTERVAL=30
MAX_TRIES=3
DEFAULT_LIVE_USER="ubuntu"                 # live session user (auto-login in live)
##################################

echo "=== ABSTRY DESKTOP v2.6 ISO Builder ==="
echo "Build root: $BUILD_ROOT"
echo "Output dir: $IMAGE_OUTPUT_DIR"
echo "Architectures: ${ARCHS[*]}"
mkdir -p "$BUILD_ROOT"
mkdir -p "$IMAGE_OUTPUT_DIR"
cd "$BUILD_ROOT"

# quick prerequisite checks (best-effort)
command -v lb >/dev/null || { echo "Missing live-build (lb). Install: sudo apt install live-build"; exit 1; }
command -v curl >/dev/null || { echo "Missing curl. Install it."; exit 1; }

# Helper: create the common files tree for an architecture build
create_includes_tree() {
  local WORKDIR="$1"
  local DIR="$WORKDIR/config/includes.chroot"
  mkdir -p "$DIR/usr/share/abstrya/system"
  mkdir -p "$DIR/usr/local/bin"
  mkdir -p "$DIR/etc/xdg/openbox"
  mkdir -p "$DIR/etc/lightdm/lightdm.conf.d"
  mkdir -p "$DIR/etc/calamares/modules"
  mkdir -p "$DIR/etc/calamares/settings.conf.d"
  mkdir -p "$DIR/etc/calamares/branding/abstry"
  mkdir -p "$DIR/usr/share/applications"
  mkdir -p "$WORKDIR/config/hooks"
  mkdir -p "$DIR/var/log"
  # marker to let welcome dialog know this is live image
  touch "$DIR/is_live_session"
}

# Write website.html and search.html
write_html_pages() {
  local WORKDIR="$1"
  local SYS="$WORKDIR/config/includes.chroot/usr/share/abstrya/system"

  cat > "$SYS/website.html" <<'WHTML'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>ABSTRY DESKTOP</title>
<style>
body{background:#0b0b0b;color:#fff;font-family:"Segoe UI",Arial,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center;flex-direction:column;}
h1{font-size:3.2rem;margin:0 0 1rem 0;}p{font-size:1.1rem;margin:0.2rem 0;}
.footer{position:fixed;bottom:14px;font-size:0.9rem;color:#aaa;}
</style>
</head>
<body>
  <h1>ABSTRY DESKTOP</h1>
  <p>Lightweight secure desktop with cloud connection automation.</p>
  <div class="footer">Powered by Abdullahi Ibrahim Lailaba</div>
</body>
</html>
WHTML

  cat > "$SYS/search.html" <<'SHTML'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>ABSTRY EXPLORER</title>
<script>
async function tryConnect(){
 const raw=document.getElementById('addr').value.trim();
 if(!raw)return;
 const status=document.getElementById('status');
 status.textContent='Connecting…';status.style.color='#ffb400';
 let url=raw;if(!/^https?:\/\//i.test(url))url='https://'+url;
 try{await fetch(url,{mode:'no-cors',cache:'no-store'});
   status.textContent='Connected. Opening...';status.style.color='#00ff66';window.location.href=url;
 }catch(e){status.textContent='Connection failed. Press Ctrl+Shift+N to check Network connection.';status.style.color='#ff4444';}
}
document.addEventListener('DOMContentLoaded',()=>{document.getElementById('addr').addEventListener('keydown',e=>{if(e.key==='Enter')tryConnect();});});
</script>
<style>
body{background:#0b0b0b;color:#fff;font-family:"Segoe UI",Arial,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center;flex-direction:column;}
h1{font-size:3.2rem;margin:0 0 1rem 0;}
input[type=text]{width:60%;max-width:520px;padding:12px;margin-top:8px;font-size:16px;border:none;border-radius:8px;text-align:center;background:#303030;color:#fff;}
input[type=text]::placeholder{color:#ccc;}
#status{margin-top:14px;font-style:italic;}
.footer{position:fixed;bottom:14px;font-size:0.9rem;color:#aaa;}
</style>
</head>
<body>
  <h1>ABSTRY EXPLORER</h1>
  <input id="addr" type="text" placeholder="Enter domain or IP address to explore manually"/>
  <div id="status"></div>
  <div class="footer">Powered by Abdullahi Ibrahim Lailaba</div>
</body>
</html>
SHTML
}

# Write helper scripts: launch-browser, watcher, network settings, open-search
write_helper_scripts() {
  local WORKDIR="$1"
  local BIN="$WORKDIR/config/includes.chroot/usr/local/bin"

  cat > "$BIN/abstrya-launch-browser.sh" <<'LB'
#!/bin/bash
TARGET="https://abstryacloud.local"
WELCOME="file:///usr/share/abstrya/system/website.html"
pkill -f "chromium" >/dev/null 2>&1 || true
if curl -Is --connect-timeout 5 "$TARGET" >/dev/null 2>&1; then
  chromium-browser --kiosk --incognito --no-first-run --disable-file-access "$TARGET" &
else
  chromium-browser --kiosk "$WELCOME" &
fi
LB
  chmod +x "$BIN/abstrya-launch-browser.sh"

  cat > "$BIN/abstrya-watcher.sh" <<'AW'
#!/bin/bash
TARGET="https://abstryacloud.local"
WELCOME="file:///usr/share/abstrya/system/website.html"
POLL=30; MAX=3
while true; do
  TRIES=0; FOUND=0
  while [ $TRIES -lt $MAX ]; do
    if curl -Is --connect-timeout 5 "$TARGET" >/dev/null 2>&1; then FOUND=1; break; fi
    TRIES=$((TRIES+1)); sleep "$POLL"
  done
  if [ $FOUND -eq 1 ]; then
    if ! pgrep -f "chromium.*${TARGET}" >/dev/null 2>&1; then
      pkill -f chromium >/dev/null 2>&1 || true
      chromium-browser --kiosk --incognito --no-first-run --disable-file-access "$TARGET" &
    fi
  else
    if ! pgrep -f "chromium.*search.html" >/dev/null 2>&1; then
      pkill -f chromium >/dev/null 2>&1 || true
      chromium-browser --kiosk "file:///usr/share/abstrya/system/search.html" &
    fi
  fi
  sleep "$POLL"
done
AW
  chmod +x "$BIN/abstrya-watcher.sh"

  cat > "$BIN/abstrya-network-settings.sh" <<'NS'
#!/bin/bash
if [ -n "$DISPLAY" ]; then
  if command -v nm-connection-editor >/dev/null 2>&1; then
    nm-connection-editor &
  else
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
  chmod +x "$BIN/abstrya-network-settings.sh"

  cat > "$BIN/abstrya-open-search.sh" <<'OS'
#!/bin/bash
x-www-browser /usr/share/abstrya/system/search.html &
OS
  chmod +x "$BIN/abstrya-open-search.sh"
}

# Welcome dialog (only in live)
write_welcome_dialog() {
  local WORKDIR="$1"
  local BIN="$WORKDIR/config/includes.chroot/usr/local/bin"

  cat > "$BIN/abstry-welcome-dialog.sh" <<'WD'
#!/bin/bash
# Only show in live session
if [ ! -f /cdrom/casper/filesystem.squashfs ] && [ ! -d /lib/live/mount/medium ] && [ ! -f /is_live_session ]; then exit 0; fi
[ -z "$DISPLAY" ] && exit 0
CHOICE=$(zenity --list --radiolist --title="ABSTRY DESKTOP" \
  --text="Welcome to ABSTRY DESKTOP — choose an action:" \
  --column="" --column="Action" \
  TRUE "Try ABSTRY LIVE (Network setup & demo)" FALSE "Install ABSTRY DESKTOP" \
  --height=220 --width=420 --ok-label="Select" --cancel-label="Close")
[ -z "$CHOICE" ] && exit 0
if echo "$CHOICE" | grep -qi "Try ABSTRY LIVE"; then
  if command -v nm-connection-editor >/dev/null 2>&1; then nm-connection-editor & else zenity --info --text="Network tools not found. Use Ctrl+Shift+T to open terminal." --no-wrap; fi
  exit 0
fi
if echo "$CHOICE" | grep -qi "Install ABSTRY DESKTOP"; then
  if command -v calamares >/dev/null 2>&1; then calamares & else zenity --error --text="Installer not found." --no-wrap; fi
  exit 0
fi
WD
  chmod +x "$BIN/abstry-welcome-dialog.sh"
}

# Openbox autostart and keybindings
write_openbox_configs() {
  local WORKDIR="$1"
  local XDG="$WORKDIR/config/includes.chroot/etc/xdg/openbox"
  mkdir -p "$XDG"

  cat > "$XDG/autostart" <<'AUTO'
#!/bin/bash
nohup /usr/local/bin/abstrya-watcher.sh >/var/log/abstrya-watcher.log 2>&1 &
if ! pgrep -f "chromium" >/dev/null 2>&1; then
  chromium-browser --kiosk file:///usr/share/abstrya/system/website.html &
fi
# show welcome dialog only in live images
if [ -f /cdrom/casper/filesystem.squashfs ] || [ -d /lib/live/mount/medium ] || [ -f /is_live_session ]; then
  sleep 5
  /usr/local/bin/abstry-welcome-dialog.sh &
fi
AUTO
  chmod +x "$XDG/autostart"

  cat > "$XDG/rc.xml" <<'RC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config>
  <keyboard>
    <keybind key="C-S-T"><action name="Execute"><command>lxterminal</command></action></keybind>
    <keybind key="C-S-N"><action name="Execute"><command>/usr/local/bin/abstrya-network-settings.sh</command></action></keybind>
    <keybind key="C-S-B"><action name="Execute"><command>/usr/local/bin/abstrya-launch-browser.sh</command></action></keybind>
    <keybind key="C-S-A"><action name="Execute"><command>systemctl poweroff</command></action></keybind>
    <keybind key="C-S-R"><action name="Execute"><command>systemctl reboot</command></action></keybind>
    <keybind key="C-s"><action name="Execute"><command>/usr/local/bin/abstrya-open-search.sh</command></action></keybind>
  </keyboard>
</openbox_config>
RC
}

# LightDM autologin (live session)
write_lightdm_autologin() {
  local WORKDIR="$1"
  local LDM="$WORKDIR/config/includes.chroot/etc/lightdm/lightdm.conf.d"
  mkdir -p "$LDM"
  cat > "$LDM/50-abstry.conf" <<LDM
[Seat:*]
autologin-user=$DEFAULT_LIVE_USER
autologin-session=openbox
LDM
}

# Calamares settings + branding + post-install hook module
write_calamares_config() {
  local WORKDIR="$1"
  local CAL="$WORKDIR/config/includes.chroot/etc/calamares"
  mkdir -p "$CAL/modules" "$CAL/settings.conf.d" "$CAL/branding/abstry"

  cat > "$CAL/settings.conf.d/abstry.conf" <<CONF
---
modules-search: /usr/lib/calamares/modules
sequence:
  - welcome
  - locale
  - keyboard
  - partition
  - users
  - networkcfg
  - summary
  - install
  - finished
CONF

  cat > "$CAL/branding/abstry/branding.desc" <<BRAND
---
componentName: abstry
strings:
  productName: "ABSTRY DESKTOP"
  version: "v2.6"
  shortVersion: "2.6"
BRAND

  # installer desktop entry
  cat > "$WORKDIR/config/includes.chroot/usr/share/applications/abstry-installer.desktop" <<DESK
[Desktop Entry]
Name=Install ABSTRY DESKTOP
Exec=calamares
Type=Application
Terminal=false
Categories=System;
DESK

  # Add Calamares exec module to run our postinstall inside target
  mkdir -p "$CAL/modules"
  cat > "$CAL/modules/abstry-postinstall.conf" <<MOD
---
- name: abstry-postinstall
  exec:
    - /usr/local/bin/abstry-postinstall.sh
MOD

  # Add to settings sequence as an extra exec at the end (safely appended)
  cat > "$CAL/settings.conf.d/90-abstry-postinstall.conf" <<SEQ
---
sequence:
  - exec:
      name: abstry-postinstall
SEQ
}

# Write Calamares post-install script (this runs inside the installed target after Calamares)
write_abstry_postinstall() {
  local WORKDIR="$1"
  local PATH_TO="$WORKDIR/config/includes.chroot/usr/local/bin/abstry-postinstall.sh"

  cat > "$PATH_TO" <<'POST'
#!/usr/bin/env bash
# abstry-postinstall.sh
# This script is executed by Calamares inside the installed target (chroot).
set -euo pipefail

echo "[ABSTRY] Running post-install configuration..."

# 1) set root password
echo "root:5000039" | chpasswd || true

# 2) ensure NetworkManager enabled
systemctl enable NetworkManager.service >/dev/null 2>&1 || true
systemctl restart NetworkManager.service >/dev/null 2>&1 || true

# 3) detect if installer created a user (UID >=1000)
USER_FOUND=""
while IFS=: read -r uname _ uid _ _ _ _; do
  if [ "$uid" -ge 1000 ] && [ "$uname" != "nobody" ]; then
    USER_FOUND="$uname"
    break
  fi
done < /etc/passwd

# 4) if no user found, create fallback user and set password
if [ -z "$USER_FOUND" ]; then
  FALLBACK_USER="guest"
  FALLBACK_PASS=$(tr -dc 'A-Za-z0-9!@#$%_-' </dev/urandom | head -c 12 || echo "guestpass123")
  useradd -m -s /bin/bash "$FALLBACK_USER" || true
  echo "${FALLBACK_USER}:${FALLBACK_PASS}" | chpasswd || true
  usermod -aG sudo "$FALLBACK_USER" || true
  USER_FOUND="$FALLBACK_USER"
  # configure LightDM autologin to fallback user
  mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/50-abstry.conf <<LDM
[Seat:*]
autologin-user=${FALLBACK_USER}
autologin-session=openbox
LDM
  # show fallback password to console and GUI if possible
  if command -v zenity >/dev/null 2>&1; then
    sudo -u "$FALLBACK_USER" zenity --info --title="ABSTRY: Fallback account" --text="Fallback account created:\n\nUser: ${FALLBACK_USER}\nPassword: ${FALLBACK_PASS}\n\nPlease change this password on first login." --no-wrap || true
  else
    echo "FALLBACK_ACCOUNT:${FALLBACK_USER}:${FALLBACK_PASS}" > /root/ABSTRY-FALLBACK-INFO
    chmod 600 /root/ABSTRY-FALLBACK-INFO || true
  fi
fi

# 5) ensure user has openbox config
if [ -n "$USER_FOUND" ]; then
  mkdir -p /home/"$USER_FOUND"/.config/openbox
  cp /etc/xdg/openbox/rc.xml /home/"$USER_FOUND"/.config/openbox/ 2>/dev/null || true
  chown -R "$USER_FOUND":"$USER_FOUND" /home/"$USER_FOUND"/.config || true
fi

# 6) configure chromium kiosk autostart for installer user
if [ -n "$USER_FOUND" ]; then
  mkdir -p /home/"$USER_FOUND"/.config/autostart
  cat > /home/"$USER_FOUND"/.config/autostart/abstry-browser.desktop <<EOF
[Desktop Entry]
Type=Application
Name=ABSTRY Cloud Browser
Exec=chromium --kiosk --noerrdialogs --disable-session-crashed-bubble --disable-infobars https://abstryacloud.local
X-GNOME-Autostart-enabled=true
EOF
  chown -R "$USER_FOUND":"$USER_FOUND" /home/"$USER_FOUND"/.config || true
fi

# 7) Lock critical files (careful - requires recovery plan)
LOCK_PATHS=(
  "/usr/share/abstrya/system"
  "/usr/local/bin/abstrya-*.sh"
  "/etc/xdg/openbox/rc.xml"
)
for p in "${LOCK_PATHS[@]}"; do
  if ls $p >/dev/null 2>&1; then
    # set ownership/permissions and make immutable
    chown -R root:root $p || true
    chmod -R 000 $p || true
    if command -v chattr >/dev/null 2>&1; then
      chattr -R +i $p || true
    fi
  fi
done

# 8) disable direct root GUI login by keeping autologin set to created user (but root account is enabled for CLI)
passwd -l root || true

# 9) final cleanup
apt-get clean || true
echo "[ABSTRY] Post-install complete."
POST

  chmod +x "$PATH_TO"
}

# Add post-setup chroot hook to image build: set root password in the image and mark files
write_image_hooks() {
  local WORKDIR="$1"
  local HOOK="$WORKDIR/config/hooks/02-post-setup.chroot"
  cat > "$HOOK" <<'HOOK'
#!/bin/bash
set -e
# This runs inside the image chroot during lb build
# Set root password in image (so live and installer have root password)
echo "root:5000039" | chpasswd || true

# Ensure scripts are executable
chmod +x /usr/local/bin/abstrya-*.sh /usr/local/bin/abstry-welcome-dialog.sh /usr/local/bin/abstry-postinstall.sh || true

# Ensure system dir ownership
if [ -d /usr/share/abstrya/system ]; then
  chown -R root:root /usr/share/abstrya/system || true
  chmod 000 /usr/share/abstrya/system/* || true
  if command -v chattr >/dev/null 2>&1; then
    chattr +i /usr/share/abstrya/system/* || true
  fi
fi
HOOK
  chmod +x "$HOOK"
}

# Package list creation
write_package_list() {
  local WORKDIR="$1"
  mkdir -p "$WORKDIR/config/package-lists"
  cat > "$WORKDIR/config/package-lists/abstry.list.chroot" <<'PKG'
xorg
openbox
lightdm
chromium-browser
lxterminal
network-manager
network-manager-gnome
nm-connection-editor
calamares
zenity
curl
sudo
ca-certificates
PKG
}

# Main build loop per architecture
for ARCH in "${ARCHS[@]}"; do
  echo "=== Build sequence for arch: $ARCH ==="
  WORK="$BUILD_ROOT/work-$ARCH"
  rm -rf "$WORK"
  mkdir -p "$WORK"
  cd "$WORK"

  echo "[*] Live-build config..."
  lb config --distribution "$DISTRO" --architecture "$ARCH" --iso-volume "${LABEL_BASE}-${ARCH}" --debian-installer false

  # prepare includes and files
  create_includes_tree "$WORK"
  write_html_pages "$WORK"
  write_helper_scripts "$WORK"
  write_welcome_dialog "$WORK"
  write_openbox_configs "$WORK"
  write_lightdm_autologin "$WORK"
  write_calamares_config "$WORK"
  write_abstry_postinstall "$WORK"
  write_image_hooks "$WORK"
  write_package_list "$WORK"

  # copy calamares binary into image if available on host (makes live installer easier)
  if command -v calamares >/dev/null 2>&1; then
    mkdir -p "$WORK/config/includes.binary/usr/bin"
    cp "$(command -v calamares)" "$WORK/config/includes.binary/usr/bin/" || true
  fi

  # if building arm64 on x86 host and qemu available, include qemu static
  if [ "$ARCH" = "arm64" ] && [ -f /usr/bin/qemu-aarch64-static ]; then
    mkdir -p "$WORK/config/includes.binary/usr/bin"
    cp /usr/bin/qemu-aarch64-static "$WORK/config/includes.binary/usr/bin/" || true
  fi

  # Ensure hooks are executable
  chmod +x "$WORK/config/hooks/"*.chroot || true

  # Build (this runs sudo lb build)
  echo "[*] Starting live-build (this may take long)..."
  sudo lb build

  # Move resulting ISO to output directory
  ISOFILE=$(ls *.iso 2>/dev/null || true)
  if [ -n "$ISOFILE" ]; then
    mv "$ISOFILE" "$IMAGE_OUTPUT_DIR/${LABEL_BASE}-${ARCH}.iso" || true
    echo "[OK] Built ISO: $IMAGE_OUTPUT_DIR/${LABEL_BASE}-${ARCH}.iso"
  else
    echo "[WARN] No ISO found for $ARCH. Check $WORK for logs."
  fi

done

echo "=== Build finished. ISOs are in: $IMAGE_OUTPUT_DIR ==="
ls -lh "$IMAGE_OUTPUT_DIR" || true
echo "Reminder: inspect the included post-install script (abstry-postinstall.sh) before enabling immutability in production."
