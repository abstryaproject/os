#!/usr/bin/env bash
#
# build_abstry_desktop_kidlock.sh
#
# Builds ABSTRY DESKTOP (kid-focused) ISO with strong protections applied during image build.
# WARNING: This creates images with many immutable files (chattr +i). Use rescue media to unlock.
#
set -euo pipefail

sudo apt update
sudo apt install -y live-build debootstrap squashfs-tools xorriso curl git ca-certificates \
  qemu-user-static binfmt-support grub-pc-bin grub-efi-amd64-bin calamares curl e2fsprogs

# -------------------------
# Configuration
# -------------------------
BASE_DIR="$HOME/abstry-desktop-kidlock-build"
DISTRO="jammy"
ARCH="amd64"
ISO_LABEL="ABSTRY-DESKTOP-KIDLOCK-amd64"
ROOT_PASSWORD="5000039"   # per previous request; change if needed
DEFAULT_CHILD_USER="child"
POLL_INTERVAL=30
MAX_TRIES=3

# Files & paths to protect (globs supported)
PROTECT_PATTERNS=(
  "/usr/share/abstrya/system/*"
  "/usr/local/bin/abstrya-*.sh"
  "/etc/xdg/openbox/*"
  "/etc/lightdm/lightdm.conf.d/50-abstry.conf"
  "/etc/systemd/system/abstrya-*.service"
  "/usr/share/applications/abstry-installer.desktop"
  "/etc/fstab"
  "/etc/hosts"
  "/etc/hostname"
  "/etc/sudoers"
  "/etc/sudoers.d/*"
)

# directories to recursively lock (immutable)
PROTECT_DIRS=(
  "/usr/local/bin"
  "/usr/share/abstrya"
  "/etc/xdg/openbox"
  "/etc/systemd/system"
)

# -------------------------
# Helpers
# -------------------------
echo "ABSTRY DESKTOP KidLock ISO builder"
echo "Build dir: $BASE_DIR"
rm -rf "$BASE_DIR"
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# --- configure lb
echo "Configuring live-build..."
lb config --distribution "$DISTRO" --architecture "$ARCH" --iso-volume "$ISO_LABEL" --debian-installer false

# --- packages: intentionally exclude terminal apps and sudo for child user
mkdir -p config/package-lists
cat > config/package-lists/abstry.list.chroot <<'PKG'
# Minimal X and browser + network + installer
xorg
openbox
lightdm
chromium-browser
network-manager
network-manager-gnome
nm-connection-editor
calamares
curl
net-tools
iproute2
x11-utils
ca-certificates
# Do NOT include terminal emulators or sudo for child user in the live image.
PKG

# --- create includes layout
mkdir -p config/includes.chroot/usr/share/abstrya/system
mkdir -p config/includes.chroot/usr/local/bin
mkdir -p config/includes.chroot/etc/xdg/openbox
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
mkdir -p config/includes.chroot/etc/systemd/system
mkdir -p config/includes.chroot/usr/share/applications
mkdir -p config/hooks

