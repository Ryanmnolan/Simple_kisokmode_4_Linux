# Touchscreen Kiosk Installer

One-command installer that turns a Raspberry Pi or Debian mini PC into a full-screen portrait touchscreen kiosk. Chromium boots straight to your home page (a URL or uploaded pages) and returns home when idle. A phone-friendly settings page handles rotation, screen on/off schedule, time zone, reboot/shutdown and an optional Wi-Fi setup hotspot.

---

## Contents

- [Which version do I need?](#which-version-do-i-need)
- [What you need](#what-you-need)
- [Install](#install)
- [The settings page](#the-settings-page)
- [Adding your own pages](#adding-your-own-pages)
- [Hotspot version: Wi-Fi, Offline mode and setup hotspot](#hotspot-version-wi-fi-offline-mode-and-setup-hotspot)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Updating and switching versions](#updating-and-switching-versions)
- [Troubleshooting](#troubleshooting)
- [Where things live](#where-things-live)
- [Removing the kiosk](#removing-the-kiosk)
- [Security notes](#security-notes)

---

## Which version do I need?

There are two installers. Both install the same kiosk; the hotspot version adds network tools on top.

| | `kiosk-install.sh` (Standard) | `kiosk-install-hotspot.sh` (Hotspot) |
|---|:---:|:---:|
| Boots into full-screen Chromium | ✅ | ✅ |
| Home page from a URL or uploaded pages | ✅ | ✅ |
| File browser, multi-file and folder upload | ✅ | ✅ |
| Return to home page when idle | ✅ | ✅ |
| Portrait rotation with touch mapping | ✅ | ✅ |
| Screen on/off schedule and time zone | ✅ | ✅ |
| Hidden mouse pointer, graphics fix | ✅ | ✅ |
| Reboot and Shut down buttons | ✅ | ✅ |
| Wi-Fi section (scan, connect, forget) | — | ✅ |
| Offline mode (never joins Wi-Fi) | — | ✅ |
| Setup hotspot: Ctrl+Alt+W, or automatic when the network is lost | — | ✅ |
| Ctrl+Alt+S: settings page on the kiosk screen | — | ✅ |

**Pick Standard** if the kiosk always sits on a reliable network and you manage it from a phone or PC on that network.

**Pick Hotspot** if the kiosk may lose Wi-Fi, moves between sites, or should run with no network at all and only be set up when needed.

You can switch between them at any time. See [Updating and switching versions](#updating-and-switching-versions).

---

## What you need

### Hardware

| Device | Notes |
|---|---|
| **Raspberry Pi 5** (recommended) | Best choice. An NVMe SSD is more reliable than an SD card. |
| **Raspberry Pi 4** | Works well. |
| **Raspberry Pi 3B / 3B+** | Works for simple pages. Only 1 GB of RAM, so heavy websites and video struggle. The 3A+ (512 MB) is not enough. |
| **x86 mini PC** (HP, Dell, Lenovo, etc.) | Works well and handles heavy pages smoothly. |

You also need:
- A touchscreen monitor (HDMI for video, USB for touch)
- A proper power supply (Pi 5: the official 27 W USB-C supply)
- A USB keyboard for first setup and emergencies (it can be unplugged afterwards)

### Operating system

| Device | Install this |
|---|---|
| Raspberry Pi | **Raspberry Pi OS Lite (64-bit)**. The Lite version has no desktop; the installer adds only what the kiosk needs. |
| Mini PC | **Debian 13** from the netinst image. In the software selection step, tick only **SSH server** and **standard system utilities**. Leave the root password blank so your user gets `sudo`. |

---

## Install

### Step 1: Prepare the Raspberry Pi (skip for a mini PC)

1. Open **Raspberry Pi Imager** on your computer.
2. Choose your Pi model and **Raspberry Pi OS Lite (64-bit)**, then your SD card or SSD.
3. When asked to customise, set:
   - **Hostname**, e.g. `kiosk`
   - **Username and password**
   - **Wi-Fi name, password and country** (or use Ethernet)
   - **Time zone**
   - **Enable SSH** (Services tab)
4. Write the card, put it in the Pi, connect the screen and power it on.
5. Wait about 2 minutes for the first boot to finish.

### Step 2: Copy the installer to the device

Use either method.

**Option A: Termius, or any SFTP app (easiest)**
1. In Termius, add a host with the device address (`kiosk.local`, or its IP) and your username and password.
2. Open **SFTP**, put your computer on one side and the device on the other.
3. Drag `kiosk-install.sh` (or `kiosk-install-hotspot.sh`) into the home folder on the device.

**Option B: the command line**
```bash
scp kiosk-install.sh youruser@kiosk.local:
```
Or download it directly on the device:
```bash
git clone https://github.com/Ryanmnolan/Simple_kisokmode_4_Linux.git
cd Simple_kisokmode_4_Linux.git
```

### Step 3: Run the installer

Connect to the device over SSH (in Termius, open the host) and run **one** of these:

```bash
sudo bash kiosk-install.sh            # Standard
sudo bash kiosk-install-hotspot.sh    # Hotspot
```

- Enter your password if asked. Nothing appears while you type, which is normal.
- The install takes 5–15 minutes, mostly downloading Chromium.
- At the end, a summary box shows the settings page address.

### Step 4: Reboot

```bash
sudo reboot
```

After about a minute, the screen shows the **"Kiosk is ready"** page with the settings address.

> The first start of Chromium can take 20–60 seconds. A black screen with a cursor, or a white screen, during that time is normal.

<img src="https://github.com/Ryanmnolan/Simple_kisokmode_4_Linux/blob/main/images%2FScreenshot_20261005_081902_Chrome.jpg" alt="Kiosk Ready Examples" width="400">


### Step 5: Open the settings page

From a phone or computer **on the same network**, open:

```
http://kiosk.local:8080
```
or `http://<ip-address>:8080`. The IP address is shown on the kiosk screen.

- Username: anything (it is ignored)
- **Password: `kiosk`**

**Change the password straight away** in the **Settings password** section.

---

## The settings page

All changes take effect when you tap **Save & apply** at the bottom of the page. The kiosk reloads within a few seconds.

The status line at the top shows whether the screen is on, which video output is in use, the kiosk's name and its IP address.

### Home page

Choose what the kiosk shows:

- **Web address:** any `http://` or `https://` address (dashboards, websites, Node-RED, Home Assistant, etc.)
- **Page on the kiosk:** a page stored on the kiosk itself, which works without internet. See [Adding your own pages](#adding-your-own-pages).

### Return to home page when idle

After this many minutes with no touches, the kiosk reloads the home page. Set it to `0` to turn this off. It only reloads if someone actually used the screen, so a dashboard is not reloaded for nothing.

### Display

| Setting | What it does |
|---|---|
| **Rotation** | 0° landscape, 90° / 270° portrait, 180° upside down. Touch input follows the rotation automatically. If portrait is upside down, switch between 90° and 270°. |
| **Zoom** | Makes everything larger (100–200%). |
| **Video output** | Leave as `auto`. Only change it if the device has two screens connected (e.g. `HDMI-A-1`, `DP-1`). |
| **Hide mouse pointer** | On by default. Takes effect after a reboot. |
| **Graphics compatibility mode** | On by default. Fixes a blank white screen on some Pi setups. Turn it off only if video or animations look choppy. |

### Screen on/off schedule

| Setting | What it does |
|---|---|
| **Time zone** | Set this first. The schedule uses the kiosk's own clock, shown under the box. |
| **Use schedule** | Turns the schedule on. |
| **Screen on / Screen off** | Times of day. Overnight spans work too, e.g. on 18:00, off 02:00. |
| **Days** | Days the screen turns on. On unticked days it stays off all day. |
| **HDMI-CEC** | Also puts a TV to sleep and wakes it (TVs only; most monitors ignore it). |
| **Screen on / Screen off / Follow schedule** | Manual control right now. A manual change lasts until the next scheduled change. |

The schedule turns off only the **screen**. The computer keeps running, so it is ready instantly. Touching the screen during off hours does not wake it; use the **Screen on** button.

### Privacy

**Private mode** forgets logins, cookies and history every time the kiosk returns to the home page. Use it for public kiosks where people may log in to things.

### System

- **Reboot kiosk:** restarts the device.
- **Shut down kiosk:** turns the device off safely. To turn it back on, press the power button (Pi 5 and mini PCs) or unplug and replug the power (Pi 3/4).

### Go home now

The button at the bottom reloads the home page on the kiosk immediately.

---

## Adding your own pages

Choose **Page on the kiosk** in the Home page section to open the file browser.

### Upload

| Button | Use it for |
|---|---|
| **Upload files** | Pick one or many files at once (HTML, images, CSS, JS, fonts, video). They go into the folder you have open. Works on phones and computers. |
| **Upload folder** | Copies a whole site folder, including subfolders. Works on computers. |
| **+ Folder** | Makes a new folder to upload into. |
| **Drag and drop** | On a computer, drag files onto the list. |

- A **.zip** file is unpacked automatically into its own folder.
- A file with the same name **replaces** the old one, so to update a site you just upload it again.
- If an upload includes an `index.html`, it is selected as the home page for you.

### Browse and choose

- Tap a **folder name** to open it. Use the path at the top (or **.. back**) to go up.
- **Use** sets that page as the home page. The page in use is highlighted.
- **View** opens a preview in a new tab.
- **Delete** removes a file or a folder.
- Tap **Save & apply** to show the chosen page on the kiosk.

The built-in **welcome** page cannot be deleted, so there is always a page to fall back on.

### Tips for your own pages

- Use **relative links** (`img/logo.png`, not `C:\Users\...\logo.png`).
- Design for the screen size you are using, e.g. 1080 × 1920 for a portrait 1080p monitor.
- Pages are served from `http://localhost:8080/pages/...`, so `fetch()` and other JavaScript work normally.

---

## Hotspot version: Wi-Fi, Offline mode and setup hotspot

These features exist only in `kiosk-install-hotspot.sh`. They live in the **Network** section of the settings page.

### Network mode

| Mode | Behaviour |
|---|---|
| **Use Wi-Fi** | Joins your saved Wi-Fi. If the network is lost for a few minutes, the setup hotspot can start automatically (see below). |
| **Offline (no Wi-Fi)** | Never joins Wi-Fi and shows pages stored on the kiosk. Nothing on a network can reach it. Wired Ethernet is left alone. |

Switching to Offline over Wi-Fi disconnects your phone. Use **Ctrl+Alt+W** to get back in.

### Wi-Fi section

- **Connected to:** what the kiosk is connected to right now.
- **Networks nearby:** tap **Scan**, then **Choose** to fill in the name.
- **Password** and **Hidden network**, then **Connect**.
- **Saved networks:** **Forget** removes a network. To make the kiosk join only one network, forget all the others.

If the kiosk moves to a different network from your phone, the page stops responding. Join your phone to the same network and open the address shown on the kiosk screen.

### Setup hotspot

The setup hotspot is the kiosk's own Wi-Fi network:

- **Name:** `Kiosk-<hostname>` (e.g. `Kiosk-kiosk`)
- **Password:** `kiosksetup` (change it in the settings)
- **Settings page:** `http://10.42.0.1:8080`

It starts in two ways.

**1. On demand with Ctrl+Alt+W** (any network mode, including Offline):
1. Plug a USB keyboard into the kiosk and press **Ctrl+Alt+W**.
2. Within a few seconds the screen shows **"Set up this kiosk"** with the network name, password and address.
3. On your phone, join that Wi-Fi and open `http://10.42.0.1:8080`.
4. Upload pages, change the home page or adjust any setting.
5. Press **Ctrl+Alt+H** to see the home page while setup mode stays on (useful for checking new pages).
6. When you are done, press **Ctrl+Alt+W** again or tap **Turn off setup hotspot** on the settings page.

The setup hotspot turns itself off after **30 minutes with no phone connected**, and stays on as long as a phone is connected.

**2. Automatically when the network is lost** (Use Wi-Fi mode only):
1. After the network has been down for the set time (default 2 minutes), the hotspot starts.
2. The screen shows **"Connect this kiosk to Wi-Fi"** with the steps.
3. Join the hotspot from your phone, open `http://10.42.0.1:8080`, go to **Wi-Fi**, pick a network and tap **Connect**.
4. While the hotspot is on, the kiosk retries its saved Wi-Fi every 10 minutes. It skips the retry while a phone is connected, so you are not dropped. When the network comes back, the hotspot turns off by itself.

Hotspot settings, saved with **Save & apply**:
- **Start it automatically if Wi-Fi is lost:** on or off
- **Hotspot password:** 8–63 letters or numbers
- **Start after:** minutes offline before the hotspot starts

> The hotspot is a small private network that only reaches the kiosk. It does not bridge to any other network.

---

## Keyboard shortcuts

Plug in a USB keyboard to use these on the kiosk.

| Keys | Action | Version |
|---|---|---|
| **Win+Alt+H** | Go to the home page | Both |
| **Ctrl+Alt+F2** | Text login screen (for commands) | Both |
| **Ctrl+Alt+F1** | Back to the kiosk from the text login | Both |
| **Ctrl+Alt+H** | Go to the home page | Hotspot |
| **Ctrl+Alt+S** | Open the settings page on the kiosk screen (sign in with the settings password) | Hotspot |
| **Ctrl+Alt+W** | Setup hotspot on/off | Hotspot |

---

## Updating and switching versions

Copy the new or other installer to the device and run it, then reboot:

```bash
sudo bash kiosk-install.sh            # switch to / update Standard
sudo bash kiosk-install-hotspot.sh    # switch to / update Hotspot
sudo reboot
```

- Your settings, password and uploaded pages are kept.
- Running the Standard installer removes the hotspot parts if they were installed.
- Running an installer twice is safe.

To use a different settings port, set it when installing:
```bash
sudo ADMIN_PORT=9000 bash kiosk-install.sh
```

---

## Troubleshooting

Most checks need SSH (Termius) or the text login (**Ctrl+Alt+F2**, then log in).

### Collect the logs

Paste this whole block and look at, or share, the output:
```bash
echo "=== session ==="; tail -n 30 ~/.local/state/kiosk/session.log
echo "=== chromium ==="; tail -n 40 ~/.local/state/kiosk/chromium.log
echo "=== labwc ==="; tail -n 20 ~/.local/state/kiosk/labwc.log
echo "=== server ==="; systemctl status kiosk-admin --no-pager | head -n 5
curl -s http://localhost:8080/api/info; echo
```

### White screen

- Wait 60 seconds on the first boot; Chromium is slow to start the first time.
- Make sure **Graphics compatibility mode** is on (Display section).
- Tap **Go home now** on the settings page.

### Black screen with a mouse pointer

Chromium is not starting. If `chromium.log` says *"The profile appears to be in use by another Chromium process"*, which happens after the device is renamed, clear the lock:
```bash
rm -f ~/.kiosk-chromium/Singleton*
```
Current installers clear this lock automatically.

### Can't reach the settings page or SSH

The IP address may have changed after a reboot.
- Try the name instead: `http://kiosk.local:8080`
- Check your router's device list, or use a network scanner app such as **Fing**
- On the kiosk: **Ctrl+Alt+F2**, log in, run `hostname -I`

To stop the address changing, set a **DHCP reservation** for the kiosk in your router (or ask IT).

### Not connected to Wi-Fi

From the text login (**Ctrl+Alt+F2**):
```bash
nmcli device status                      # is wlan0 connected?
sudo nmcli device wifi list              # networks the kiosk can see (q to quit)
sudo nmcli device wifi connect "NetworkName" password "ThePassword"
```
`sudo nmtui` gives a simple menu instead. On the Hotspot version, you can also press **Ctrl+Alt+W** and use the Wi-Fi section from your phone.

Guest networks sometimes block devices from seeing each other ("client isolation") or need a sign-in page. In that case, use a different network or Ethernet.

### "sudo: unable to resolve host"

This harmless warning appears after changing the device name. The installer fixes it; to fix it by hand:
```bash
echo "127.0.1.1 $(hostname)" | sudo tee -a /etc/hosts
```

### Schedule turns the screen on/off at the wrong time

Set the **Time zone** in the schedule section and tap **Save & apply**. Check the **Kiosk clock** line under it.

### Picture is upside down or sideways

Change **Rotation**. For portrait, try both 90° and 270°.

### Touch is offset or in the wrong place

Reboot once after changing rotation. If it still happens, set **Video output** to the exact name shown in the status line instead of `auto`.

---

## Where things live

| Path | What |
|---|---|
| `/etc/kiosk/kiosk.conf` | All settings (edited by the settings page) |
| `~/kiosk-pages/` | Uploaded pages; you can also copy files here over SFTP |
| `~/.local/state/kiosk/` | Logs and runtime state |
| `~/.kiosk-chromium/` | Chromium profile |
| `/opt/kiosk/kiosk-admin.py` | Settings page server (service `kiosk-admin`) |
| `/usr/local/bin/kiosk-session` | Starts the display, idle timer and Chromium |
| `/usr/local/bin/kiosk-screen` | Screen on/off schedule |
| `/usr/local/bin/kiosk-home` | Returns to the home page |
| `/usr/local/bin/kiosk-netwatch` | Network mode and hotspot (Hotspot version, service `kiosk-netwatch`) |
| `/run/kiosk-net/netwatch.log` | Hotspot log (Hotspot version) |

How it works: the device logs in automatically on the screen and starts **labwc** (a lightweight Wayland window manager), which starts **Chromium** in kiosk mode. A small Python web server on port 8080 provides the settings page and serves your uploaded pages. No desktop environment is installed.

---

## Removing the kiosk

```bash
sudo systemctl disable --now kiosk-admin kiosk-netwatch 2>/dev/null
sudo rm -f /etc/systemd/system/kiosk-admin.service /etc/systemd/system/kiosk-netwatch.service
sudo rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
sudo rm -f /etc/sudoers.d/kiosk
sed -i '/^# >>> kiosk >>>$/,/^# <<< kiosk <<<$/d' ~/.bash_profile
sudo rm -rf /opt/kiosk /etc/kiosk /usr/share/icons/kiosk-hidden
sudo rm -f /usr/local/bin/kiosk-*
sudo nmcli connection delete KioskHotspot 2>/dev/null
sudo systemctl daemon-reload
sudo reboot
```
Your uploaded pages in `~/kiosk-pages` are left in place; delete them by hand if you no longer need them.

---

## Security notes

- **Change the settings password** from the default `kiosk`, and on the Hotspot version change the hotspot password from `kiosksetup`.
- The settings page uses plain HTTP with a password. Keep the kiosk on a trusted network.
- Uploaded pages under `/pages/` can be viewed without a password by anyone on the network. Don't upload anything private.
- The settings page can reboot or shut down the device, set the time zone and (Hotspot version) manage Wi-Fi. These are the only admin permissions the kiosk user is given.
- Anyone with a USB keyboard at the kiosk can use **Ctrl+Alt+F2** to reach a login prompt; they still need the account password. Use a strong one.
