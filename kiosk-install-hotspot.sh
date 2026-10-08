#!/usr/bin/env bash
# =============================================================================
#  Touchscreen Kiosk Installer  -  HOTSPOT version
#  Adds Wi-Fi tools, Offline mode and the setup hotspot (Ctrl+Alt+W).
#  For the simpler version without these, use kiosk-install.sh
#  Works on:  Raspberry Pi 5  -> Raspberry Pi OS Lite (64-bit)
#             x86 mini PC     -> Debian 13 (minimal / netinst, no desktop)
#
#  What you get:
#    * Boots straight into full-screen Chromium (no desktop, no address bar)
#    * Portrait rotation with touch input mapped to the rotated screen
#    * Web settings page at  http://<hostname>.local:8080  (password protected)
#        - set the home page to a web address, or to a page stored on the kiosk
#        - file browser: open folders, pick the home page, view, delete
#        - upload many files at once, a whole folder, or a .zip (auto-unpacked)
#        - idle timeout: after X minutes with no touches, go back to home page
#        - screen on/off schedule by time and day of week
#        - time zone, hide mouse pointer, graphics compatibility mode
#        - Wi-Fi: scan, connect, forget networks
#
#        - Network mode: "Use Wi-Fi" or "Offline" (never joins Wi-Fi)
#
#  Setup hotspot ("Kiosk-<name>", settings at http://10.42.0.1:8080):
#    * Ctrl+Alt+W on a keyboard plugged into the kiosk turns it on/off any time
#      (offline mode too). It turns itself off after 30 min with no phone.
#    * In Wi-Fi mode it also starts by itself if the network is lost.
#  Other keys: Ctrl+Alt+S settings on screen, Ctrl+Alt+H home,
#              Ctrl+Alt+F2 text login (Ctrl+Alt+F1 returns)
#        - "Go home now", "Screen on/off", "Reboot" and "Shut down" buttons
#
#  Install:
#    1. Flash the OS, create your user, enable SSH, connect to the network.
#    2. Copy this file to the machine, then run:   sudo bash kiosk-install.sh
#    3. Reboot. Open the settings page from a phone or PC.
#
#  Re-running the script is safe; your saved settings and pages are kept.
# =============================================================================
set -euo pipefail

ADMIN_PORT="${ADMIN_PORT:-8080}"

# ---------- checks ------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo:  sudo bash $0"
  exit 1
fi

KIOSK_USER="${KIOSK_USER:-${SUDO_USER:-}}"
if [[ -z "$KIOSK_USER" || "$KIOSK_USER" == "root" ]]; then
  echo "Run this as your normal user with sudo, or set the user explicitly:"
  echo "  KIOSK_USER=yourname bash $0"
  exit 1
fi
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  echo "User '$KIOSK_USER' does not exist."
  exit 1
fi

KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
KIOSK_GROUP="$(id -gn "$KIOSK_USER")"
PAGES_DIR="$KIOSK_HOME/kiosk-pages"
STATE_DIR="$KIOSK_HOME/.local/state/kiosk"

if grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
  PLATFORM="Raspberry Pi"
else
  PLATFORM="x86 PC"
fi

echo "==> Installing kiosk for user '$KIOSK_USER' on $PLATFORM"

# ---------- packages ----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  labwc swayidle wlr-randr python3 curl sudo procps util-linux \
  avahi-daemon ca-certificates dbus-user-session \
  fonts-dejavu-core fonts-noto-color-emoji \
  libgl1-mesa-dri libegl1

# Optional helpers (not fatal if missing)
# polkit helps the display session get access to the screen on some PCs
apt-get install -y --no-install-recommends polkitd \
  || apt-get install -y --no-install-recommends policykit-1 || true
apt-get install -y --no-install-recommends wlopm \
  || echo "   (wlopm not available - screen off will use wlr-randr instead)"
apt-get install -y --no-install-recommends v4l-utils \
  || echo "   (v4l-utils not available - HDMI-CEC TV control disabled)"

# Networking: NetworkManager runs Wi-Fi and the backup setup hotspot
apt-get install -y --no-install-recommends network-manager wpasupplicant dnsmasq-base \
  || echo "   (could not install NetworkManager - Wi-Fi tools and backup hotspot disabled)"
apt-get install -y --no-install-recommends iw || true
systemctl enable --now NetworkManager >/dev/null 2>&1 || true

# Chromium package name differs between releases
if ! apt-get install -y chromium; then
  apt-get install -y chromium-browser
fi

for g in video render input; do
  getent group "$g" >/dev/null && usermod -aG "$g" "$KIOSK_USER"
done

# ---------- folders -----------------------------------------------------------
install -d -o "$KIOSK_USER" -g "$KIOSK_GROUP" -m 755 /etc/kiosk
install -d -o "$KIOSK_USER" -g "$KIOSK_GROUP" "$PAGES_DIR" "$STATE_DIR"
install -d -o "$KIOSK_USER" -g "$KIOSK_GROUP" "$KIOSK_HOME/.config" "$KIOSK_HOME/.config/labwc"
install -d /opt/kiosk

# ---------- default settings (kept if they already exist) ---------------------
if [[ ! -f /etc/kiosk/kiosk.conf ]]; then
  cat > /etc/kiosk/kiosk.conf <<EOF
# Kiosk settings - normally edited from the web settings page
HOME_URL='http://localhost:${ADMIN_PORT}/pages/welcome/index.html'
IDLE_MINUTES=5
ROTATION=90
SCALE=1
OUTPUT=auto
SCHEDULE_ENABLED=0
SCREEN_ON=06:00
SCREEN_OFF=22:00
SCREEN_DAYS='Mon Tue Wed Thu Fri Sat Sun'
USE_CEC=0
PRIVATE_MODE=0
HIDE_CURSOR=1
SAFE_GRAPHICS=1
NETWORK_MODE=wifi
HOTSPOT_ENABLED=1
HOTSPOT_PASSWORD=kiosksetup
HOTSPOT_DELAY=2
ADMIN_PASSWORD=kiosk
EOF
fi
chown "$KIOSK_USER:$KIOSK_GROUP" /etc/kiosk/kiosk.conf
chmod 600 /etc/kiosk/kiosk.conf

# ---------- make sure this computer's name resolves (stops sudo warnings) ------
HN="$(hostname)"
if ! grep -qE "[[:space:]]${HN}([[:space:]]|\$)" /etc/hosts; then
  echo "127.0.1.1 ${HN}" >> /etc/hosts
fi

# ---------- invisible mouse pointer theme ------------------------------------
install -d /usr/share/icons/kiosk-hidden/cursors
cat > /usr/share/icons/kiosk-hidden/index.theme <<'EOF'
[Icon Theme]
Name=kiosk-hidden
Comment=Invisible mouse pointer for kiosks
EOF
python3 - <<'EOF'
import os, struct
d = "/usr/share/icons/kiosk-hidden/cursors"
# Xcursor file holding one fully transparent 1x1 image
data = (struct.pack("<4sIII", b"Xcur", 16, 0x10000, 1)
        + struct.pack("<III", 0xFFFD0002, 24, 28)
        + struct.pack("<9I", 36, 0xFFFD0002, 24, 1, 1, 1, 0, 0, 0)
        + struct.pack("<I", 0))
with open(os.path.join(d, "default"), "wb") as f:
    f.write(data)
names = '''left_ptr arrow top_left_arrow pointer hand hand1 hand2 pointing_hand text
xterm ibeam vertical-text crosshair cross tcross wait watch progress left_ptr_watch
half-busy not-allowed no-drop crossed_circle forbidden help question_arrow whats_this
move fleur all-scroll grab openhand grabbing closedhand dnd-move dnd-copy dnd-link
dnd-none dnd-ask copy alias context-menu cell plus col-resize row-resize ew-resize
ns-resize nesw-resize nwse-resize n-resize s-resize e-resize w-resize ne-resize
nw-resize se-resize sw-resize sb_h_double_arrow sb_v_double_arrow h_double_arrow
v_double_arrow size_hor size_ver size_bdiag size_fdiag size_all top_side bottom_side
left_side right_side top_left_corner top_right_corner bottom_left_corner
bottom_right_corner zoom-in zoom-out center_ptr draft pencil right_ptr'''.split()
for n in names:
    p = os.path.join(d, n)
    if os.path.lexists(p):
        os.remove(p)
    os.symlink("default", p)
EOF

