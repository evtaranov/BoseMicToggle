<img src="icon-preview.png" width="128" align="right" alt="">

# BoseMicToggle

The play/pause button on your Bluetooth headset mutes and unmutes your
microphone in Zoom.

A small macOS menu bar agent. No dependencies: a single Swift file built with
the system `swiftc`.

- The menu bar icon reflects the microphone state
- Audio feedback on every toggle
- `Ctrl+Alt+Cmd+M` hotkey
- Listens for the button only during a meeting, and is idle otherwise

## Why this is not straightforward

During a call the headset switches from A2DP to the HFP profile (16 kHz mono).
In HFP the multifunction button is call control, not a media key: the headset
sends the AT command `AT+CHUP` ("hang up") over RFCOMM.

The system `bluetoothd` receives that command and never forwards it to
applications. Verified absent from:

| Layer | Result |
|---|---|
| CGEvent stream (`hs.eventtap`, Karabiner) | the press never arrives |
| MediaRemote / `MPRemoteCommandCenter` | never arrives (only a synthesized media key does) |
| HID (`IOHIDManager`) | no device is created for a Bluetooth headset; the Consumer-Control `Headset` devices that do exist belong to the built-in codec, i.e. the 3.5 mm jack |
| RFCOMM (`IOBluetoothRFCOMMChannel`) | the channel is owned by the system; a second listener cannot attach |

The only public way to observe the press is the unified log: `bluetoothd`
writes `Received call hangup event (AT+CHUP) from device <address>` and does
not redact the address. The agent reads `log stream` with a narrow predicate.

**This is system log scraping.** No public API exists for this signal, and the
wording of the message is not a contract: Apple may rename it in any macOS
update and the trigger will silently stop working. The **Check button signal**
menu item reports how many presses the system logged in the last 10 minutes,
which makes that failure obvious.

## Requirements

- macOS 13+ (tested on macOS 26)
- Apple Silicon (`build.sh` hardcodes `arm64`; change `-target` for Intel)
- Zoom with an English or Russian interface (see `micMenuTitles` in the source)
- Xcode command line tools: `xcode-select --install`

## Install

```sh
git clone https://github.com/evtaranov/BoseMicToggle.git
cd BoseMicToggle
./build.sh
open -a ~/Applications/BoseMicToggle.app
```

Then grant **Accessibility** -- without it the agent cannot read Zoom's menu:

> System Settings → Privacy & Security → Accessibility

Add `~/Applications/BoseMicToggle.app` with `+` and switch it on, then restart
the agent (**Quit** in its menu, then `open -a` again).

Verify the permission took effect:

```sh
grep 'accessibility trusted' ~/Library/Logs/BoseMicToggle.log | tail -1
```

### Start at login

```sh
./install-autostart.sh              # install
./install-autostart.sh --uninstall  # remove
```

The script generates a LaunchAgent containing your own path: `launchd` does not
understand `~` and requires an absolute one. The agent is launched through
`/usr/bin/open` rather than the binary directly, so the app keeps the bundle
identity that its Accessibility grant is tied to.

## Configuration

Everything below applies without rebuilding; restart the agent afterwards.

```sh
# Feedback volume, as a fraction of the system volume
defaults write io.github.bosemictoggle soundVolume -float 0.75

# Sounds: file names from /System/Library/Sounds.
# The reversed: prefix plays a sound backwards, which is how you get a pair
# sharing one timbre, one rising and one falling.
defaults write io.github.bosemictoggle soundUnmuted reversed:Bottle
defaults write io.github.bosemictoggle soundMuted Bottle
defaults write io.github.bosemictoggle soundFailed Basso

# Dump Zoom's menu to the log on next launch -- needed if Zoom renames its
# items and the toggle stops finding them
defaults write io.github.bosemictoggle dumpMenu -bool true
```

Reversed sounds are cached in `~/Library/Application Support/BoseMicToggle/`.
Delete that folder to regenerate them.

## How it works

| File | Purpose |
|---|---|
| `main.swift` | the whole agent |
| `build.sh` | builds the `.app` into `~/Applications` |
| `make-icon.swift` | draws the icon in code, builds `AppIcon.icns` |
| `Info.plist` | `LSUIElement` -- an agent with no Dock icon |
| `install-autostart.sh` | the login LaunchAgent |

Inside `main.swift`:

- **Trigger** -- `log stream` over `bluetoothd` with a predicate on `AT+CHUP`.
  It runs only during a meeting, because the `log` process costs around 7% CPU.
  If it dies (after sleep, for instance) it is restarted.
- **Muting** -- pressing `Meeting → Mute/Unmute audio` through Accessibility.
  No menu is opened and focus never moves to Zoom.
- **Meeting detection** -- the presence of that same menu item; Zoom does not
  show it outside a meeting. Polled every 4 seconds, which also yields the
  microphone state for the icon.

## Known limitations

- **Zoom only.** Other applications would need their own muting path.
- **The button sends "hang up".** That is inert in Zoom, but if a real call is
  running in parallel (FaceTime, or a phone call relayed from an iPhone), the
  same press will end it. macOS acts on this before the agent sees the event.
- **Permissions reset on every rebuild.** The build is ad-hoc signed, so the
  code hash changes and macOS treats each build as a new application. The only
  fix is removing the entry from the Accessibility list with `-` and adding it
  again; toggling the checkbox on the stale entry does nothing. A stable
  signing identity instead of ad-hoc would end this.
- **Tied to Zoom's menu item titles.** English and Russian are supported; for
  another language add entries to `micMenuTitles`.

## Troubleshooting

```sh
tail -f ~/Library/Logs/BoseMicToggle.log
```

Button presses are visible in the system log independently of the agent:

```sh
log show --last 10m --debug --predicate 'eventMessage CONTAINS "AT+CHUP"'
```

Nothing there after pressing the button means the signal is not reaching macOS,
or Apple reworded the message. Entries there while the agent does nothing means
the problem is on the agent's side -- check its log.

## License

MIT
