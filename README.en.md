# Procman

[中文](README.md) | **English**

A small macOS menu bar app that keeps track of all the "stuff running in the background" and "things you're waiting on" during local development.

> The app UI is currently in Chinese only.

## Why

A typical work session these days looks like this: a model is training, a script is crunching data, two or three AI assistants are writing code in separate windows, and a terminal is running the frontend and backend dev servers. Each of these takes minutes to hours, so you keep switching between them. Sooner or later:

- **You forget something is still running**: a server you started yesterday is still holding the port, or a job finished long ago and nobody looked at it
- **You can't tell which one is done**: you click through a dozen windows only to find "this one is still going, that one stopped half an hour ago waiting for my reply"
- **You lose context**: you switch back to a window and can't remember what you asked it to do or what the next step was
- **You're blind once you leave the desk**: at a meeting or lunch, you have no idea whether the job finished or crashed

Procman tries to fix exactly that:

- All background services in one place — **what's running, for how long, on which port, and what it just printed** — and quitting Procman doesn't take them down with it
- Pin the windows you're waiting on to a wall with live thumbnails; **"active" vs. "idle for 20 min"** tells you at a glance which one needs you
- Attach a one-line note to each window, like "copy the model off when training is done", so **you know what you were doing the moment you switch back**; park what you don't need right now as a paused to-do, out of the way but not forgotten
- Check it from your phone, so **you know the progress even away from the computer**, and restart a service if needed

In short: when you're juggling many things at once, you no longer have to keep in your head what's running, what's waiting, and how far along each one is.

## At a glance

- **Services**: give long-running commands (frontend dev server, API, training scripts, crawlers…) a directory and a command; start/stop with one click, watch live output, auto-detect listening ports
- **Window wall**: pin windows you're waiting on to a wall with live thumbnails, showing which ones are "still moving" and how long the others have been idle
- **To-dos**: jot down loose ends; paused and closed windows become to-dos too, and return to the wall automatically when the window reopens
- **Phone remote**: a companion Android app that finds and connects to your Mac on the LAN automatically — read logs, start/stop services and watch the window wall from the couch

<p align="center">
  <img src="docs/mac-wall.png" width="820" alt="Window wall">
</p>

<p align="center">
  <img src="docs/mac-services.png" width="820" alt="Services">
</p>

<p align="center">
  <img src="docs/phone-wall.png" width="200" alt="Phone: window wall">
  <img src="docs/phone-services.png" width="200" alt="Phone: services">
  <img src="docs/phone-detail.png" width="200" alt="Phone: service detail and logs">
  <img src="docs/phone-memos.png" width="200" alt="Phone: to-dos">
</p>

> All services, windows and to-dos in the screenshots are demo data.

## Features

### Services

- A service = name + working directory + command (run with zsh, multi-line allowed; optionally `source ~/.zshrc` first so conda / nvm / pyenv work)
- Start, stop (SIGTERM to the whole process group, SIGKILL after 8 s), restart; optional autostart with Procman and auto-restart on crash (gives up after 5 rapid crashes in a row)
- Output goes straight to a log file (`~/.procman/logs/<id>.log`, rotated at 20 MB); quitting or upgrading Procman doesn't affect running services, and they're adopted again on relaunch
- Detects the ports a service actually listens on and probes whether they speak HTTP; copy or open in the browser with one click
- Warns before starting if the port is taken and shows who holds it, with a one-click "kill it and start"; a "Ports" window lists every listening port on the machine
- Start/stop right from the menu bar; can launch in the background at login

### Window wall

- Global hotkeys to mark the current window (`⌃⌥M`) or a whole app (`⌃⌥⇧M`), with an optional note: "waiting for training", "upload once ops confirms"
- Live thumbnails; in the background it also takes small periodic snapshots to compare, labeling each window "active" or "idle for x min" — so you can see at a glance which job has finished
- Click a card to jump to that window (even across Spaces), `1`–`9` to jump quickly, `⌃⌥W` to show / hide
- Window IDs change when an app or the Mac restarts; Procman re-attaches marks by title / project name
- **Pause monitoring**: right-click → "Pause monitoring (move to to-dos)" takes the window off the wall as a "paused" to-do; click ▶ to put it back
- **Closed windows**: a noted window that's been closed for 20 s automatically becomes a to-do, and returns to the wall when it reopens

### To-dos

- A to-do column on the right of the wall; `⌃⌥N` to jot one down from anywhere
- Check off, edit in place, drag to reorder; paused windows get their own group

### Phone remote (Android)

- Procman on the Mac runs a WebSocket server on the LAN (default port 7788, falls back to another if taken) and advertises `_procman._tcp` via Bonjour
- The Android app discovers Procman on the LAN; the first connection must be approved in a dialog on the Mac, after which it connects automatically and reconnects on drop
- From the phone you can: view wall thumbnails and idle times, tap to bring that window to the front on the Mac, pause / resume / stop monitoring; view service status and live logs, start / stop / restart; add, edit and delete to-dos
- For safety, the phone **cannot** create services or change their commands
- Paired devices are managed under Settings → Phone Remote on the Mac and can be removed at any time

## Install

### Mac

Requires macOS 15+ and the Xcode Command Line Tools (`xcode-select --install`); full Xcode is not needed.

```sh
git clone https://github.com/blackwhite084/procman.git
cd procman
bash make-cert.sh   # optional, once: creates a local signing certificate so rebuilds keep their permissions
./build.sh          # builds and installs to ~/Applications/Procman.app
open ~/Applications/Procman.app
```

The window wall needs two system permissions (links are in Procman's settings):

- **Screen Recording**: thumbnails and window titles
- **Accessibility**: jumping to the exact window

Restart Procman once after granting them (services are not affected). Without a stable signing certificate every rebuild has to be re-authorized, which is why running `make-cert.sh` first is recommended.

### Android

The app lives in [`mobile/`](mobile) and is written in Flutter.

```sh
cd mobile
flutter build apk --release --split-per-abi --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Put the phone and the Mac on the same LAN and open the app — it finds the Mac by itself. If it doesn't, enter the address manually (shown under Settings → Phone Remote on the Mac).

> `mobile/android` lists the Aliyun Maven mirrors first for faster builds in mainland China; the official repositories are still used as fallback.

## Data and configuration

Everything lives in `~/.procman/` (override with the `PROCMAN_HOME` environment variable):

| File | Contents |
|---|---|
| `services.json` | Service definitions |
| `logs/` | Service output |
| `state.json` | Running processes, used to adopt them after Procman restarts |
| `marks.json` | Window wall marks and notes |
| `memos.json` | To-dos |
| `remote.json` | Paired phones and their tokens |

Other environment variables: `PROCMAN_NAME` sets the Mac name shown on the phone; `PROCMAN_DEBUG=1` prints debug logs. `Procman --diagnose` checks the window wall's capture and window-focusing paths and writes the result to `~/diagnose.txt`.

## Remote protocol

WebSocket; text frames are JSON (field `t` is the message type), binary frames are window thumbnails (4-byte big-endian window ID + JPEG). See the comment at the top of [`Sources/Remote.swift`](Sources/Remote.swift). The connection is LAN-only and unencrypted; the token only identifies paired devices — do not expose the port to the internet.

## License

[AGPL-3.0](LICENSE). You're free to use, modify and distribute it; if you distribute a modified version or offer it as a network service, you must release the source under the same license.

For use in closed-source products or other commercial licensing, please contact the author.