# ---------- welcome page ------------------------------------------------------
install -d -o "$KIOSK_USER" -g "$KIOSK_GROUP" "$PAGES_DIR/welcome"
cat > "$PAGES_DIR/welcome/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kiosk Ready</title>
<style>
  html,body{margin:0;height:100%;background:#0f1419;color:#e8eaed;
    font-family:system-ui,-apple-system,"Segoe UI",Roboto,"DejaVu Sans",sans-serif}
  .wrap{height:100%;display:flex;flex-direction:column;align-items:center;
    justify-content:center;text-align:center;padding:24px;box-sizing:border-box}
  .dot{width:18px;height:18px;border-radius:50%;background:#3fb950;
    box-shadow:0 0 24px #3fb950;margin-bottom:28px}
  h1{font-size:44px;margin:0 0 12px;font-weight:600}
  p{font-size:22px;color:#9aa3ae;margin:6px 0;line-height:1.4}
  .addr{font-size:30px;color:#58a6ff;margin:28px 0 8px;word-break:break-all}
  .small{font-size:18px}
  .clock{position:fixed;bottom:28px;font-size:20px;color:#6e7681}
</style>
</head>
<body>
<div class="wrap">
  <div class="dot"></div>
  <h1>Kiosk is ready</h1>
  <p>To choose what shows on this screen, open this address<br>on a phone or computer on the same network:</p>
  <div class="addr" id="addr">http://&lt;this-computer&gt;:8080</div>
  <p class="small" id="alt"></p>
  <p class="small" id="pw"></p>
  <div class="clock" id="clock"></div>
</div>
<script>
  fetch('/api/info').then(r => r.json()).then(d => {
    const ip = d.ips && d.ips.length ? d.ips[0] : null;
    document.getElementById('addr').textContent =
      'http://' + (ip || d.hostname + '.local') + ':' + d.port;
    document.getElementById('alt').textContent =
      'or  http://' + d.hostname + '.local:' + d.port;
    if (d.default_password) {
      document.getElementById('pw').textContent = 'Default password: kiosk  (please change it)';
    }
  }).catch(() => {});
  function tick(){ document.getElementById('clock').textContent = new Date().toLocaleString(); }
  tick(); setInterval(tick, 1000);
</script>
</body>
</html>
EOF
chown -R "$KIOSK_USER:$KIOSK_GROUP" "$PAGES_DIR"

# ---------- kiosk-session: runs inside labwc ----------------------------------
cat > /usr/local/bin/kiosk-session <<'EOF'
#!/usr/bin/env bash
# Started by labwc. Applies display settings, runs the idle watcher and
# screen schedule, and keeps Chromium running on the home page.
CONF=/etc/kiosk/kiosk.conf
STATE="$HOME/.local/state/kiosk"
PROFILE="$HOME/.kiosk-chromium"
mkdir -p "$STATE"

exec 8>"$STATE/session.lock"
flock -n 8 || exit 0

CHROME="$(command -v chromium || command -v chromium-browser || true)"

log(){ echo "$(date '+%F %T') $*" >> "$STATE/session.log"; }

trim_log(){
  local f="$1"
  if [ -f "$f" ] && [ "$(stat -c%s "$f")" -gt 5000000 ]; then : > "$f"; fi
}

load_conf(){
  HOME_URL="http://localhost:__PORT__/pages/welcome/index.html"
  IDLE_MINUTES=5; ROTATION=90; SCALE=1; OUTPUT=auto; PRIVATE_MODE=0; SAFE_GRAPHICS=1
  # shellcheck disable=SC1090
  [ -r "$CONF" ] && . "$CONF"
}

detect_output(){
  if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "auto" ]; then
    echo "$OUTPUT"; return
  fi
  wlr-randr 2>/dev/null | awk '/^[^[:space:]]/{print $1; exit}'
}

transform(){
  case "$ROTATION" in 90|180|270) echo "$ROTATION" ;; *) echo normal ;; esac
}

write_rcxml(){
  local out="$1" rc="$HOME/.config/labwc/rc.xml" tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<XML
<?xml version="1.0"?>
<labwc_config>
  <core>
    <gap>0</gap>
  </core>
  <!-- Kiosk shortcuts. Because these are defined, labwc's default shortcuts
       (close window, app menu, etc.) are not loaded.
       Ctrl+Alt+S = settings page on this screen, Ctrl+Alt+H = home page,
       Ctrl+Alt+W = setup hotspot on/off.
       Ctrl+Alt+F2 = text login, Ctrl+Alt+F1 = back to the kiosk. -->
  <keyboard>
    <keybind key="C-A-s">
      <action name="Execute" command="/usr/local/bin/kiosk-open-settings"/>
    </keybind>
    <keybind key="C-A-w">
      <action name="Execute" command="/usr/local/bin/kiosk-hotspot-toggle"/>
    </keybind>
    <keybind key="C-A-h">
      <action name="Execute" command="/usr/local/bin/kiosk-home --force"/>
    </keybind>
    <keybind key="W-A-h">
      <action name="Execute" command="/usr/local/bin/kiosk-home --force"/>
    </keybind>
  </keyboard>
  <mouse>
    <context name="Client">
      <mousebind button="Left" action="Press"><action name="Focus"/></mousebind>
    </context>
  </mouse>
  <!-- Map the touchscreen to the display so touches follow the rotation -->
  <touch mapToOutput="${out}" mouseEmulation="no"/>
</labwc_config>
XML
  if ! cmp -s "$tmp" "$rc"; then
    mv "$tmp" "$rc"
    labwc --reconfigure >/dev/null 2>&1 || true
    log "Touch input mapped to $out"
  else
    rm -f "$tmp"
  fi
}

apply_display(){
  local out="" i
  for i in $(seq 1 30); do
    out="$(detect_output)"
    [ -n "$out" ] && break
    sleep 1
  done
  if [ -z "$out" ]; then
    log "No display output found"
    return
  fi
  echo "$out" > "$STATE/output"
  write_rcxml "$out"
  if ! wlr-randr --output "$out" --transform "$(transform)" --scale "${SCALE:-1}" >>"$STATE/session.log" 2>&1; then
    log "wlr-randr could not apply rotation/scale to $out"
  fi
}

start_idle(){
  pkill -u "$(id -u)" -x swayidle 2>/dev/null
  rm -f "$STATE/active"
  local m="${IDLE_MINUTES:-0}"
  [[ "$m" =~ ^[0-9]+$ ]] || return 0
  [ "$m" -gt 0 ] || return 0
  swayidle -w \
    timeout $((m * 60)) '/usr/local/bin/kiosk-home' \
    resume "touch '$STATE/active'" >/dev/null 2>&1 &
}

wait_for_url(){
  local i
  case "$1" in
    http://localhost*|http://127.0.0.1*)
      for i in $(seq 1 30); do
        curl -s -o /dev/null --max-time 2 "$1" && return
        sleep 1
      done
      ;;
    http://*|https://*)
      # Wait for the network so the page does not open on an error screen
      for i in $(seq 1 60); do
        ip route 2>/dev/null | grep -q '^default' && return
        sleep 1
      done
      log "No network after 60s, opening page anyway"
      ;;
  esac
}

clean_prefs(){
  local p="$PROFILE/Default/Preferences"
  [ -f "$p" ] && sed -i \
    -e 's/"exited_cleanly":false/"exited_cleanly":true/' \
    -e 's/"exit_type":"[^"]*"/"exit_type":"Normal"/' "$p"
}

clear_stale_lock(){
  # Chromium refuses to start if its lock file names another host (e.g. after
  # the computer was renamed) or a crashed process. Only remove it when no
  # kiosk Chromium is actually running.
  if ! pgrep -u "$(id -u)" -f -- "--user-data-dir=$PROFILE" >/dev/null 2>&1; then
    rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonSocket" "$PROFILE/SingletonCookie"
  fi
}

if [ -z "$CHROME" ]; then
  log "Chromium is not installed"
  exit 1
fi

/usr/local/bin/kiosk-screen &

fails=0
while true; do
  load_conf
  URL="$HOME_URL"
  if [ -f "$STATE/open_settings" ]; then
    rm -f "$STATE/open_settings"          # Ctrl+Alt+S: show settings once
    URL="http://localhost:__PORT__/"
  elif [ -f /run/kiosk-net/hotspot ]; then
    if grep -q '^MODE=manual' /run/kiosk-net/hotspot; then
      # Ctrl+Alt+W setup hotspot: show the steps once, then the normal pages
      if [ /run/kiosk-net/hotspot -nt "$STATE/setup_shown" ]; then
        touch "$STATE/setup_shown"
        URL="http://localhost:__PORT__/setup"
      fi
    else
      URL="http://localhost:__PORT__/setup"  # lost network: show the steps
    fi
  fi
  apply_display
  start_idle
  wait_for_url "$URL"
  clean_prefs
  clear_stale_lock
  trim_log "$STATE/chromium.log"
  trim_log "$STATE/session.log"

  args=(
    --kiosk
    --user-data-dir="$PROFILE"
    --ozone-platform=wayland
    --no-first-run
    --noerrdialogs
    --disable-infobars
    --disable-session-crashed-bubble
    --disable-features=Translate,TranslateUI,MediaRouter
    --check-for-update-interval=31536000
    --disable-component-update
    --overscroll-history-navigation=0
    --disable-pinch
    --autoplay-policy=no-user-gesture-required
    --password-store=basic
  )
  [ "$PRIVATE_MODE" = "1" ] && args+=(--incognito)
  # Graphics compatibility mode: fixes a blank white page on some Pi/GPU setups
  [ "$SAFE_GRAPHICS" = "1" ] && args+=(--disable-gpu-compositing)

  log "Starting browser: $URL"
  started=$(date +%s)
  "$CHROME" "${args[@]}" "$URL" >>"$STATE/chromium.log" 2>&1
  # Normal restarts (idle reset, settings change) relaunch right away.
  # If Chromium keeps dying within seconds, back off instead of looping.
  if [ $(( $(date +%s) - started )) -lt 10 ]; then
    fails=$((fails + 1))
    [ "$fails" -eq 5 ] && log "Browser keeps exiting right away - see chromium.log"
    sleep $(( fails < 15 ? fails * 2 : 30 ))
  else
    fails=0
    sleep 1
  fi
done
EOF

# ---------- kiosk-home: go back to the home page -------------------------------
cat > /usr/local/bin/kiosk-home <<'EOF'
#!/usr/bin/env bash
# Return the kiosk to its home page by restarting Chromium.
#   kiosk-home          -> only if someone used the screen since the last reset
#   kiosk-home --force  -> always
STATE="$HOME/.local/state/kiosk"
PROFILE="$HOME/.kiosk-chromium"
ME="$(id -u)"

if [ "${1:-}" != "--force" ]; then
  [ -f "$STATE/active" ] || exit 0
fi
rm -f "$STATE/active"

pkill -o -u "$ME" -f -- "--user-data-dir=$PROFILE" || exit 0
for _ in 1 2 3 4 5 6; do
  pgrep -u "$ME" -f -- "--user-data-dir=$PROFILE" >/dev/null || exit 0
  sleep 0.5
done
pkill -9 -u "$ME" -f -- "--user-data-dir=$PROFILE"
exit 0
EOF

# ---------- kiosk-screen: on/off schedule ------------------------------------
cat > /usr/local/bin/kiosk-screen <<'EOF'
#!/usr/bin/env bash
# Turns the display on/off based on the schedule in /etc/kiosk/kiosk.conf.
# A manual on/off from the settings page lasts until the next scheduled change.
CONF=/etc/kiosk/kiosk.conf
STATE="$HOME/.local/state/kiosk"
mkdir -p "$STATE"

exec 9>"$STATE/screen.lock"
flock -n 9 || exit 0

log(){ echo "$(date '+%F %T') $*" >> "$STATE/session.log"; }

load_conf(){
  SCHEDULE_ENABLED=0; SCREEN_ON=06:00; SCREEN_OFF=22:00
  SCREEN_DAYS="Mon Tue Wed Thu Fri Sat Sun"; USE_CEC=0; ROTATION=90; SCALE=1
  # shellcheck disable=SC1090
  [ -r "$CONF" ] && . "$CONF"
}

transform(){
  case "$ROTATION" in 90|180|270) echo "$ROTATION" ;; *) echo normal ;; esac
}

