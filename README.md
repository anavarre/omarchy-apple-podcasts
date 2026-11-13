# Apple Podcasts — Omarchy bar widget

A bar icon that opens a panel with your latest Apple Podcasts episodes and plays them.

![Apple Podcasts widget preview](preview.png)

> **Unofficial.** Apple has no public API for your library, so this uses the same private
> endpoints as podcasts.apple.com. It can break whenever Apple changes the site and may
> sit outside Apple's terms. Personal use only.

## Requirements

`mpv` and `socat` (for playback), plus `curl`. With `mpv-mpris` (part of Omarchy's base
install), the player shows up as a regular media player, so media keys, `playerctl` and
dictation tools such as Superwhisper and voxtype can pause the episode.

### Pausing while dictating with Superwhisper

Superwhisper pauses media through a Python helper that runs `env python3`. If a global mise
or pyenv Python without PyGObject comes first in your session `PATH`, that helper fails and
nothing gets paused. When the plugin loads, `bin/podcasts-superwhisper` detects this case,
and only this case. It then writes
`~/.config/systemd/user/superwhisper.service.d/omarchy-apple-podcasts-python.conf`, which
puts `/usr/bin` first in Superwhisper's `PATH`, and restarts Superwhisper once it is idle.
It does nothing if Superwhisper is not installed, already works, or already sets its own `PATH`.

## Install

The easy way, also listed on the [Omarchy plugins directory](https://plugins.omarchy.org/plugin.html?id=anavarre.apple-podcasts):

```sh
omarchy plugin add https://github.com/anavarre/omarchy-apple-podcast.git --enable
```

Or manually, from a local checkout:

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/omarchy-apple-podcasts
omarchy plugin enable anavarre.apple-podcasts
omarchy-shell shell rescanPlugins
omarchy bar move anavarre.apple-podcasts --section right
```

## Sign in

Apple offers no sign-in for third parties, so the widget borrows your web-player session:

1. Open the panel and press **Open podcasts.apple.com**.
2. Sign in with your Apple Account (2FA happens in the browser).
3. Copy the `media-user-token` cookie value (browser dev tools → Storage/Application → Cookies).
4. Paste it into the panel.

The token is stored privately on your computer in `~/.config/omarchy/apple-podcasts/` and is only sent to Apple. Pasting into the sign-in field goes through a bounded clipboard read (2 KiB, 2 second limit); anything larger is rejected.

## Using it

Click an episode to play it. While something plays, a card with large artwork and the controls sits above the list.

| Key | Action |
| --- | --- |
| `Space` / `Enter` | Play the selected episode; pause or resume it if it is already playing |
| `←` / `→` | Skip back / forward |
| `o` | Open the episode on Apple's site |
| `n` | Queue the selected episode; it starts by itself when the current one ends (or right away if nothing is playing) |
| Drag `⠿` | Reorder the queue by dragging an episode by its handle on the right of the row |
| `Shift` + `R` | Remove the selected episode from the queue |
| `Enter` | On a section title (Queue, Unplayed, Played), collapse or expand the section |
| `s` | Stop |
| `Esc` | Close the panel |
| `p` | Switch between unplayed and played episodes |
| `m` | Mark the selected episode as played, without listening to it |
| `,` | Settings |
| `?` | Show the shortcuts (also the `?` icon at the bottom right) |

- **Resume anywhere.** Your position syncs with Apple, so you can switch between your iPhone and this computer.
- **Started episodes come first**, most recently listened to on top. The rest is grouped by podcast feed (the "Group by podcast feed" setting), or sorted by date across shows when that is off.
- **Subscriber-only episodes** can't be played here; the panel says so.

## Settings

Open them from the panel (`,`) or from Omarchy's bar settings:

- Episodes per page (1–30): the panel lists this many, and more load as you arrow past the end or click the pulsing arrow
- Refresh interval
- Latest episodes or your Up Next queue
- Started episodes first, and how the rest is ordered (by show or by date)
- Text size (small, medium, large or extra large; scales all text in the panel)
- Skip back / forward length (10–90 seconds)
- Playback speed

## Uninstall

```sh
omarchy plugin disable anavarre.apple-podcasts
rm ~/.config/omarchy/plugins/omarchy-apple-podcasts
rm -r ~/.config/omarchy/apple-podcasts
omarchy-shell shell rescanPlugins
```

If the plugin added the Superwhisper drop-in (see above), remove it too, or leave it there to keep dictation pausing other players:

```sh
rm ~/.config/systemd/user/superwhisper.service.d/omarchy-apple-podcasts-python.conf
systemctl --user daemon-reload && systemctl --user restart superwhisper
```

The `rm -r` above deletes your saved sign-in token and local listening positions. You can also remove the widget from the bar in Omarchy's bar settings. Your listening history on Apple is untouched.

## License

MIT