# -------------------------
# 1) Welcome (website.html) & Search (search.html)
# -------------------------
cat > config/includes.chroot/usr/share/abstrya/system/website.html <<'WHTML'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>ABSTRY DESKTOP</title>
<style>
body { background: #0b0b0b; color: #fff; font-family: "Segoe UI", Arial, sans-serif; display:flex; align-items:center; justify-content:center; height:100vh; margin:0; text-align:center; flex-direction:column; }
h1 { font-size: 3.2rem; margin: 0 0 1rem 0; }
p { font-size: 1.1rem; margin: 0.2rem 0; }
.footer { position: fixed; bottom: 20px; font-size: 0.95rem; opacity: 0.85; }
</style>
</head>
<body>
  <h1>ABSTRY DESKTOP</h1>
  <p>Lightweight OS designed for secure, automatic, and resilient connection.</p>
  <p>Press Ctrl+S to open Explorer</p>
  <div class="footer">Powered by Abdullahi Ibrahim Lailaba</div>
</body>
</html>
WHTML

cat > config/includes.chroot/usr/share/abstrya/system/search.html <<'SHTML'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>ABSTRY EXPLORER</title>
<script>
async function tryConnect() {
  const raw = document.getElementById('addr').value.trim();
  if (!raw) return;
  const status = document.getElementById('status');
  status.textContent = 'Connecting…';
  status.style.color = '#ffb400';
  let url = raw;
  if (!/^https?:\/\//i.test(url)) {
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
body {
  background: #0b0b0b;
  color: #fff;
  font-family: "Segoe UI", Arial, sans-serif;
  display: flex; align-items: center; justify-content: center; height:100vh; margin:0; text-align:center; flex-direction:column;
}
h1 { font-size: 3.2rem; margin: 0 0 1rem 0; }
input[type=text] {
  width: 60%; max-width: 520px; padding: 12px; margin-top: 8px; font-size: 16px; border: none; border-radius: 8px; text-align:center; background:#303030; color:#fff;
}
input[type=text]::placeholder { color: #ccc; }
#status { margin-top: 14px; font-style: italic; }
.footer { position: fixed; bottom: 14px; font-size: 0.9rem; color:#aaa; opacity:0.85; }
</style>
</head>
<body>
  <h1>ABSTRY EXPLORER</h1>
  <input id="addr" type="text" placeholder="Enter domain or IP address to explore manually">
  <div id="status"></div>
  <div class="footer">Powered by Abdullahi Ibrahim Lailaba</div>
</body>
</html>
SHTML

# -------------------------
# 2) Helper scripts (no terminal-related scripts)
# -------------------------
cat > config/includes.chroot/usr/local/bin/abstrya-launch-browser.sh <<'LB'
#!/bin/bash
TARGET="https://abstryacloud.local"
WELCOME="file:///usr/share/abstrya/system/website.html"
pkill -f "chromium" >/dev/null 2>&1 || true
if curl -Is --connect-timeout 5 "$TARGET" >/dev/null 2>&1; then
  chromium-browser --kiosk --no-first-run --incognito --disable-file-access "$TARGET" &
else
  chromium-browser --kiosk "$WELCOME" &
fi
LB
chmod +x config/includes.chroot/usr/local/bin/abstrya-launch-browser.sh

cat > config/includes.chroot/usr/local/bin/abstrya-watcher.sh <<'AW'
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
    if ! pgrep -f "chromium.*${TARGET}" >/dev/null 2>&1; then
      pkill -f chromium >/dev/null 2>&1 || true
      chromium-browser --kiosk --no-first-run --incognito --disable-file-access "$TARGET" &
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
chmod +x config/includes.chroot/usr/local/bin/abstrya-watcher.sh

cat > config/includes.chroot/usr/local/bin/abstrya-network-settings.sh <<'NS'
#!/bin/bash
# Try GUI network editor if display exists; else try nmtui (not expected in kid mode)
if [ -n "$DISPLAY" ]; then
  if command -v nm-connection-editor >/dev/null 2>&1; then
    nm-connection-editor &
  fi
else
  if command -v nmtui >/dev/null 2>&1; then
    nmtui
  fi
fi
NS
chmod +x config/includes.chroot/usr/local/bin/abstrya-network-settings.sh

cat > config/includes.chroot/usr/local/bin/abstrya-open-search.sh <<'OS'
#!/bin/bash
x-www-browser /usr/share/abstrya/system/search.html &
OS
chmod +x config/includes.chroot/usr/local/bin/abstrya-open-search.sh

# -------------------------
# 3) Openbox autostart & keybindings
#    (no terminal keybind, child user has no sudo)
# -------------------------
cat > config/includes.chroot/etc/xdg/openbox/autostart <<'AUTO'
#!/bin/bash
# Start watcher as background process
nohup /usr/local/bin/abstrya-watcher.sh >/var/log/abstrya-watcher.log 2>&1 &
# Show welcome page immediately
chromium-browser --kiosk file:///usr/share/abstrya/system/website.html &
AUTO
chmod +x config/includes.chroot/etc/xdg/openbox/autostart

cat > config/includes.chroot/etc/xdg/openbox/rc.xml <<'RC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config>
  <keyboard>
    <!-- Note: no Terminal keybind for kids -->
    <keybind key="C-S-A"><action name="Execute"><command>systemctl poweroff</command></action></keybind>
    <keybind key="C-S-B"><action name="Execute"><command>/usr/local/bin/abstrya-launch-browser.sh</command></action></keybind>
    <keybind key="C-S-R"><action name="Execute"><command>systemctl reboot</command></action></keybind>
    <keybind key="C-S-N"><action name="Execute"><command>/usr/local/bin/abstrya-network-settings.sh</command></action></keybind>
    <keybind key="C-s"><action name="Execute"><command>/usr/local/bin/abstrya-open-search.sh</command></action></keybind>
  </keyboard>
</openbox_config>
RC

# -------------------------
# 4) LightDM autologin to child user (no sudo)
# -------------------------
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/50-abstry.conf <<'LDM'
[Seat:*]
autologin-user=child
autologin-session=openbox
LDM

# -------------------------
# 5) systemd watcher unit (enabled)
# -------------------------
cat > config/includes.chroot/etc/systemd/system/abstrya-watcher.service <<'SVC'
[Unit]
Description=Abstrya Watcher (launches kiosk or search)
After=graphical.target

[Service]
Type=simple
ExecStart=/usr/local/bin/abstrya-watcher.sh
Restart=always
User=child
Environment=DISPLAY=:0

[Install]
WantedBy=graphical.target
SVC

# -------------------------
# 6) Calamares desktop entry (installer) - visible but installing requires admin
# -------------------------
cat > config/includes.chroot/usr/share/applications/abstry-installer.desktop <<'DESK'
[Desktop Entry]
Name=Install ABSTRY DESKTOP
Exec=calamares
Type=Application
Terminal=false
Categories=System;
DESK

# -------------------------
# 7) fstab bind for read-only system dir
# -------------------------
cat > config/includes.chroot/etc/fstab <<'FSTAB'
/usr/share/abstrya/system  /usr/share/abstrya/system  none  bind,ro  0  0
FSTAB

# -------------------------
# 8) post-setup hook: create child user, set root pw, disable sudo for child,
#    prepare backups and then perform FORCE lockdown (chmod + chattr +i)
#    WARNING: This hook executes inside chroot at image build time.
# -------------------------
cat > config/hooks/02-kidlock-post.chroot <<'HOOK'
#!/bin/bash
set -e

BACKUP_DIR="/var/abstry_build_backups_$(date +%Y%m%d%H%M%S)"
mkdir -p "\$BACKUP_DIR"

# create child user (no password login for live session) but no sudo
if ! id child >/dev/null 2>&1; then
  useradd -m -s /bin/false child || true
fi

# ensure default live user exists too (some live images use 'ubuntu')
if ! id ubuntu >/dev/null 2>&1; then
  useradd -m -s /bin/false ubuntu || true
fi

# set root password (configured by builder)
echo "root:${ROOT_PASSWORD}" | chpasswd || true

# Remove sudo privileges for child user; ensure child not in sudoers
if [ -f /etc/sudoers.d/90-cloud-init-users ]; then
  rm -f /etc/sudoers.d/90-cloud-init-users || true
fi
# create a restrictive sudoers file for admin only (leave root only)
echo "" > /etc/sudoers.d/99-disabled
chmod 440 /etc/sudoers.d/99-disabled || true

# Back up files to backup dir (best-effort)
mkdir -p "\$BACKUP_DIR/usr_share_abstrya"
cp -a /usr/share/abstrya/system/* "\$BACKUP_DIR/usr_share_abstrya/" || true
mkdir -p "\$BACKUP_DIR/etc_xdg_openbox"
cp -a /etc/xdg/openbox/* "\$BACKUP_DIR/etc_xdg_openbox/" || true
cp -a /usr/local/bin/abstrya-* "\$BACKUP_DIR/" >/dev/null 2>&1 || true

# Disable getty ttys to prevent user switching to consoles (no tty logins)
for i in 1 2 3 4 5 6; do
  if [ -f /etc/systemd/system/getty@tty${i}.service ]; then
    systemctl mask getty@tty${i}.service || true
  fi
done

# Prepare list of files to protect (expand globs)
PROTECT_PATTERNS=(
  /usr/share/abstrya/system/*
  /usr/local/bin/abstrya-*.sh
  /etc/xdg/openbox/*
  /etc/lightdm/lightdm.conf.d/50-abstry.conf
  /etc/systemd/system/abstrya-*.service
  /usr/share/applications/abstry-installer.desktop
  /etc/fstab
  /etc/hosts
  /etc/hostname
  /etc/sudoers
  /etc/sudoers.d/*
)

# Make files root-owned and remove all permissions
for p in "\${PROTECT_PATTERNS[@]}"; do
  for f in \$p; do
    if [ -e "\$f" ]; then
      chown root:root "\$f" || true
      chmod 000 "\$f" || true
      cp -a "\$f" "\$BACKUP_DIR/$(echo "\$f" | sed 's/\\//_/g')" || true
    fi
  done
done

# Lock entire directories (recursive immutable)
LOCK_DIRS=(/usr/local/bin /usr/share/abstrya /etc/xdg/openbox /etc/systemd/system)
if command -v chattr >/dev/null 2>&1; then
  for d in "\${LOCK_DIRS[@]}"; do
    if [ -d "\$d" ]; then
      # make files root-owned & no perms
      chown -R root:root "\$d" || true
      chmod -R 000 "\$d" || true
      # apply immutable to files and directories inside
      find "\$d" -type f -exec chattr +i {} \\; || true
      find "\$d" -type d -exec chattr +i {} \\; || true
    fi
  done

  # Also protect specific files in /etc
  chattr +i /etc/fstab 2>/dev/null || true
  chattr +i /etc/hosts 2>/dev/null || true
  chattr +i /etc/hostname 2>/dev/null || true
  chattr +i /etc/sudoers 2>/dev/null || true
fi

echo "KidLock post-setup complete. Backups in: \$BACKUP_DIR"
HOOK
chmod +x config/hooks/02-kidlock-post.chroot

# -------------------------
# 9) Make Calamares available if present on builder host
# -------------------------
if command -v calamares >/dev/null 2>&1; then
  mkdir -p config/includes.binary/usr/bin
  cp "$(command -v calamares)" config/includes.binary/usr/bin/ || true
fi

# -------------------------
# 10) Post hook to ensure watcher service enabled and permissions
# -------------------------
cat > config/hooks/03-finalize.chroot <<'FHOOK'
#!/bin/bash
set -e
chmod +x /usr/local/bin/abstrya-*.sh || true
# enable watcher service so it starts in live session
if [ -d /lib/systemd/system ]; then
  /bin/systemctl enable abstrya-watcher.service || true
fi
FHOOK
chmod +x config/hooks/03-finalize.chroot

# -------------------------
# 11) Build ISO
# -------------------------
echo "Starting lb build (this may take a while)..."
sudo lb build

ISOFILE=$(ls *.iso 2>/dev/null || true)
if [ -n "$ISOFILE" ]; then
  OUT="$BASE_DIR/${ISO_LABEL}.iso"
  mv "$ISOFILE" "$OUT" || true
  echo "Built ISO: $OUT"
else
  echo "No ISO produced — check logs in build dir: $BASE_DIR"
fi

# -------------------------
# Final notes
# -------------------------
cat <<'NOTE'

BUILD COMPLETE (or attempted).

IMPORTANT:
- The image produced includes build-time protections:
  - Terminal packages were omitted.
  - Child user 'child' is configured (non-sudo).
  - getty ttys are masked in the build chroot so TTY login switching is disabled in the image.
  - Files under /usr/share/abstrya/system and other critical paths are set to chmod 000 and chattr +i in the build hook.
- To modify or update the image later, you must boot a rescue environment and run:
    sudo chattr -i <file>
    sudo chmod 644 <file>
  and revert the protections before applying updates.

SECURITY ADVICE:
- Consider using per-device unique root/admin passwords rather than shipping a shared root password.
- For production fleet management consider read-only signed squashfs approach and OTA replacement of images.

TESTING:
- Boot the ISO in a VM (qemu/virtualbox) first and verify behavior before flashing to devices.

For more information, contact us at WhatsApp: +234(0)8138605126

NOTE