scheduled_state(){
  [ "$SCHEDULE_ENABLED" = "1" ] || { echo on; return; }
  [[ "$SCREEN_ON"  =~ ^[0-9]{2}:[0-9]{2}$ ]] || { echo on; return; }
  [[ "$SCREEN_OFF" =~ ^[0-9]{2}:[0-9]{2}$ ]] || { echo on; return; }

  local now on off day d today=0
  now=$((10#$(date +%H%M)))
  on=$((10#${SCREEN_ON//:/}))
  off=$((10#${SCREEN_OFF//:/}))
  day="$(LC_ALL=C date +%a)"

  for d in $SCREEN_DAYS; do [ "$d" = "$day" ] && today=1; done
  [ "$today" = "1" ] || { echo off; return; }

  if [ "$on" -eq "$off" ]; then
    echo on
  elif [ "$on" -lt "$off" ]; then
    if (( now >= on && now < off )); then echo on; else echo off; fi
  else
    # Overnight span, e.g. on 18:00, off 02:00
    if (( now >= on || now < off )); then echo on; else echo off; fi
  fi
}

set_screen(){
  local want="$1" out done_it=0
  out="$(cat "$STATE/output" 2>/dev/null)"

  if command -v wlopm >/dev/null 2>&1; then
    wlopm --"$want" "${out:-*}" >/dev/null 2>&1 && done_it=1
  fi
  if [ "$done_it" = "0" ] && [ -n "$out" ]; then
    if [ "$want" = "off" ]; then
      wlr-randr --output "$out" --off >/dev/null 2>&1
    else
      wlr-randr --output "$out" --on --transform "$(transform)" --scale "${SCALE:-1}" >/dev/null 2>&1
    fi
  fi

  if [ "$USE_CEC" = "1" ] && command -v cec-ctl >/dev/null 2>&1; then
    for dev in /dev/cec*; do
      [ -e "$dev" ] || continue
      cec-ctl -d "$dev" --playback >/dev/null 2>&1
      if [ "$want" = "off" ]; then
        cec-ctl -d "$dev" --to 0 --standby >/dev/null 2>&1
      else
        cec-ctl -d "$dev" --to 0 --image-view-on >/dev/null 2>&1
      fi
    done
  fi

  echo "$want" > "$STATE/screen_state"
  log "Screen $want"
}

last=""
while true; do
  load_conf
  sched="$(scheduled_state)"
  want="$sched"

  if [ -f "$STATE/override" ]; then
    read -r ov base < "$STATE/override"
    if [[ "$ov" != "on" && "$ov" != "off" ]]; then
      rm -f "$STATE/override"
    else
      if [ -z "$base" ]; then
        echo "$ov $sched" > "$STATE/override"
        base="$sched"
      fi
      if [ "$base" = "$sched" ]; then
        want="$ov"
      else
        rm -f "$STATE/override"   # schedule changed, return to schedule
      fi
    fi
  fi

  if [ "$want" != "$last" ]; then
    set_screen "$want"
    last="$want"
  fi
  sleep 5
done
EOF

# ---------- kiosk-open-settings: Ctrl+Alt+S ------------------------------------
cat > /usr/local/bin/kiosk-open-settings <<'EOF'
#!/usr/bin/env bash
# Show the settings page on the kiosk screen (the next idle reset returns home).
STATE="$HOME/.local/state/kiosk"
mkdir -p "$STATE"
touch "$STATE/open_settings"
exec /usr/local/bin/kiosk-home --force
EOF

# ---------- kiosk-hotspot-toggle: Ctrl+Alt+W ----------------------------------
cat > /usr/local/bin/kiosk-hotspot-toggle <<'EOF'
#!/usr/bin/env bash
# Ask kiosk-netwatch to turn the setup hotspot on or off.
STATE="$HOME/.local/state/kiosk"
mkdir -p "$STATE"
echo toggle > "$STATE/hotspot_request"
EOF

# ---------- kiosk-netwatch: Wi-Fi mode, offline mode, setup hotspot (root) -----
cat > /usr/local/bin/kiosk-netwatch <<'EOF'
#!/usr/bin/env bash
# Kiosk network helper (runs as root).
#
#  Network mode "wifi"    : joins saved Wi-Fi. If there is no network for a few
#                           minutes, starts a backup setup hotspot (if enabled).
#  Network mode "offline" : never joins Wi-Fi (wired Ethernet is left alone).
#
#  Ctrl+Alt+W on the kiosk (any mode) turns a setup hotspot on or off so a
#  phone can connect and use the settings page. A setup hotspot turns itself
#  off after 30 minutes with no phone connected.
CONF=/etc/kiosk/kiosk.conf
RUN=/run/kiosk-net
KUSER="__KUSER__"
KHOME="__KHOME__"
KSTATE="$KHOME/.local/state/kiosk"
HOLD="$KSTATE/wifi_hold"
REQ="$KSTATE/hotspot_request"
CON=KioskHotspot
RETRY=600            # backup hotspot: retry saved Wi-Fi every 10 minutes
MANUAL_TIMEOUT=1800  # setup hotspot: off after 30 minutes with no phone
mkdir -p "$RUN"
chmod 755 "$RUN"

log(){ echo "$(date '+%F %T') $*" >> "$RUN/netwatch.log"; }

# Read one value from the settings file without running it as root
getconf(){
  local v
  v="$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1)"
  v="${v#\'}"; v="${v%\'}"
  echo "${v:-$2}"
}

online(){ [ -n "$(ip -4 route show default 2>/dev/null)" ]; }
wifi_dev(){ nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}'; }
hotspot_active(){ nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$CON"; }
has_saved_wifi(){ nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ':802-11-wireless$' | grep -qv "^$CON:"; }
wifi_client_on(){
  [ -n "$DEV" ] && nmcli -t -f DEVICE,STATE,CONNECTION device 2>/dev/null \
    | awk -F: -v d="$DEV" -v h="$CON" '$1==d && $2 ~ /^connect/ && $3!=h {f=1} END{exit !f}'
}
clients_on_hotspot(){ command -v iw >/dev/null 2>&1 && iw dev "$DEV" station dump 2>/dev/null | grep -q '^Station'; }
held(){ [ -f "$HOLD" ] && [ $(( $(date +%s) - $(stat -c %Y "$HOLD") )) -lt 180 ]; }
notify_kiosk(){ runuser -u "$KUSER" -- env HOME="$KHOME" /usr/local/bin/kiosk-home --force >/dev/null 2>&1 || true; }

start_hotspot(){   # $1 = auto | manual
  local ssid pw addr
  ssid="Kiosk-$(hostname)"
  pw="$(getconf HOTSPOT_PASSWORD kiosksetup)"
  [[ "$pw" =~ ^[A-Za-z0-9]{8,63}$ ]] || pw=kiosksetup
  # Remember nearby networks - the radio cannot scan well while it is a hotspot
  nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan yes > "$RUN/scan.tmp" 2>/dev/null \
    && mv "$RUN/scan.tmp" "$RUN/scan.txt"
  nmcli connection delete "$CON" >/dev/null 2>&1
  if nmcli device wifi hotspot ifname "$DEV" con-name "$CON" ssid "$ssid" password "$pw" >/dev/null 2>&1; then
    nmcli connection modify "$CON" connection.autoconnect no >/dev/null 2>&1
    sleep 2
    addr="$(ip -4 -o addr show dev "$DEV" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
    printf 'SSID=%s\nPASSWORD=%s\nADDRESS=%s\nMODE=%s\n' "$ssid" "$pw" "${addr:-10.42.0.1}" "$1" > "$RUN/hotspot"
    log "Hotspot started ($1): $ssid"
    notify_kiosk
    return 0
  fi
  log "Could not start hotspot on $DEV"
  return 1
}

stop_hotspot(){
  nmcli connection down "$CON" >/dev/null 2>&1
  rm -f "$RUN/hotspot"
}

resume_wifi(){     # after a hotspot: rejoin saved Wi-Fi, unless in offline mode
  if [ "$(getconf NETWORK_MODE wifi)" = wifi ] && [ -n "$DEV" ]; then
    nmcli --wait 45 device connect "$DEV" >/dev/null 2>&1
  fi
}

rm -f "$RUN/hotspot"
offline_since=0
last_try=0
manual=0
manual_since=0
prev_mode=""
sleep 10
while true; do
  now=$(date +%s)
  DEV="$(wifi_dev)"
  mode="$(getconf NETWORK_MODE wifi)"
  enabled="$(getconf HOTSPOT_ENABLED 1)"
  delay="$(getconf HOTSPOT_DELAY 2)"
  [[ "$delay" =~ ^[0-9]+$ ]] || delay=2

  if held; then                      # settings page is switching networks
    sleep 3
    continue
  fi

  # ---- Ctrl+Alt+W / "Turn off" button requests ----
  req=""
  if [ -f "$REQ" ]; then
    req="$(head -c 20 "$REQ")"
    rm -f "$REQ"
  fi
  if [ "$req" = toggle ]; then
    if hotspot_active; then req=off; else req=on; fi
  fi
  if [ "$req" = on ] && [ -n "$DEV" ]; then
    if start_hotspot manual; then manual=1; manual_since=$now; fi
    sleep 3
    continue
  fi
  if [ "$req" = off ] && { hotspot_active || [ -f "$RUN/hotspot" ]; }; then
    stop_hotspot
    log "Hotspot turned off by request"
    manual=0
    notify_kiosk
    resume_wifi
    sleep 3
    continue
  fi

  # ---- setup hotspot started with Ctrl+Alt+W ----
  if [ "$manual" = 1 ]; then
    if ! hotspot_active; then
      manual=0
      rm -f "$RUN/hotspot"
      log "Setup hotspot ended"
      notify_kiosk
      resume_wifi
    elif clients_on_hotspot; then
      manual_since=$now                # keep it on while a phone is connected
    elif [ $(( now - manual_since )) -ge $MANUAL_TIMEOUT ]; then
      stop_hotspot
      manual=0
      log "Setup hotspot timed out"
      notify_kiosk
      resume_wifi
    fi
    sleep 3
    continue
  fi

  # ---- offline mode: keep Wi-Fi off ----
  if [ "$mode" = offline ]; then
    [ "$prev_mode" != offline ] && log "Offline mode"
    prev_mode=offline
    if hotspot_active || [ -f "$RUN/hotspot" ]; then
      stop_hotspot
      notify_kiosk
    fi
    if wifi_client_on; then
      nmcli device disconnect "$DEV" >/dev/null 2>&1   # also stops auto-reconnect
      log "Wi-Fi disconnected (offline mode)"
    fi
    offline_since=0
    sleep 5
    continue
  fi
  if [ "$prev_mode" = offline ]; then
    log "Wi-Fi mode"
    resume_wifi
  fi
  prev_mode=wifi

  # ---- Wi-Fi mode ----
  if online; then
    if [ "$offline_since" != 0 ]; then log "Network is up"; offline_since=0; fi
    if hotspot_active || [ -f "$RUN/hotspot" ]; then
      stop_hotspot
      log "Backup hotspot stopped - network is up"
      notify_kiosk
    fi
  elif hotspot_active; then
    if [ "$enabled" != 1 ]; then
      stop_hotspot
      log "Backup hotspot turned off in settings"
      notify_kiosk
      resume_wifi
    elif has_saved_wifi && [ $(( now - last_try )) -ge $RETRY ] && ! clients_on_hotspot; then
      log "Retrying saved Wi-Fi"
      last_try=$now
      stop_hotspot
      nmcli --wait 45 device connect "$DEV" >/dev/null 2>&1
      if online; then
        log "Reconnected"
        offline_since=0
        notify_kiosk
      else
        start_hotspot auto
      fi
    fi
  else
    if [ -f "$RUN/hotspot" ]; then   # hotspot went away on its own
      rm -f "$RUN/hotspot"
      notify_kiosk
    fi
    if [ "$offline_since" = 0 ]; then offline_since=$now; log "No network"; fi
    if [ "$enabled" = 1 ] && [ -n "$DEV" ] && [ $(( now - offline_since )) -ge $(( delay * 60 )) ]; then
      start_hotspot auto
      last_try=$now
    fi
  fi
  sleep 5
done
EOF

sed -i "s/__PORT__/${ADMIN_PORT}/g" /usr/local/bin/kiosk-session
sed -i -e "s#__KUSER__#${KIOSK_USER}#" -e "s#__KHOME__#${KIOSK_HOME}#" /usr/local/bin/kiosk-netwatch
chmod 755 /usr/local/bin/kiosk-session /usr/local/bin/kiosk-home /usr/local/bin/kiosk-screen \
  /usr/local/bin/kiosk-open-settings /usr/local/bin/kiosk-netwatch /usr/local/bin/kiosk-hotspot-toggle

cat > /etc/systemd/system/kiosk-netwatch.service <<'EOF'
[Unit]
Description=Kiosk network mode and setup hotspot
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
ExecStart=/usr/local/bin/kiosk-netwatch
Restart=always
RestartSec=5
RuntimeDirectory=kiosk-net
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

# ---------- settings web page (Python, no extra packages) ---------------------
cat > /opt/kiosk/kiosk-admin.py <<'PYEOF'
#!/usr/bin/env python3
"""Kiosk settings web page. Serves the settings UI (password protected)
and the local kiosk pages folder at /pages/ (open, for the kiosk browser)."""
import base64
import hmac
import json
import mimetypes
import os
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = os.environ.get("KIOSK_CONF", "/etc/kiosk/kiosk.conf")
PAGES = os.environ.get("KIOSK_PAGES", os.path.expanduser("~/kiosk-pages"))
STATE = os.environ.get("KIOSK_STATE", os.path.expanduser("~/.local/state/kiosk"))
PORT = int(os.environ.get("KIOSK_PORT", "8080"))
MAX_UPLOAD = 500 * 1024 * 1024          # per file
MAX_UNZIP = 2 * 1024 * 1024 * 1024      # total size of a zip once unpacked
PROTECTED = {"welcome"}                 # built-in folders that cannot be deleted
DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
SKIP_NAMES = {"__MACOSX", "Thumbs.db", "desktop.ini"}

DEFAULTS = {
    "HOME_URL": f"http://localhost:{PORT}/pages/welcome/index.html",
    "IDLE_MINUTES": "5",
    "ROTATION": "90",
    "SCALE": "1",
    "OUTPUT": "auto",
    "SCHEDULE_ENABLED": "0",
    "SCREEN_ON": "06:00",
    "SCREEN_OFF": "22:00",
    "SCREEN_DAYS": " ".join(DAYS),
    "USE_CEC": "0",
    "PRIVATE_MODE": "0",
    "HIDE_CURSOR": "1",
    "SAFE_GRAPHICS": "1",
    "NETWORK_MODE": "wifi",
    "HOTSPOT_ENABLED": "1",
    "HOTSPOT_PASSWORD": "kiosksetup",
    "HOTSPOT_DELAY": "2",
    "ADMIN_PASSWORD": "kiosk",
}
NET_RUN = "/run/kiosk-net"
HOTSPOT_CON = "KioskHotspot"
TIMEZONES = [
    "America/New_York", "America/Chicago", "America/Denver", "America/Phoenix",
    "America/Los_Angeles", "America/Anchorage", "Pacific/Honolulu", "UTC",
]


# ---------------------------------------------------------------- config ----
def read_conf():
    conf = dict(DEFAULTS)
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                key = key.strip()
                if key in conf:
                    try:
                        parts = shlex.split(val)
                        conf[key] = parts[0] if parts else ""
                    except ValueError:
                        conf[key] = val
    except FileNotFoundError:
        pass
    return conf


def write_conf(conf):
    tmp = CONF + ".tmp"
    with open(tmp, "w") as f:
        f.write("# Kiosk settings - normally edited from the web settings page\n")
        for key in DEFAULTS:
            f.write(f"{key}={shlex.quote(str(conf.get(key, DEFAULTS[key])))}\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONF)


def validate(data, current):
    conf = dict(current)

    url = str(data.get("HOME_URL", "")).strip()
    if not re.match(r"^(https?|file)://\S+$", url) or len(url) > 2000:
        raise ValueError("Home page must start with http://, https:// or file://")
    conf["HOME_URL"] = url

    try:
        idle = int(data.get("IDLE_MINUTES", 0))
    except (TypeError, ValueError):
        raise ValueError("Idle minutes must be a number")
    if not 0 <= idle <= 1440:
        raise ValueError("Idle minutes must be between 0 and 1440")
    conf["IDLE_MINUTES"] = str(idle)

    rot = str(data.get("ROTATION", "0"))
    if rot not in ("0", "90", "180", "270"):
        raise ValueError("Rotation must be 0, 90, 180 or 270")
    conf["ROTATION"] = rot

    try:
        scale = float(data.get("SCALE", 1))
    except (TypeError, ValueError):
        raise ValueError("Scale must be a number")
    if not 0.5 <= scale <= 3:
        raise ValueError("Scale must be between 0.5 and 3")
    conf["SCALE"] = f"{scale:g}"

    out = str(data.get("OUTPUT", "auto")).strip() or "auto"
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", out):
        raise ValueError("Display output name is not valid")
    conf["OUTPUT"] = out

    for key in ("SCHEDULE_ENABLED", "USE_CEC", "PRIVATE_MODE", "HIDE_CURSOR", "SAFE_GRAPHICS",
                "HOTSPOT_ENABLED"):
        conf[key] = "1" if str(data.get(key, "0")) in ("1", "true", "True") else "0"

    for key in ("SCREEN_ON", "SCREEN_OFF"):
        t = str(data.get(key, "")).strip()
        if not re.fullmatch(r"([01]\d|2[0-3]):([0-5]\d)", t):
            raise ValueError("Times must be HH:MM (24-hour)")
        conf[key] = t

    days = data.get("SCREEN_DAYS", [])
    if isinstance(days, str):
        days = days.split()
    conf["SCREEN_DAYS"] = " ".join(d for d in DAYS if d in days)

    mode = str(data.get("NETWORK_MODE", conf["NETWORK_MODE"]))
    if mode not in ("wifi", "offline"):
        raise ValueError("Network mode must be wifi or offline")
    conf["NETWORK_MODE"] = mode

    hp = str(data.get("HOTSPOT_PASSWORD", conf["HOTSPOT_PASSWORD"]) or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9]{8,63}", hp):
        raise ValueError("Hotspot password must be 8-63 letters or numbers")
    conf["HOTSPOT_PASSWORD"] = hp
    try:
        delay = int(data.get("HOTSPOT_DELAY", conf["HOTSPOT_DELAY"]))
    except (TypeError, ValueError):
        raise ValueError("Hotspot delay must be a number of minutes")
    if not 1 <= delay <= 60:
        raise ValueError("Hotspot delay must be 1 to 60 minutes")
    conf["HOTSPOT_DELAY"] = str(delay)

    pw = str(data.get("NEW_PASSWORD", "") or "")
    if pw:
        if len(pw) < 4 or len(pw) > 64 or re.search(r"\s", pw):
            raise ValueError("Password must be 4-64 characters with no spaces")
        conf["ADMIN_PASSWORD"] = pw
    return conf


# ----------------------------------------------------------------- files ----
BAD_CHARS = re.compile(r"[\x00-\x1f\x7f\\]")


def clean_rel(rel, allow_root=True):
    """Normalise a path inside the pages folder. Rejects '..', hidden names, etc."""
    rel = (rel or "").replace("\\", "/").strip().strip("/")
    if not rel:
        if allow_root:
            return ""
        raise ValueError("No file name given")
    parts = rel.split("/")
    for p in parts:
        if p in ("", ".", "..") or p.startswith(".") or len(p) > 150 or BAD_CHARS.search(p):
            raise ValueError(f"Unsupported name: {p or '(empty)'}")
    return "/".join(parts)


def safe_join(root, rel):
    root = os.path.realpath(root)
    full = os.path.realpath(os.path.join(root, rel))
    if full != root and not full.startswith(root + os.sep):
        raise ValueError("Bad path")
    return full


def is_page(name):
    return name.lower().endswith((".html", ".htm"))


def find_index(folder_full):
    for cand in ("index.html", "index.htm", "Index.html", "INDEX.HTML"):
        if os.path.isfile(os.path.join(folder_full, cand)):
            return cand
    return None


def browse(rel):
    rel = clean_rel(rel)
    full = safe_join(PAGES, rel)
    if not os.path.isdir(full):
        raise ValueError("Folder not found")
    entries = []
    for name in os.listdir(full):
        if name.startswith(".") or name in SKIP_NAMES:
            continue
        p = os.path.join(full, name)
        child = f"{rel}/{name}" if rel else name
        if os.path.isdir(p):
            try:
                count = len([n for n in os.listdir(p) if not n.startswith(".")])
            except OSError:
                count = 0
            entries.append({"name": name, "path": child, "type": "dir",
                            "index": find_index(p), "count": count,
                            "protected": child in PROTECTED})
        elif os.path.isfile(p):
            st = os.stat(p)
            entries.append({"name": name, "path": child, "type": "file",
                            "size": st.st_size, "page": is_page(name)})
    entries.sort(key=lambda e: (e["type"] != "dir", e["name"].lower()))
    return {"path": rel, "entries": entries}


def make_dir(rel):
    rel = clean_rel(rel, allow_root=False)
    full = safe_join(PAGES, rel)
    if os.path.exists(full):
        raise ValueError("That name is already used")
    os.makedirs(full)
    return rel


def delete_path(rel):
    rel = clean_rel(rel, allow_root=False)
    if rel in PROTECTED:
        raise ValueError("The built-in welcome page cannot be deleted")
    full = safe_join(PAGES, rel)
    if os.path.isdir(full):
        shutil.rmtree(full)
    elif os.path.exists(full):
        os.remove(full)
    else:
        raise ValueError("Not found")


def extract_zip(zip_path, folder):
    """Unpack a zip into PAGES/folder (replacing that folder). Returns index page path."""
    folder = clean_rel(folder, allow_root=False)
    if folder in PROTECTED:
        raise ValueError("Pick a different name - that folder is built in")
    dest = safe_join(PAGES, folder)
    try:
        zf = zipfile.ZipFile(zip_path)
    except zipfile.BadZipFile:
        raise ValueError("That .zip file could not be opened")
    with zf:
        members = []
        for info in zf.infolist():
            if info.is_dir():
                continue
            name = info.filename.replace("\\", "/")
            if any(part in SKIP_NAMES for part in name.split("/")):
                continue
            try:
                name = clean_rel(name, allow_root=False)
            except ValueError:
                continue  # hidden files like .DS_Store, odd names
            members.append((info, name))
        if not members:
            raise ValueError("The .zip file has no usable files")
        if sum(i.file_size for i, _ in members) > MAX_UNZIP:
            raise ValueError("The .zip file is too large once unpacked")
        # If everything sits inside one top folder, unpack its contents directly
        tops = {n.split("/", 1)[0] for _, n in members}
        strip = len(tops) == 1 and all("/" in n for _, n in members)
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        elif os.path.exists(dest):
            os.remove(dest)
        os.makedirs(dest)
        for info, name in members:
            rel = name.split("/", 1)[1] if strip else name
            target = safe_join(dest, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with zf.open(info) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
    idx = find_index(dest)
    if idx:
        return f"{folder}/{idx}"
    for dirpath, dirs, files in os.walk(dest):
        dirs.sort()
        for name in sorted(files):
            if is_page(name):
                return f"{folder}/" + os.path.relpath(os.path.join(dirpath, name), dest).replace(os.sep, "/")
    return None


# ---------------------------------------------------------------- status ----
def local_ips():
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ips.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return ips


def read_state(name, default=""):
    try:
        with open(os.path.join(STATE, name)) as f:
            return f.read().strip()
    except OSError:
        return default


def get_timezone():
    try:
        out = subprocess.run(["timedatectl", "show", "-p", "Timezone", "--value"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        if out:
            return out
    except Exception:
        pass
    real = os.path.realpath("/etc/localtime")
    return real.split("zoneinfo/", 1)[1] if "zoneinfo/" in real else "UTC"


def set_timezone(tz):
    tz = str(tz or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}", tz) \
            or not os.path.isfile(os.path.join("/usr/share/zoneinfo", tz)):
        raise ValueError("Unknown time zone")
    if tz == get_timezone():
        return
    r = subprocess.run(["sudo", "-n", "/usr/bin/timedatectl", "set-timezone", tz],
                       capture_output=True, text=True, timeout=15)
    if r.returncode != 0:
        raise ValueError("Could not change the time zone")
    time.tzset()


# ------------------------------------------------------------------ wifi ----
WIFI_LOCK = threading.Lock()


def nm(args, sudo=False, timeout=30):
    cmd = (["sudo", "-n", "/usr/bin/nmcli"] if sudo else ["nmcli"]) + list(args)
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        raise ValueError("NetworkManager (nmcli) is not installed")
    except subprocess.TimeoutExpired:
        raise ValueError("The network tool did not respond in time")


def split_terse(line):
    """Split nmcli -t output, which escapes ':' and '\\' with a backslash."""
    out, cur, esc = [], "", False
    for ch in line:
        if esc:
            cur += ch
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == ":":
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


def read_kv(path):
    try:
        with open(path) as f:
            return dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line)
    except OSError:
        return None


def hotspot_info():
    return read_kv(os.path.join(NET_RUN, "hotspot"))


def parse_scan(text):
    nets = {}
    for line in text.splitlines():
        f = split_terse(line)
        if len(f) < 4 or not f[1]:
            continue
        ssid, inuse = f[1], f[0].strip() == "*"
        try:
            sig = int(f[2])
        except ValueError:
            sig = 0
        sec = f[3].strip()
        cur = nets.get(ssid)
        if not cur or sig > cur["signal"]:
            nets[ssid] = {"ssid": ssid, "signal": sig, "secure": sec not in ("", "--"),
                          "inuse": inuse or bool(cur and cur["inuse"])}
        elif inuse:
            cur["inuse"] = True
    return sorted(nets.values(), key=lambda n: (not n["inuse"], -n["signal"], n["ssid"].lower()))


def write_wifi_result(state, message):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "wifi_result.json"), "w") as f:
        json.dump({"state": state, "message": message, "time": time.time()}, f)


def read_wifi_result():
    try:
        with open(os.path.join(STATE, "wifi_result.json")) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    if time.time() - d.get("time", 0) > 600:
        return None
    if d.get("state") == "connecting" and not WIFI_LOCK.locked():
        return None   # left over from before a restart
    return d


def wifi_status(rescan=False):
    hs = hotspot_info()
    out = {"hotspot": hs, "connections": [], "networks": [], "saved": [],
           "available": True, "cached": bool(hs), "result": read_wifi_result()}
    try:
        r = nm(["-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device"])
    except ValueError as e:
        out["available"] = False
        out["error"] = str(e)
        return out
    for line in r.stdout.splitlines():
        f = split_terse(line)
        if len(f) >= 4 and f[1] in ("wifi", "ethernet") and f[2].startswith("connected") \
                and f[3] != HOTSPOT_CON:
            out["connections"].append({"device": f[0], "type": f[1], "name": f[3]})
    if hs or WIFI_LOCK.locked():
        try:
            with open(os.path.join(NET_RUN, "scan.txt")) as fh:
                out["networks"] = parse_scan(fh.read())
        except OSError:
            pass
    else:
        r = nm(["-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list",
                "--rescan", "yes" if rescan else "auto"], sudo=rescan, timeout=40)
        out["networks"] = parse_scan(r.stdout)
    r = nm(["-t", "-f", "NAME,TYPE", "connection", "show"])
    for line in r.stdout.splitlines():
        f = split_terse(line)
        if len(f) >= 2 and f[1] == "802-11-wireless" and f[0] != HOTSPOT_CON:
            out["saved"].append(f[0])
    return out


def friendly_nm_error(text):
    t = text.lower()
    if "secrets were required" in t or "802-1x" in t or "psk" in t:
        return "Check the password."
    if "no network with ssid" in t:
        return "That network was not found - check the name, or tick Hidden network."
    if "timeout" in t or "timed out" in t:
        return "It took too long - the signal may be weak."
    return text


def _wifi_job(ssid, password, hidden):
    hold = os.path.join(STATE, "wifi_hold")
    try:
        open(hold, "w").close()
        write_wifi_result("connecting", f"Connecting to {ssid}…")
        if hotspot_info():
            nm(["connection", "down", HOTSPOT_CON], sudo=True, timeout=30)
            time.sleep(3)
        nm(["device", "wifi", "rescan"], sudo=True, timeout=20)
        time.sleep(4)
        nm(["connection", "delete", "id", ssid], sudo=True, timeout=20)  # replace old details
        args = ["--wait", "60", "device", "wifi", "connect", ssid]
        if password:
            args += ["password", password]
        if hidden:
            args += ["hidden", "yes"]
        r = nm(args, sudo=True, timeout=90)
        if r.returncode == 0:
            write_wifi_result("ok", f"Connected to {ssid}.")
        else:
            nm(["connection", "delete", "id", ssid], sudo=True, timeout=20)
            lines = (r.stderr or r.stdout).strip().splitlines()
            write_wifi_result("error", f"Could not connect to {ssid}. "
                              + friendly_nm_error(lines[-1] if lines else ""))
    except Exception as e:  # noqa: BLE001 - report anything to the page
        write_wifi_result("error", str(e))
    finally:
        try:
            os.remove(hold)
        except OSError:
            pass
        WIFI_LOCK.release()


def wifi_connect(data):
    ssid = str(data.get("ssid") or "")
    password = str(data.get("password") or "")
    if not ssid.strip() or len(ssid.encode()) > 32 or re.search(r"[\x00-\x1f]", ssid):
        raise ValueError("Network name must be 1-32 characters")
    if ssid == HOTSPOT_CON:
        raise ValueError("That name is reserved")
    if password and not 8 <= len(password) <= 63:
        raise ValueError("Wi-Fi passwords are 8 to 63 characters")
    if read_conf()["NETWORK_MODE"] == "offline":
        raise ValueError("The kiosk is in Offline mode. Set Network mode to Use Wi-Fi "
                         "and tap Save & apply first.")
    if not WIFI_LOCK.acquire(blocking=False):
        raise ValueError("Already connecting - please wait")
    threading.Thread(target=_wifi_job, args=(ssid, password, bool(data.get("hidden"))),
                     daemon=True).start()


def wifi_forget(name):
    if name not in wifi_status()["saved"]:
        raise ValueError("Not a saved network")
    r = nm(["connection", "delete", "id", name], sudo=True)
    if r.returncode != 0:
        raise ValueError("Could not remove that network")


def hotspot_off():
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "hotspot_request"), "w") as f:
        f.write("off\n")


def status():
    override = read_state("override").split()
    time.tzset()
    return {
        "hotspot": hotspot_info(),
        "time": time.strftime("%a %-I:%M %p"),
        "timezone": get_timezone(),
        "hostname": socket.gethostname(),
        "ips": local_ips(),
        "port": PORT,
        "output": read_state("output", "unknown"),
        "screen": read_state("screen_state", "on"),
        "override": override[0] if override else "",
    }


def kiosk_home():
    try:
        subprocess.Popen(["/usr/local/bin/kiosk-home", "--force"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass  # settings are saved either way; the kiosk picks them up on next restart


# ------------------------------------------------------------------- web ----
class Handler(BaseHTTPRequestHandler):
    server_version = "KioskAdmin/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, text, ctype="text/html; charset=utf-8", code=200):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        pw = read_conf()["ADMIN_PASSWORD"]
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            try:
                _, _, given = base64.b64decode(header[6:]).decode("utf-8").partition(":")
                if hmac.compare_digest(given.encode(), pw.encode()):
                    return True
            except Exception:
                pass
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Kiosk settings"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 1024 * 1024:
            raise ValueError("Request too large")
        body = self.rfile.read(n) if n else b""
        return json.loads(body or b"{}")

    def save_body(self, dest):
        """Stream the request body to a file (keeps memory low on small Pis)."""
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_UPLOAD:
            raise ValueError("File is too large (500 MB max per file)")
        remaining = n
        with open(dest, "wb") as f:
            while remaining > 0:
                chunk = self.rfile.read(min(256 * 1024, remaining))
                if not chunk:
                    raise ValueError("Upload was interrupted")
                f.write(chunk)
                remaining -= len(chunk)

    def handle_upload(self, query):
        rel = clean_rel(query.get("path", [""])[0], allow_root=False)
        extract = query.get("extract", ["0"])[0] == "1" and rel.lower().endswith(".zip")

        if extract:
            os.makedirs(STATE, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=STATE, suffix=".zip")
            os.close(fd)
            try:
                self.save_body(tmp)
                index = extract_zip(tmp, rel[:-4])
            finally:
                if os.path.exists(tmp):
                    os.remove(tmp)
            return {"ok": True, "path": rel[:-4], "index": index}

        if rel.split("/", 1)[0] in PROTECTED:
            raise ValueError("The built-in welcome folder cannot be changed")
        target = safe_join(PAGES, rel)
        if os.path.isdir(target):
            raise ValueError(f"A folder named '{os.path.basename(rel)}' already exists here")
        parent = os.path.dirname(target)
        os.makedirs(parent, exist_ok=True)
        tmp = os.path.join(parent, "." + os.path.basename(target) + ".part")
        try:
            self.save_body(tmp)
            os.replace(tmp, target)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
        return {"ok": True, "path": rel}

    def serve_page(self, rel):
        rel = urllib.parse.unquote(rel)
        try:
            full = safe_join(PAGES, rel)
        except ValueError:
            return self.send_text("Not found", "text/plain", 404)
        if os.path.isdir(full):
            if rel and not rel.endswith("/"):
                self.send_response(301)
                self.send_header("Location", "/pages/" + urllib.parse.quote(rel) + "/")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            idx = find_index(full)
            if idx:
                full = os.path.join(full, idx)
        if not os.path.isfile(full):
            return self.send_text("Not found", "text/plain", 404)
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/javascript", "application/json"):
            ctype += "; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(os.path.getsize(full)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        with open(full, "rb") as f:
            shutil.copyfileobj(f, self.wfile)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        path = url.path
        if path == "/pages" or path.startswith("/pages/"):
            return self.serve_page(path[len("/pages/"):] if path.startswith("/pages/") else "")
        if path == "/setup":
            return self.send_text(SETUP_HTML)
        if path == "/api/info":
            info = status()
            info["default_password"] = read_conf()["ADMIN_PASSWORD"] == "kiosk"
            return self.send_json(info)
        if not self.authed():
            return
        try:
            if path in ("/", "/index.html"):
                return self.send_text(ADMIN_HTML)
            if path == "/api/config":
                conf = read_conf()
                conf.pop("ADMIN_PASSWORD", None)
                return self.send_json({"config": conf, "status": status(), "days": DAYS,
                                       "timezones": TIMEZONES})
            if path == "/api/browse":
                q = urllib.parse.parse_qs(url.query)
                return self.send_json(browse(q.get("path", [""])[0]))
            if path == "/api/wifi":
                q = urllib.parse.parse_qs(url.query)
                return self.send_json(wifi_status(q.get("rescan", ["0"])[0] == "1"))
            self.send_text("Not found", "text/plain", 404)
        except ValueError as e:
            self.send_json({"error": str(e)}, 400)

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        path = url.path
        if not self.authed():
            return
        try:
            if path == "/api/upload":
                return self.send_json(self.handle_upload(urllib.parse.parse_qs(url.query)))
            data = self.read_json()
            if path == "/api/config":
                conf = validate(data, read_conf())
                if data.get("TIMEZONE"):
                    set_timezone(data["TIMEZONE"])
                write_conf(conf)
                kiosk_home()
                return self.send_json({"ok": True})
            if path == "/api/mkdir":
                return self.send_json({"ok": True, "path": make_dir(data.get("path", ""))})
            if path == "/api/delete":
                delete_path(data.get("path", ""))
                return self.send_json({"ok": True})
            if path == "/api/home":
                kiosk_home()
                return self.send_json({"ok": True})
            if path == "/api/screen":
                state = data.get("state")
                os.makedirs(STATE, exist_ok=True)
                ov = os.path.join(STATE, "override")
                if state in ("on", "off"):
                    with open(ov, "w") as f:
                        f.write(state + "\n")
                elif state == "auto":
                    if os.path.exists(ov):
                        os.remove(ov)
                else:
                    raise ValueError("Unknown screen state")
                return self.send_json({"ok": True})
            if path == "/api/wifi/connect":
                wifi_connect(data)
                return self.send_json({"ok": True})
            if path == "/api/hotspot/off":
                hotspot_off()
                return self.send_json({"ok": True})
            if path == "/api/wifi/forget":
                wifi_forget(str(data.get("name", "")))
                return self.send_json({"ok": True})
            if path == "/api/reboot":
                self.send_json({"ok": True})
                subprocess.Popen(["sudo", "-n", "/usr/sbin/reboot"])
                return
            if path == "/api/shutdown":
                self.send_json({"ok": True})
                subprocess.Popen(["sudo", "-n", "/usr/sbin/poweroff"])
                return
            self.send_json({"error": "Not found"}, 404)
        except ValueError as e:
            self.send_json({"error": str(e)}, 400)
        except OSError as e:
            self.send_json({"error": f"Could not save: {e.strerror or e}"}, 400)
        except Exception as e:  # keep the server alive
            self.send_json({"error": f"Server error: {e}"}, 500)


SETUP_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kiosk Setup</title>
<style>
  html,body{margin:0;height:100%;background:#0f1419;color:#e8eaed;
    font-family:system-ui,-apple-system,"Segoe UI",Roboto,"DejaVu Sans",sans-serif}
  .wrap{min-height:100%;display:flex;flex-direction:column;justify-content:center;
    padding:6vmin;box-sizing:border-box;max-width:900px;margin:0 auto}
  .tag{display:inline-block;align-self:flex-start;background:#3a2a10;color:#f2b84b;
    border-radius:999px;padding:6px 16px;font-size:20px;margin-bottom:22px}
  h1{font-size:44px;margin:0 0 30px;font-weight:650;line-height:1.15}
  ol{margin:0;padding:0;list-style:none;counter-reset:s}
  li{counter-increment:s;display:flex;gap:18px;margin:0 0 26px;font-size:24px;line-height:1.4;color:#c9d1d9}
  li::before{content:counter(s);flex:none;width:44px;height:44px;border-radius:50%;
    background:#1f6feb;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:700}
  .big{display:block;font-size:34px;color:#fff;font-weight:650;margin-top:4px;word-break:break-all}
  .lbl{color:#8b949e;font-size:19px}
  .note{margin-top:20px;font-size:19px;color:#8b949e;line-height:1.5}
  kbd{background:#21262d;border:1px solid #30363d;border-radius:6px;padding:1px 8px;font-size:17px}
</style>
</head>
<body>
<div class="wrap">
  <span class="tag" id="tag">No network connection</span>
  <h1 id="title">Connect this kiosk to Wi-Fi</h1>
  <ol>
    <li><div>On your phone, join this Wi-Fi network:
      <span class="big" id="ssid">Kiosk</span>
      <span class="lbl">Password:</span> <span class="big" id="pw" style="display:inline">…</span></div></li>
    <li><div>Open this address in the phone's browser:
      <span class="big" id="addr">http://10.42.0.1:8080</span></div></li>
    <li><div id="step3">Sign in, go to <b>Wi-Fi</b>, pick your network and tap <b>Connect</b>.</div></li>
  </ol>
  <div class="note" id="note">The kiosk also retries its saved Wi-Fi every 10 minutes.<br>
    Have a keyboard? Press <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>S</kbd> to open the settings here.</div>
</div>
<script>
function load() {
  fetch('/api/info').then(r => r.json()).then(d => {
    const h = d.hotspot;
    if (!h) return;
    document.getElementById('ssid').textContent = h.SSID;
    document.getElementById('pw').textContent = h.PASSWORD;
    document.getElementById('addr').textContent = 'http://' + (h.ADDRESS || '10.42.0.1') + ':' + d.port;
    if (h.MODE === 'manual') {
      document.getElementById('tag').textContent = 'Setup mode';
      document.getElementById('title').textContent = 'Set up this kiosk';
      document.getElementById('step3').innerHTML =
        'Sign in to upload pages, change the home page or other settings.';
      document.getElementById('note').innerHTML =
        'Press <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>W</kbd> again when you are done, or tap ' +
        '<b>Turn off setup hotspot</b> on the settings page. It also turns off by itself after ' +
        '30 minutes with no phone connected.<br>' +
        '<kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>H</kbd> shows the home page while setup mode stays on.';
    }
  }).catch(() => {});
}
load();
setInterval(load, 10000);
</script>
</body>
</html>
"""


ADMIN_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kiosk Settings</title>
<style>
:root{--bg:#f3f4f6;--card:#fff;--fg:#1d2330;--mut:#667085;--line:#dde1e7;--acc:#1f6feb;--accfg:#fff;--accsoft:#e8f0fe;--bad:#c0392b;--ok:#1a7f37}
@media (prefers-color-scheme:dark){:root{--bg:#0f1419;--card:#1a1f26;--fg:#e8eaed;--mut:#9aa3ae;--line:#2c333d;--acc:#4c8dff;--accfg:#fff;--accsoft:#1c2a40;--bad:#ff6b5e;--ok:#3fb950}}
*{box-sizing:border-box}
body{margin:0;font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--fg)}
main{max-width:680px;margin:0 auto;padding:16px 16px 110px}
h1{font-size:22px;margin:6px 0 2px}
.sub{color:var(--mut);font-size:14px;margin:0 0 16px}
section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:14px}
h2{font-size:16px;margin:0 0 10px}
label.f{display:block;font-size:14px;color:var(--mut);margin:12px 0 4px}
input[type=url],input[type=text],input[type=number],input[type=time],input[type=password],select{
  width:100%;padding:10px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--fg);font-size:16px}
.hint{font-size:13px;color:var(--mut);margin-top:6px}
.row{display:flex;gap:10px}.row>*{flex:1;min-width:0}
.seg{display:flex;flex-wrap:wrap;gap:6px}
.seg label{flex:1;min-width:56px;text-align:center;padding:9px 6px;border:1px solid var(--line);border-radius:8px;cursor:pointer;font-size:14px;user-select:none}
.seg input{position:absolute;opacity:0;pointer-events:none}
.seg label:has(input:checked){background:var(--acc);border-color:var(--acc);color:var(--accfg)}
.switch{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:10px 0}
.switch input{flex:none;width:22px;height:22px;accent-color:var(--acc)}
button,.btn{display:inline-block;padding:11px 14px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--fg);font-size:15px;cursor:pointer;text-decoration:none;line-height:1.2}
button:disabled{opacity:.5;cursor:default}
button.primary{background:var(--acc);border-color:var(--acc);color:var(--accfg);font-weight:600}
button.danger{color:var(--bad)}
button.small{padding:6px 10px;font-size:13px}
h3{font-size:15px;margin:20px 0 6px}
.lblrow{display:flex;align-items:center;justify-content:space-between;margin:14px 0 6px;font-size:14px;color:var(--mut)}
.warn{margin-top:10px;padding:10px 12px;border-radius:8px;background:#fff4e0;color:#7a4a00;font-size:14px}
@media (prefers-color-scheme:dark){.warn{background:#3a2a10;color:#f2b84b}}
.btns{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--card);border-top:1px solid var(--line);padding:12px 16px}
.bar .in{max-width:680px;margin:0 auto;display:flex;gap:10px}
.bar button{flex:1}
#toast{position:fixed;left:50%;bottom:84px;transform:translateX(-50%);background:var(--fg);color:var(--bg);padding:10px 16px;border-radius:8px;font-size:14px;opacity:0;transition:opacity .2s;pointer-events:none;max-width:90%;z-index:10}
#toast.show{opacity:1}
#toast.bad{background:var(--bad);color:#fff}
.hidden{display:none !important}

/* current selection */
.current{display:flex;align-items:center;gap:10px;margin-top:12px;padding:10px 12px;border-radius:8px;background:var(--accsoft);font-size:14px}
.current .p{flex:1;min-width:0;word-break:break-all}
.current .p b{display:block;font-size:12px;font-weight:500;color:var(--mut)}
.current a{font-size:13px;color:var(--acc);white-space:nowrap}

/* file browser */
.fb{margin-top:12px;border:1px solid var(--line);border-radius:10px;overflow:hidden}
.fb-head{display:flex;align-items:center;gap:8px;padding:8px 10px;background:var(--bg);border-bottom:1px solid var(--line)}
.crumbs{flex:1;min-width:0;display:flex;flex-wrap:wrap;align-items:center;gap:2px;font-size:14px}
.crumbs button{border:0;background:none;padding:4px 6px;font-size:14px;color:var(--acc)}
.crumbs button:last-child{color:var(--fg);font-weight:600}
.crumbs span{color:var(--mut)}
.fb-head .small{padding:6px 10px;font-size:13px;white-space:nowrap}
.fb-list{max-height:420px;overflow:auto}
.item{display:flex;align-items:center;gap:10px;padding:9px 10px;border-top:1px solid var(--line);font-size:14px}
.item:first-child{border-top:0}
.item.sel{background:var(--accsoft)}
.item svg{flex:none;width:22px;height:22px}
.item .nm{flex:1;min-width:0;word-break:break-all;cursor:default}
.item .nm small{display:block;color:var(--mut);font-size:12px}
.item.dir .nm{cursor:pointer}
.item .acts{display:flex;gap:6px;flex:none}
.item .acts button,.item .acts a{padding:6px 10px;font-size:13px}
.item .acts .use{border-color:var(--acc);color:var(--acc)}
.item.sel .acts .use{background:var(--acc);color:var(--accfg)}
.empty{padding:22px 10px;text-align:center;color:var(--mut);font-size:14px}
.fb-foot{display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:10px;border-top:1px solid var(--line);background:var(--bg)}
.fb-foot .where{flex-basis:100%;font-size:12px;color:var(--mut)}
.prog{font-size:13px;color:var(--mut);margin-top:8px;min-height:1em}
.fb.drag{outline:2px dashed var(--acc);outline-offset:-4px}
</style>
</head>
<body>
<main>
  <h1>Kiosk Settings</h1>
  <p class="sub" id="status">Loading…</p>

  <section>
    <h2>Home page</h2>
    <div class="seg">
      <label><input type="radio" name="src" value="url"> Web address</label>
      <label><input type="radio" name="src" value="local"> Page on the kiosk</label>
    </div>

    <div id="srcUrl">
      <label class="f" for="url">Web address</label>
      <input type="url" id="url" placeholder="https://example.com/dashboard" autocomplete="off">
      <div class="hint">Any http://, https:// or file:// address.</div>
    </div>

    <div id="srcLocal" class="hidden">
      <div class="current">
        <div class="p"><b>Home page</b><span id="curName">None selected</span></div>
        <a id="curPreview" class="hidden" target="_blank" rel="noopener">Preview ↗</a>
      </div>

      <div class="fb" id="fb">
        <div class="fb-head">
          <div class="crumbs" id="crumbs"></div>
          <button class="small" id="newFolder">+ Folder</button>
        </div>
        <div class="fb-list" id="fbList"></div>
        <div class="fb-foot">
          <button id="btnFiles">Upload files</button>
          <button id="btnFolder">Upload folder</button>
          <span class="where" id="where"></span>
        </div>
      </div>
      <input type="file" id="upFiles" multiple hidden>
      <input type="file" id="upFolder" webkitdirectory directory multiple hidden>
      <div class="prog" id="prog"></div>
      <div class="hint">Tap <b>Use</b> next to a page to make it the home page. Open a folder by tapping its name.
        <b>Upload files</b> lets you pick many files at once (HTML, images, CSS, JS) and puts them in the folder you have open.
        <b>Upload folder</b> copies a whole site folder (works on computers; phones can use Upload files).
        A .zip is unpacked into its own folder. Files with the same name are replaced.
        You can also drag files onto the list.</div>
    </div>
  </section>

  <section>
    <h2>Return to home page when idle</h2>
    <label class="f" for="idle">Minutes with no touches (0 = never)</label>
    <input type="number" id="idle" min="0" max="1440" step="1">
  </section>

  <section>
    <h2>Display</h2>
    <label class="f">Rotation</label>
    <div class="seg">
      <label><input type="radio" name="rot" value="0"> 0° landscape</label>
      <label><input type="radio" name="rot" value="90"> 90° portrait</label>
      <label><input type="radio" name="rot" value="180"> 180°</label>
      <label><input type="radio" name="rot" value="270"> 270° portrait</label>
    </div>
    <div class="hint">If the picture is upside down in portrait, switch between 90° and 270°.</div>
    <div class="row">
      <div>
        <label class="f" for="scale">Zoom</label>
        <select id="scale">
          <option value="1">100%</option><option value="1.25">125%</option>
          <option value="1.5">150%</option><option value="1.75">175%</option>
          <option value="2">200%</option>
        </select>
      </div>
      <div>
        <label class="f" for="output">Video output</label>
        <input type="text" id="output" placeholder="auto">
      </div>
    </div>
    <div class="hint">Leave video output as <b>auto</b> unless the computer has two screens connected
      (examples: HDMI-A-1, DP-1).</div>
    <div class="switch"><span>Hide mouse pointer<br><small class="hint">Takes effect after a reboot</small></span>
      <input type="checkbox" id="hideCur"></div>
    <div class="switch"><span>Graphics compatibility mode<br><small class="hint">Fixes a blank white screen.
      Turn off only if videos or animations look choppy.</small></span>
      <input type="checkbox" id="safeGfx"></div>
  </section>

  <section>
    <h2>Screen on/off schedule</h2>
    <label class="f" for="tz">Time zone</label>
    <select id="tz"></select>
    <div class="hint" id="clock"></div>
    <div class="switch"><span>Use schedule</span><input type="checkbox" id="schedOn"></div>
    <div id="schedBox">
      <div class="row">
        <div><label class="f" for="tOn">Screen on</label><input type="time" id="tOn"></div>
        <div><label class="f" for="tOff">Screen off</label><input type="time" id="tOff"></div>
      </div>
      <label class="f">Days the screen turns on</label>
      <div class="seg" id="daySeg"></div>
      <div class="hint">On days not selected, the screen stays off all day.</div>
      <div class="switch"><span>Also put a TV to sleep using HDMI-CEC</span><input type="checkbox" id="cec"></div>
    </div>
    <label class="f">Right now</label>
    <div class="btns">
      <button data-screen="on">Screen on</button>
      <button data-screen="off">Screen off</button>
      <button data-screen="auto">Follow schedule</button>
    </div>
    <div class="hint">Manual on/off lasts until the next scheduled change.</div>
  </section>

  <section>
    <h2>Network</h2>
    <label class="f">Network mode</label>
    <div class="seg">
      <label><input type="radio" name="netmode" value="wifi"> Use Wi-Fi</label>
      <label><input type="radio" name="netmode" value="offline"> Offline (no Wi-Fi)</label>
    </div>
    <div class="hint">Offline: the kiosk never joins Wi-Fi and shows pages stored on it. To make changes,
      plug a keyboard into the kiosk and press <b>Ctrl+Alt+W</b> to start the setup hotspot.</div>
    <div class="current"><div class="p"><b>Connected to</b><span id="wNow">Checking…</span></div></div>
    <div class="warn hidden" id="wHot"></div>
    <div class="btns hidden" id="hsOffRow"><button class="danger" id="hsOff">Turn off setup hotspot</button></div>
    <div class="lblrow"><span>Networks nearby</span><button class="small" id="wScan">Scan</button></div>
    <div class="fb" style="margin-top:0"><div class="fb-list" id="wList"><div class="empty">Loading…</div></div></div>
    <label class="f" for="wSsid">Network name</label>
    <input type="text" id="wSsid" autocomplete="off" autocapitalize="off" spellcheck="false">
    <label class="f" for="wPass">Password (leave blank for an open network)</label>
    <input type="password" id="wPass" autocomplete="off">
    <div class="switch"><span>Hidden network</span><input type="checkbox" id="wHidden"></div>
    <div class="btns"><button class="primary" id="wConnect">Connect</button></div>
    <div class="prog" id="wMsg"></div>
    <div class="hint">If the kiosk moves to a different network than your phone is on, this page stops
      responding. Join your phone to the same network and open the address shown on the kiosk screen.</div>

    <h3>Saved networks</h3>
    <div class="fb" style="margin-top:0"><div class="fb-list" id="wSaved"></div></div>

    <h3>Setup hotspot</h3>
    <div class="switch"><span>Start it automatically if Wi-Fi is lost<br><small class="hint">Use Wi-Fi mode only</small></span>
      <input type="checkbox" id="hsOn"></div>
    <div class="row">
      <div><label class="f" for="hsPw">Hotspot password</label><input type="text" id="hsPw" autocomplete="off"></div>
      <div><label class="f" for="hsDelay">Start after (minutes offline)</label><input type="number" id="hsDelay" min="1" max="60"></div>
    </div>
    <div class="hint">The setup hotspot is the kiosk's own Wi-Fi, called <b id="hsName">Kiosk</b>.
      Join it from your phone and open <b>http://10.42.0.1:8080</b> to change settings, upload pages or
      pick a network. Press <b>Ctrl+Alt+W</b> on a keyboard plugged into the kiosk to turn it on or off
      at any time. Saved with <b>Save &amp; apply</b>.</div>
  </section>

  <section>
    <h2>Privacy</h2>
    <div class="switch"><span>Private mode — forget logins and cookies every time it returns home</span>
      <input type="checkbox" id="priv"></div>
  </section>

  <section>
    <h2>Settings password</h2>
    <label class="f" for="pw">New password (leave blank to keep current)</label>
    <input type="password" id="pw" autocomplete="new-password">
    <div class="hint">After changing it, your browser will ask you to sign in again.</div>
  </section>

  <section>
    <h2>System</h2>
    <div class="btns">
      <button class="danger" id="reboot">Reboot kiosk</button>
      <button class="danger" id="shutdown">Shut down kiosk</button>
    </div>
    <div class="hint">After shutting down, turn it back on with the power button
      (Pi 5 and mini PCs) or by unplugging and plugging the power back in.</div>
  </section>
</main>

<div class="bar"><div class="in">
  <button id="home">Go home now</button>
  <button class="primary" id="save">Save &amp; apply</button>
</div></div>
<div id="toast"></div>

<script>
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
let data = null;
let cwd = '';            // folder open in the file browser
let entries = [];        // its contents
let selectedRel = '';    // page chosen as home (path inside the pages folder)
let busy = false;
const PROTECTED = ['welcome'];   // built-in folders (read-only)
const isProtected = rel => PROTECTED.includes((rel || '').split('/')[0]);

const ICON_DIR = '<svg viewBox="0 0 24 24" fill="none"><path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h4.6l2 2h8.4A1.5 1.5 0 0 1 21 8.5v9A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5z" fill="#f2b84b"/></svg>';
const ICON_PAGE = '<svg viewBox="0 0 24 24" fill="none"><path d="M6 3h8l4 4v14H6z" fill="#4c8dff" opacity=".18"/><path d="M6 3h8l4 4v14H6z" stroke="#4c8dff" stroke-width="1.5"/><path d="M10 12l-2 2 2 2M14 12l2 2-2 2" stroke="#4c8dff" stroke-width="1.5" stroke-linecap="round"/></svg>';
const ICON_FILE = '<svg viewBox="0 0 24 24" fill="none"><path d="M6 3h8l4 4v14H6z" stroke="#8b94a1" stroke-width="1.5"/></svg>';

function toast(msg, bad) {
  const t = $('#toast');
  t.textContent = msg;
  t.className = 'show' + (bad ? ' bad' : '');
  clearTimeout(toast.t);
  toast.t = setTimeout(() => t.className = '', 2800);
}

async function api(path, opts = {}) {
  const r = await fetch(path, opts);
  let j = {};
  try { j = await r.json(); } catch (e) {}
  if (!r.ok) throw new Error(j.error || ('Error ' + r.status));
  return j;
}
const post = (path, obj) => api(path, {method: 'POST', body: JSON.stringify(obj || {})});

/* ---------- paths ---------- */
function localPrefix() { return 'http://localhost:' + data.status.port + '/pages/'; }
const enc = rel => rel.split('/').map(encodeURIComponent).join('/');
const relToUrl = rel => localPrefix() + enc(rel);
const previewUrl = rel => '/pages/' + enc(rel);
function urlToRel(u) {
  if (!u || !u.startsWith(localPrefix())) return null;
  try { return u.slice(localPrefix().length).split('/').map(decodeURIComponent).join('/'); }
  catch (e) { return null; }
}
const join = (a, b) => a ? a + '/' + b : b;
const parentOf = rel => rel.includes('/') ? rel.slice(0, rel.lastIndexOf('/')) : '';
function fmtSize(n) {
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n / 1024).toFixed(0) + ' KB';
  return (n / 1048576).toFixed(1) + ' MB';
}
function skip(path) {
  return path.split('/').some(p => p.startsWith('.') || ['__MACOSX', 'Thumbs.db', 'desktop.ini'].includes(p));
}

/* ---------- radios ---------- */
function setRadio(name, val) { $$('input[name="' + name + '"]').forEach(i => i.checked = (i.value === String(val))); }
function getRadio(name) { const i = $('input[name="' + name + '"]:checked'); return i ? i.value : null; }
function showSource() {
  const local = getRadio('src') === 'local';
  $('#srcUrl').classList.toggle('hidden', local);
  $('#srcLocal').classList.toggle('hidden', !local);
}

/* ---------- selection ---------- */
function select(rel) {
  selectedRel = rel || '';
  $('#curName').textContent = selectedRel || 'None selected';
  const a = $('#curPreview');
  if (selectedRel) { a.href = previewUrl(selectedRel); a.classList.remove('hidden'); }
  else a.classList.add('hidden');
  renderList();
}

/* ---------- file browser ---------- */
async function openDir(path) {
  try {
    const r = await api('/api/browse?path=' + encodeURIComponent(path || ''));
    cwd = r.path; entries = r.entries;
  } catch (e) {
    if (path) return openDir('');
    toast(e.message, true); entries = [];
  }
  renderCrumbs(); renderList(); updateUploadState();
}

function updateUploadState() {
  const ro = isProtected(cwd);
  $('#btnFiles').disabled = busy || ro;
  $('#btnFolder').disabled = busy || ro;
  $('#newFolder').disabled = busy || ro;
  $('#save').disabled = busy;
  $('#where').textContent = ro
    ? 'This is the built-in welcome folder. Go back to Pages to upload.'
    : 'Uploads go to: /' + cwd;
}

function renderCrumbs() {
  const c = $('#crumbs'); c.innerHTML = '';
  const parts = cwd ? cwd.split('/') : [];
  const add = (label, path) => {
    const b = document.createElement('button');
    b.textContent = label; b.onclick = () => openDir(path); c.appendChild(b);
  };
  add('Pages', '');
  parts.forEach((p, i) => {
    const s = document.createElement('span'); s.textContent = '›'; c.appendChild(s);
    add(p, parts.slice(0, i + 1).join('/'));
  });
}

function actionBtn(label, cls, fn) {
  const b = document.createElement('button');
  b.textContent = label; if (cls) b.className = cls;
  b.onclick = e => { e.stopPropagation(); fn(); };
  return b;
}

function renderList() {
  const list = $('#fbList'); list.innerHTML = '';
  if (cwd) {
    const up = document.createElement('div');
    up.className = 'item dir';
    up.innerHTML = ICON_DIR;
    const nm = document.createElement('div'); nm.className = 'nm'; nm.textContent = '.. (back)';
    nm.onclick = () => openDir(parentOf(cwd));
    up.appendChild(nm); list.appendChild(up);
  }
  if (!entries.length) {
    const e = document.createElement('div'); e.className = 'empty';
    e.textContent = 'This folder is empty. Upload files or a folder below.';
    list.appendChild(e); return;
  }
  entries.forEach(it => {
    const row = document.createElement('div');
    row.className = 'item ' + it.type;
    row.innerHTML = it.type === 'dir' ? ICON_DIR : (it.page ? ICON_PAGE : ICON_FILE);
    const nm = document.createElement('div'); nm.className = 'nm';
    nm.textContent = it.name;
    const small = document.createElement('small');
    const acts = document.createElement('div'); acts.className = 'acts';

    if (it.type === 'dir') {
      const homeRel = it.index ? join(it.path, it.index) : null;
      small.textContent = it.count + ' item' + (it.count === 1 ? '' : 's') + (it.index ? ' · has ' + it.index : '');
      nm.onclick = () => openDir(it.path);
      if (homeRel) {
        if (homeRel === selectedRel) row.classList.add('sel');
        acts.appendChild(actionBtn(homeRel === selectedRel ? 'In use' : 'Use', 'use', () => select(homeRel)));
      }
      if (!it.protected) acts.appendChild(actionBtn('Delete', 'danger', () => remove(it)));
    } else {
      small.textContent = fmtSize(it.size);
      if (it.page) {
        if (it.path === selectedRel) row.classList.add('sel');
        acts.appendChild(actionBtn(it.path === selectedRel ? 'In use' : 'Use', 'use', () => select(it.path)));
        const a = document.createElement('a');
        a.className = 'btn'; a.textContent = 'View'; a.target = '_blank'; a.rel = 'noopener';
        a.href = previewUrl(it.path); acts.appendChild(a);
      }
      if (!isProtected(it.path)) acts.appendChild(actionBtn('Delete', 'danger', () => remove(it)));
    }
    nm.appendChild(small);
    row.append(nm, acts);
    list.appendChild(row);
  });
}

async function remove(it) {
  const what = it.type === 'dir' ? 'the folder "' + it.name + '" and everything in it' : '"' + it.name + '"';
  if (!confirm('Delete ' + what + '?')) return;
  try {
    await post('/api/delete', {path: it.path});
    if (selectedRel && (selectedRel === it.path || selectedRel.startsWith(it.path + '/'))) {
      select('');
      toast('Deleted - pick a new home page', true);
    } else toast('Deleted');
    openDir(cwd);
  } catch (e) { toast(e.message, true); }
}

$('#newFolder').onclick = async () => {
  const name = (prompt('New folder name:') || '').trim();
  if (!name) return;
  try { const r = await post('/api/mkdir', {path: join(cwd, name)}); openDir(r.path); }
  catch (e) { toast(e.message, true); }
};

/* ---------- uploads ---------- */
function setBusy(b) { busy = b; updateUploadState(); }

async function uploadList(items) {
  const prog = $('#prog');
  const results = [], failed = [];
  setBusy(true);
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    prog.textContent = 'Uploading ' + (i + 1) + ' of ' + items.length + ': ' + it.path;
    try {
      const q = '/api/upload?path=' + encodeURIComponent(it.path) + (it.extract ? '&extract=1' : '');
      results.push(await api(q, {method: 'POST', body: it.file}));
    } catch (e) { failed.push(it.path + ' - ' + e.message); }
  }
  setBusy(false);
  prog.textContent = failed.length
    ? 'Finished with ' + failed.length + ' problem(s): ' + failed.slice(0, 3).join('; ') + (failed.length > 3 ? '…' : '')
    : 'Uploaded ' + items.length + ' file' + (items.length === 1 ? '' : 's') + '.';
  return results;
}

async function uploadFiles(files) {
  files = files.filter(f => !skip(f.name));
  if (!files.length || busy || isProtected(cwd)) return;
  const items = files.map(f => ({file: f, path: join(cwd, f.name), extract: /\.zip$/i.test(f.name)}));
  const results = await uploadList(items);
  const ok = new Set(results.map(r => r.path));

  const zipped = results.find(r => r.index !== undefined);
  const pages = files.filter(f => /\.html?$/i.test(f.name) && ok.has(join(cwd, f.name)));
  const index = pages.find(f => /^index\.html?$/i.test(f.name)) || (pages.length === 1 ? pages[0] : null);

  if (index) { select(join(cwd, index.name)); toast('Uploaded - tap Save & apply to show it'); }
  else if (zipped && zipped.index) { select(zipped.index); await openDir(zipped.path); toast('Unpacked - tap Save & apply to show it'); return; }
  openDir(cwd);
}

async function uploadFolder(files) {
  files = files.filter(f => !skip(f.webkitRelativePath || f.name));
  if (!files.length || busy || isProtected(cwd)) return;
  const items = files.map(f => ({file: f, path: join(cwd, f.webkitRelativePath || f.name)}));
  const results = await uploadList(items);
  const ok = new Set(results.map(r => r.path));
  const top = (files[0].webkitRelativePath || '').split('/')[0];
  const index = files.find(f => /^[^/]+\/index\.html?$/i.test(f.webkitRelativePath || '')
                               && ok.has(join(cwd, f.webkitRelativePath)));
  if (index) { select(join(cwd, index.webkitRelativePath)); toast('Uploaded - tap Save & apply to show it'); }
  openDir(top ? join(cwd, top) : cwd);
}

$('#btnFiles').onclick = () => $('#upFiles').click();
$('#btnFolder').onclick = () => $('#upFolder').click();
$('#upFiles').onchange = e => { const f = [...e.target.files]; e.target.value = ''; uploadFiles(f); };
$('#upFolder').onchange = e => { const f = [...e.target.files]; e.target.value = ''; uploadFolder(f); };

const fb = $('#fb');
fb.addEventListener('dragover', e => { e.preventDefault(); fb.classList.add('drag'); });
fb.addEventListener('dragleave', () => fb.classList.remove('drag'));
fb.addEventListener('drop', e => {
  e.preventDefault(); fb.classList.remove('drag');
  const files = [...(e.dataTransfer.files || [])].filter(f => f.size > 0 || f.type);
  if (files.length) uploadFiles(files);
  else toast('To copy a whole folder, use Upload folder', true);
});

/* ---------- status / settings ---------- */
function renderStatus() {
  const s = data.status;
  const ip = s.ips && s.ips.length ? s.ips[0] : '';
  const screen = s.screen + (s.override ? ' (manual)' : '');
  $('#status').innerHTML = 'Screen <b>' + screen + '</b> · Output <b>' + s.output +
    '</b><br>' + s.hostname + '.local' + (ip ? ' · ' + ip : '');
  $('#clock').textContent = 'Kiosk clock: ' + s.time + ' (' + s.timezone + ')';
}

function fill() {
  const c = data.config;
  const rel = urlToRel(c.HOME_URL);
  setRadio('src', rel !== null ? 'local' : 'url');
  $('#url').value = rel !== null ? '' : c.HOME_URL;
  select(rel || '');
  showSource();
  const start = rel ? parentOf(rel) : '';
  openDir(isProtected(start) ? '' : start);

  $('#idle').value = c.IDLE_MINUTES;
  setRadio('rot', c.ROTATION);
  $('#scale').value = ['1', '1.25', '1.5', '1.75', '2'].includes(c.SCALE) ? c.SCALE : '1';
  $('#output').value = c.OUTPUT;

  $('#schedOn').checked = c.SCHEDULE_ENABLED === '1';
  $('#tOn').value = c.SCREEN_ON;
  $('#tOff').value = c.SCREEN_OFF;
  const on = c.SCREEN_DAYS.split(' ');
  $('#daySeg').innerHTML = '';
  data.days.forEach(d => {
    const l = document.createElement('label');
    l.innerHTML = '<input type="checkbox" name="day" value="' + d + '"' + (on.includes(d) ? ' checked' : '') + '> ' + d;
    $('#daySeg').appendChild(l);
  });
  $('#cec').checked = c.USE_CEC === '1';
  $('#schedBox').style.opacity = $('#schedOn').checked ? 1 : .5;
  $('#priv').checked = c.PRIVATE_MODE === '1';
  $('#hideCur').checked = c.HIDE_CURSOR === '1';
  $('#safeGfx').checked = c.SAFE_GRAPHICS === '1';
  setRadio('netmode', c.NETWORK_MODE || 'wifi');
  $('#hsOn').checked = c.HOTSPOT_ENABLED === '1';
  $('#hsPw').value = c.HOTSPOT_PASSWORD;
  $('#hsDelay').value = c.HOTSPOT_DELAY;
  $('#hsName').textContent = 'Kiosk-' + data.status.hostname;
  const zones = data.timezones.slice();
  if (!zones.includes(data.status.timezone)) zones.unshift(data.status.timezone);
  $('#tz').innerHTML = '';
  zones.forEach(z => {
    const o = document.createElement('option');
    o.value = z; o.textContent = z.replace('America/', '').replace('Pacific/', '').replace(/_/g, ' ');
    if (z === data.status.timezone) o.selected = true;
    $('#tz').appendChild(o);
  });
  renderStatus();
}

async function load() {
  try { data = await api('/api/config'); fill(); loadWifi(false); }
  catch (e) { $('#status').textContent = 'Could not load settings: ' + e.message; }
}

/* ---------- wifi ---------- */
let wifiPoll = null, wifiBusy = false;

async function loadWifi(rescan) {
  if (rescan) $('#wList').innerHTML = '<div class="empty">Scanning… (about 10 seconds)</div>';
  try {
    renderWifi(await api('/api/wifi' + (rescan ? '?rescan=1' : '')));
  } catch (e) {
    if (wifiBusy) {
      $('#wMsg').textContent = 'Lost contact with the kiosk - it is probably switching networks. ' +
        'Join your phone to the new network and open the address shown on the kiosk screen.';
      wifiPoll = setTimeout(() => loadWifi(false), 5000);
    } else {
      $('#wNow').textContent = 'Could not read Wi-Fi: ' + e.message;
    }
  }
}

function renderWifi(w) {
  if (!w.available) {
    $('#wNow').textContent = w.error || 'Wi-Fi tools are not available';
    $('#wList').innerHTML = '';
    return;
  }
  $('#wNow').textContent = w.connections.length
    ? w.connections.map(c => c.name + (c.type === 'ethernet' ? ' (wired)' : '')).join(', ')
    : 'Not connected';
  const hot = $('#wHot');
  if (w.hotspot) {
    hot.textContent = (w.hotspot.MODE === 'manual' ? 'Setup hotspot' : 'Backup hotspot') + ' is on (' +
      w.hotspot.SSID + '). The list below is from just before it started. ' +
      'Connecting to a network turns the hotspot off.';
    hot.classList.remove('hidden');
    $('#hsOffRow').classList.remove('hidden');
  } else {
    hot.classList.add('hidden');
    $('#hsOffRow').classList.add('hidden');
  }

  const list = $('#wList'); list.innerHTML = '';
  if (!w.networks.length) list.innerHTML = '<div class="empty">No networks found. Tap Scan.</div>';
  w.networks.forEach(n => {
    const row = document.createElement('div');
    row.className = 'item' + (n.inuse ? ' sel' : '');
    const nm = document.createElement('div'); nm.className = 'nm'; nm.textContent = n.ssid;
    const sm = document.createElement('small');
    sm.textContent = n.signal + '% signal · ' + (n.secure ? 'needs password' : 'open') + (n.inuse ? ' · connected' : '');
    nm.appendChild(sm);
    const acts = document.createElement('div'); acts.className = 'acts';
    acts.appendChild(actionBtn('Choose', 'use', () => {
      $('#wSsid').value = n.ssid; $('#wHidden').checked = false; $('#wPass').value = '';
      $('#wPass').focus();
    }));
    row.append(nm, acts); list.appendChild(row);
  });

  const sv = $('#wSaved'); sv.innerHTML = '';
  if (!w.saved.length) sv.innerHTML = '<div class="empty">No saved networks</div>';
  w.saved.forEach(name => {
    const row = document.createElement('div'); row.className = 'item';
    const nm = document.createElement('div'); nm.className = 'nm'; nm.textContent = name;
    const acts = document.createElement('div'); acts.className = 'acts';
    acts.appendChild(actionBtn('Forget', 'danger', async () => {
      if (!confirm('Forget "' + name + '"? The kiosk will not reconnect to it automatically.')) return;
      try { await post('/api/wifi/forget', {name}); toast('Forgotten'); loadWifi(false); }
      catch (e) { toast(e.message, true); }
    }));
    row.append(nm, acts); sv.appendChild(row);
  });
  showWifiResult(w.result);
}

function showWifiResult(r) {
  clearTimeout(wifiPoll);
  if (!r) { wifiBusy = false; return; }
  const m = $('#wMsg');
  m.textContent = r.message;
  m.style.color = r.state === 'error' ? 'var(--bad)' : r.state === 'ok' ? 'var(--ok)' : '';
  wifiBusy = r.state === 'connecting';
  $('#wConnect').disabled = wifiBusy;
  if (wifiBusy) wifiPoll = setTimeout(() => loadWifi(false), 3000);
}

$('#wScan').onclick = () => loadWifi(true);
$('#hsOff').onclick = async () => {
  if (!confirm('Turn off the setup hotspot? If your phone is connected to it, this page will stop responding.')) return;
  try { await post('/api/hotspot/off'); toast('Turning off the hotspot…'); setTimeout(() => loadWifi(false), 8000); }
  catch (e) { toast(e.message, true); }
};
$('#wConnect').onclick = async () => {
  const ssid = $('#wSsid').value;
  if (!ssid.trim()) { toast('Choose or type a network name', true); return; }
  if (!confirm('Connect the kiosk to "' + ssid + '"?')) return;
  try {
    await post('/api/wifi/connect', {ssid, password: $('#wPass').value, hidden: $('#wHidden').checked});
    $('#wPass').value = '';
    showWifiResult({state: 'connecting', message: 'Connecting to ' + ssid + '…'});
  } catch (e) { toast(e.message, true); }
};

async function refreshStatus() {
  try { const d = await api('/api/config'); data.status = d.status; renderStatus(); } catch (e) {}
}

function collect() {
  const local = getRadio('src') === 'local';
  return {
    HOME_URL: local ? (selectedRel ? relToUrl(selectedRel) : '') : $('#url').value.trim(),
    IDLE_MINUTES: $('#idle').value || '0',
    ROTATION: getRadio('rot') || '0',
    SCALE: $('#scale').value,
    OUTPUT: $('#output').value.trim() || 'auto',
    SCHEDULE_ENABLED: $('#schedOn').checked ? '1' : '0',
    SCREEN_ON: $('#tOn').value,
    SCREEN_OFF: $('#tOff').value,
    SCREEN_DAYS: $$('input[name="day"]:checked').map(i => i.value),
    USE_CEC: $('#cec').checked ? '1' : '0',
    PRIVATE_MODE: $('#priv').checked ? '1' : '0',
    HIDE_CURSOR: $('#hideCur').checked ? '1' : '0',
    SAFE_GRAPHICS: $('#safeGfx').checked ? '1' : '0',
    TIMEZONE: $('#tz').value,
    NETWORK_MODE: getRadio('netmode') || 'wifi',
    HOTSPOT_ENABLED: $('#hsOn').checked ? '1' : '0',
    HOTSPOT_PASSWORD: $('#hsPw').value.trim(),
    HOTSPOT_DELAY: $('#hsDelay').value || '2',
    NEW_PASSWORD: $('#pw').value
  };
}

$$('input[name="src"]').forEach(i => i.addEventListener('change', showSource));
$('#schedOn').addEventListener('change', () => $('#schedBox').style.opacity = $('#schedOn').checked ? 1 : .5);

$('#save').addEventListener('click', async () => {
  const body = collect();
  if (!body.HOME_URL) {
    toast(getRadio('src') === 'local' ? 'Tap Use next to a page first' : 'Enter a web address first', true);
    return;
  }
  if (body.NETWORK_MODE === 'offline' && data.config.NETWORK_MODE !== 'offline' &&
      !confirm('Switch to Offline mode? The kiosk will leave Wi-Fi. If your phone reaches it over Wi-Fi, ' +
               'this page will stop responding. Use Ctrl+Alt+W on the kiosk to get back in.')) return;
  try {
    await post('/api/config', body);
    data.config.NETWORK_MODE = body.NETWORK_MODE;
    $('#pw').value = '';
    const cursorChanged = body.HIDE_CURSOR !== data.config.HIDE_CURSOR;
    toast(cursorChanged ? 'Saved - reboot to apply the mouse pointer change' : 'Saved - kiosk is reloading');
    data.config.HIDE_CURSOR = body.HIDE_CURSOR;
    setTimeout(refreshStatus, 1500);
  } catch (e) { toast(e.message, true); }
});

$('#home').addEventListener('click', async () => {
  try { await post('/api/home'); toast('Going home'); } catch (e) { toast(e.message, true); }
});

$$('[data-screen]').forEach(b => b.addEventListener('click', async () => {
  try {
    await post('/api/screen', {state: b.dataset.screen});
    toast(b.dataset.screen === 'auto' ? 'Following schedule' : 'Screen ' + b.dataset.screen);
    setTimeout(refreshStatus, 6000);
  } catch (e) { toast(e.message, true); }
}));

$('#reboot').addEventListener('click', async () => {
  if (!confirm('Reboot the kiosk now?')) return;
  try { await post('/api/reboot'); toast('Rebooting…'); } catch (e) { toast(e.message, true); }
});

$('#shutdown').addEventListener('click', async () => {
  if (!confirm('Shut down the kiosk now?\n\nIt will stay off until someone presses its power button or unplugs and replugs it.')) return;
  try {
    await post('/api/shutdown');
    toast('Shutting down… safe to unplug in about 20 seconds');
  } catch (e) { toast(e.message, true); }
});

load();
setInterval(refreshStatus, 15000);
</script>
</body>
</html>
"""


if __name__ == "__main__":
    os.makedirs(PAGES, exist_ok=True)
    os.makedirs(STATE, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()
PYEOF
chmod 755 /opt/kiosk/kiosk-admin.py

cat > /etc/systemd/system/kiosk-admin.service <<EOF
[Unit]
Description=Kiosk settings web page
After=network.target

[Service]
User=${KIOSK_USER}
Environment=KIOSK_PORT=${ADMIN_PORT}
Environment=KIOSK_PAGES=${PAGES_DIR}
ExecStart=/usr/bin/python3 /opt/kiosk/kiosk-admin.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# Allow the settings page's Reboot / Shut down buttons, time zone and Wi-Fi tools
cat > /etc/sudoers.d/kiosk <<EOF
${KIOSK_USER} ALL=(root) NOPASSWD: /usr/sbin/reboot, /usr/sbin/poweroff, /usr/bin/timedatectl set-timezone *, /usr/bin/nmcli
EOF
chmod 440 /etc/sudoers.d/kiosk
visudo -cf /etc/sudoers.d/kiosk >/dev/null

# ---------- labwc config ------------------------------------------------------
cat > "$KIOSK_HOME/.config/labwc/autostart" <<'EOF'
/usr/local/bin/kiosk-session &
EOF
# Initial rc.xml; kiosk-session rewrites it with the detected output
if [[ ! -f "$KIOSK_HOME/.config/labwc/rc.xml" ]]; then
  cat > "$KIOSK_HOME/.config/labwc/rc.xml" <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <keyboard>
    <keybind key="C-A-s">
      <action name="Execute" command="/usr/local/bin/kiosk-open-settings"/>
    </keybind>
    <keybind key="C-A-w">
      <action name="Execute" command="/usr/local/bin/kiosk-hotspot-toggle"/>
    </keybind>
    <keybind key="C-A-h">
      <action name="Execute" command="/usr/local/bin/kiosk-home --force"/>
    </keybind>
    <keybind key="W-A-h">
      <action name="Execute" command="/usr/local/bin/kiosk-home --force"/>
    </keybind>
  </keyboard>
</labwc_config>
EOF
fi
chown -R "$KIOSK_USER:$KIOSK_GROUP" "$KIOSK_HOME/.config/labwc" "$KIOSK_HOME/.local"

# ---------- auto-login on tty1 and start labwc --------------------------------
for dm in lightdm gdm3 gdm sddm lxdm; do
  if systemctl list-unit-files "${dm}.service" >/dev/null 2>&1 \
     && systemctl list-unit-files "${dm}.service" | grep -q "^${dm}.service"; then
    systemctl disable "${dm}.service" >/dev/null 2>&1 || true
  fi
done
systemctl set-default multi-user.target

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF

BP="$KIOSK_HOME/.bash_profile"
if [[ ! -f "$BP" ]]; then
  printf '# Load the normal profile\n[ -f "$HOME/.profile" ] && . "$HOME/.profile"\n' > "$BP"
fi
sed -i '/^# >>> kiosk >>>$/,/^# <<< kiosk <<<$/d' "$BP"
cat >> "$BP" <<'EOF'
# >>> kiosk >>>
# Start the kiosk on the local screen (not over SSH)
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  mkdir -p "$HOME/.local/state/kiosk"
  export XCURSOR_SIZE=24
  if [ "$(. /etc/kiosk/kiosk.conf 2>/dev/null; echo "${HIDE_CURSOR:-1}")" = "1" ]; then
    export XCURSOR_THEME=kiosk-hidden
  fi
  # Wait for the graphics driver - on some PCs the login is faster than it
  for i in $(seq 1 30); do
    ls /dev/dri/card* >/dev/null 2>&1 && break
    sleep 1
  done
  sleep 3
  # Keep retrying instead of logging out, so a slow start never leaves a
  # black screen (Linux stops auto-login after a few quick failures)
  while true; do
    labwc > "$HOME/.local/state/kiosk/labwc.log" 2>&1
    sleep 5
  done
fi
# <<< kiosk <<<
EOF
chown "$KIOSK_USER:$KIOSK_GROUP" "$BP"

# ---------- services ----------------------------------------------------------
systemctl daemon-reload
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
systemctl enable kiosk-admin.service
systemctl restart kiosk-admin.service
systemctl enable kiosk-netwatch.service
systemctl restart kiosk-netwatch.service

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "=============================================================="
echo " Kiosk installed on $PLATFORM"
echo
echo " Settings page:  http://$(hostname).local:${ADMIN_PORT}"
[[ -n "$IP" ]] && echo "            or:  http://${IP}:${ADMIN_PORT}"
echo " Password:       kiosk   (change it on the settings page)"
echo " Local pages:    $PAGES_DIR"
echo " Logs:           $STATE_DIR"
echo
echo " Setup hotspot:  Wi-Fi 'Kiosk-$(hostname)', password kiosksetup,"
echo "                 settings at http://10.42.0.1:${ADMIN_PORT}"
echo "                 Starts with Ctrl+Alt+W, or by itself after 2 minutes"
echo "                 without a network (Wi-Fi mode)."
echo " Keyboard:       Ctrl+Alt+W setup hotspot   Ctrl+Alt+S settings   Ctrl+Alt+H home"
echo "                 Ctrl+Alt+F2 text login (Ctrl+Alt+F1 to return)"
echo
echo " Reboot now to start the kiosk:  sudo reboot"
echo "=============================================================="
