# drome-lord

this is a small server that speaks mpd to ncmpcpp and subsonic to navidrome, and hands playback to
mpv. library gets cached in sqlite so browsing is instant. i needed this cause i don't want to use samba or nfs lol

## what works

- browsing (media library, browser, search), queue, stored playlists (= subsonic playlists)
- gapless playback through mpv, idle, command lists, scrobbling
- visualizer feed for ncmpcpp (linux/pipewire only)
- `drome-lord cover`: album art pane for kitty/ghostty, also inside tmux

## build

needs zig 0.17.0 and mpv. sqlite and stb_image are fetched by `zig build`.

```
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

## config

`~/.config/drome-lord/config`:

```
urls = http://music.local:4533, https://music.example.com  # first one that answers wins
port = 6600
mpv_args = --gapless-audio=weak --replaygain=album
visualizer = localhost:5555  # optional, leave out to disable
```

`~/.config/drome-lord/credentials`, `chmod 600`:

```
username = me
password = wat
```

## ncmpcpp

```
mpd_host = 127.0.0.1
mpd_port = 6600
visualizer_data_source = localhost:5555
visualizer_output_name = visualizer
visualizer_in_stereo = yes
visualizer_type = spectrum
```

the cover pane doubles as the now-playing display and draws the progress bar, so ncmpcpp can
hide its own header, statusbar and progress bar:

```
header_visibility = no
statusbar_visibility = no
progressbar_look = ""
```

a wide strip along the bottom of the tmux window, ncmpcpp above it:

```
tmux split-window -v -l 9 'drome-lord cover'    # or a ghostty split
drome-lord cover --layout vertical     # force image-on-top (auto picks it for tall panes)
drome-lord cover --no-text             # image only
drome-lord cover --no-image            # text only, for terminals without graphics
```

wide panes (cols >= rows*4) get cover on the left and the text block on the right; tall ones get
the cover on top. title / artist / album · year / progress bar with times / repeat-single-random-
consume + volume, in kanagawa colours with nerd font icons. needs `allow-passthrough on` in tmux.

## service

systemd user unit, `~/.config/systemd/user/drome-lord.service`, then
`systemctl --user enable --now drome-lord`:

```
[Unit]
Description=drome-lord
After=network-online.target

[Service]
ExecStart=%h/.local/bin/drome-lord
Restart=on-failure

[Install]
WantedBy=default.target
```

launchd agent, `~/Library/LaunchAgents/local.drome-lord.plist`, then
`launchctl load` it (PATH needs homebrew so mpv is found):

```
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.drome-lord</string>
  <key>ProgramArguments</key><array><string>/Users/YOU/.local/bin/drome-lord</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
```

## not done yet

- visualizer on macos (no pipewire there)
- real regexes in `=~` filters, `modified-since`
- `addtagid`/`cleartagid`, fingerprints, crossfade/mixramp (stored but not applied)
- cover pane is untested outside ghostty/kitty
