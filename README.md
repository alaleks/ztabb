# ztabb

A terminal that stays out of the way: one small native process, a bundled
typeface, and no runtime you have to feed.

Tabs, a VT/xterm emulator, hosts read from `~/.ssh/config`, light and dark
themes, and syntax colouring on the line you are typing.

## What it costs

Measured on this machine, an Apple Silicon Mac, against Tabby running beside it:

|                    | ztabb          | Tabby               |
| ------------------ | -------------- | ------------------- |
| Idle CPU           | **0.1 %**      | 14.3 %              |
| Resident memory    | **110 MB**     | 459 MB              |
| Processes          | **1**          | 5                   |
| On disk            | **8.6 MB**     | 379 MB              |
| Runtime dependency | **SDL3, libc** | Electron / Chromium |

Two honest caveats. Tabby was a live instance with tabs open, not a controlled
baseline — treat it as an order of magnitude, not a benchmark. And most of
ztabb's 110 MB is not ztabb: an empty SDL window with a Metal renderer already
costs 88 MB on this machine. ztabb's own share is about 23 MB, of which the font
atlases on the GPU are the bulk.

What ztabb itself holds is small and bounded:

- **16 bytes** per screen cell.
- **63 KB** for a fresh 120x34 tab — scrollback is not reserved until something
  scrolls.
- **4 MB** ceiling on a tab's history, whatever it is fed.
- **Zero** allocations in the render loop.

## Licence

ztabb is MIT — see `LICENSE`. It bundles glyph data rasterized from **JetBrains
Mono**, which is under the SIL Open Font License 1.1; `NOTICE` records that and
`licenses/JetBrainsMono-OFL.txt` carries the terms.

## Requirements

- Zig 0.16.0
- SDL3 (`brew install sdl3`)

## Build

```sh
zig build                       # build
zig build run                   # build and run
zig build test                  # 298 unit tests
zig build -Doptimize=ReleaseFast

zig build bundle                # zig-out/ztabb.app, with its icon (macOS)
```

`zig build bundle` is what puts the icon in the Dock, Finder and Launchpad:
macOS shows an application icon for a bundle, and a bare executable borrows the
terminal's.

## Install (macOS)

```sh
zig build bundle -Doptimize=ReleaseFast
cp -R zig-out/ztabb.app /Applications/
```

The bundle carries its own copy of SDL3 and is ad-hoc signed, so the installed
app keeps working if Homebrew's formula is upgraded or removed. It is not
signed with a Developer ID; a locally built app is not quarantined, so it opens
without Gatekeeper asking, but a copy downloaded from elsewhere would be.

## Keys

The application modifier is **Cmd** or **Ctrl+Shift** — both work everywhere, so
there is a second option where the system claims a Cmd combination for itself.
Plain Ctrl belongs entirely to the shell, so Ctrl+C, Ctrl+W and Ctrl+R behave as
they always do.

| Key                               | Action                               |
| --------------------------------- | ------------------------------------ |
| `Cmd+T` / `Cmd+N`                 | New tab                              |
| `Cmd+W`                           | Close tab                            |
| `Cmd+1` … `Cmd+9`                 | Go to tab by number                  |
| `Cmd+[` / `Cmd+]`                 | Previous / next tab                  |
| `Cmd+S`                           | SSH host list                        |
| `Cmd+D`                           | Toggle light / dark                  |
| `Cmd+L`                           | Toggle command colouring             |
| `Cmd+=` / `Cmd+-` / `Cmd+0`       | Font size: up / down / back to 13 pt |
| `Cmd+C` / `Cmd+V`                 | Copy selection or line / paste       |
| `Shift+PageUp` / `Shift+PageDown` | Scroll history                       |
| Mouse wheel                       | Scroll history                       |

No binding uses Shift as an extra modifier: under the Ctrl+Shift form it is
already spoken for, and such a combination would be unreachable there.

Mouse: **+** opens a tab, the globe beside it drops down the SSH hosts, a click
selects a tab, **×** closes one. Dragging over the terminal selects a range;
`Cmd+C` copies it, falling back to the cursor's line when nothing is selected.
Typing or switching tabs clears the selection, so what is highlighted is always
what would be copied.

Pasting honours **bracketed paste**: when the program has asked for it, the text
arrives wrapped in markers, so a shell can tell it from typing and will not run
a pasted command until Enter.

`ZTABB_THEME=light ztabb` opens in the light theme.

## Why it is small

**One process, no web stack.** The renderer is SDL3 talking to Metal; there is
no browser engine, no JavaScript runtime and no IPC between helper processes.
The binary links against SDL3 and libc, and nothing else.

**Glyphs are batched by colour.** A colour change flushes SDL's batch, and
setting one per glyph cost 9800 flushes a frame on a full window of ordinary
single-colour output, where 49 suffice. Runs sharing a colour and weight are
drawn together.

**Frames are drawn only when something changed**, and the poll interval backs
off while nothing does — which is why an idle window costs a tenth of a percent
of a core rather than sixty redraws a second of a motionless prompt. A keystroke
wakes it immediately.

**A typed character lands in the frame it was typed in.** After a key press the
loop waits briefly for the shell's echo before drawing, rather than showing it a
frame later.

**History is bounded by bytes, not just rows.** A row cap alone does not hold:
on a wide window every row is expensive, so a tab left on `tail -f` would keep
tens of megabytes for the session. At the ceiling the ring evicts its oldest row
one at a time, so scrollback depth stays constant instead of collapsing by half
periodically. On a 200x50 window the history settles at 4 MB after about five
thousand lines and stays there through half a million.

**Nothing is allocated per frame.** The SSH list, the labels and the highlighter
all work in fixed buffers.

## The terminal

The escape parser is a state machine, so a sequence or a UTF-8 code point split
across a pty read is reassembled rather than mangled. Cursor movement, ED/EL,
insert and delete of lines and characters, scrolling regions (DECSTBM), the
alternate screen (`vim`, `less`, `htop`), DECTCEM, DECSC/DECRC, window title via
OSC 0/1/2, SGR attributes, 256 colours and truecolor.

Scrollback survives a resize: rows are re-laid at the new width, clipped or
padded. Lines are not re-wrapped, as in most terminals.

## The typeface

**JetBrains Mono is built in** — 1067 glyphs, no installation and no font
library. Glyphs live in the executable as antialiased coverage maps, and the
binary links no font machinery at all.

Default size is 13 pt; `Cmd+=` and `Cmd+-` step to 11 and 16. The cell follows
the typeface's own metrics: 0.60 em wide by 1.32 em tall, the full ascent plus
descent, so descenders are not clipped. Every size is baked at 1x and again at
exactly 2x — a bitmap stretched onto a denser backbuffer loses the antialiasing
that makes small text legible.

Interface text — tab labels, dialogs — is set in the real Medium face, a step
smaller than the terminal: at that size Regular goes faint and Bold goes heavy.
It is aligned on the **cap band** rather than the cell, because the cell carries
the whole font box and the room above the capitals is not matched below, which
sets a label low beside the icon next to it.

Coverage includes Latin, Cyrillic, Latin-1, arrows, box drawing, block elements
and **Powerline** (U+E0A0–U+E0B3), so `agnoster` and `powerlevel10k` prompts
render without a Nerd Font. The separators are drawn geometrically rather than
taken from the face: only exact geometry tiles with the cells either side of it
without a seam.

## Icons

Interface icons are signed distance fields evaluated at the exact size they are
drawn, not bitmaps. Strokes are capsules, so caps and joins are round, and their
weight is matched to the interface face's stem so an icon and the label beside
it read as one piece. Being formulas rather than pictures, they are identical on
every display.

The application icon is drawn the same way: a rounded square on the terminal's
own dark ground with a hairline rim, so it does not dissolve into a dark Dock,
and a teal prompt holding 7.6:1 against it — at 16 px the mark has nothing else
helping it. macOS asks for a dozen sizes, and each is rendered at its own
resolution instead of scaled from one master.

## Themes

Light and dark in the spirit of JetBrains' Gerry: a soft blue-grey ground rather
than near-black, with muted accents. Screen cells store **palette indices**, not
resolved RGB, so switching the theme recolours text already on screen. Every
pairing is checked against WCAG in the tests; body text holds 8.8:1 and the
weakest ANSI colour 4.3:1.

## SSH

`~/.ssh/config` is parsed at startup: aliases, `HostName`, `User`, `Port`,
`IdentityFile`, several aliases on one `Host` line, the `Key=value` form, and
`Include` one level deep. Wildcards such as `Host *` are recognised but not
listed — they are defaults, not somewhere to connect.

The globe button or `Cmd+S` opens the list; arrows or the mouse choose, Enter or
a click connects, Esc closes. The chosen host is started as `ssh <alias>` in a
new tab, and the tab takes that name — the remote shell's own title does not
bury which connection it is.

Keys, the agent, `ProxyJump` and `Match` blocks are `ssh`'s business: ztabb
passes the alias and overrides nothing, so whatever works as `ssh <alias>` in
another terminal works here.

## Command colouring

The shell owns its input line, so ztabb does not touch the byte stream — it
colours cells at draw time. It finds the end of the prompt (`$ `, `% `, `# `,
`> `, `❯ `) and colours the command, builtins, options, strings, paths,
variables, operators and comments. It stands aside on the alternate screen and
while the history is scrolled.

## Layout

```
src/
├── main.zig        entry point
├── app.zig         window, event loop, key bindings
├── render.zig      grid, tab bar, overlays
├── terminal.zig    screen model and escape parser
├── pty.zig         pty and child process
├── tabs.zig        tab list
├── theme.zig       light and dark palettes
├── highlight.zig   command-line lexer
├── ssh.zig         ~/.ssh/config parser
├── font.zig        baked typeface and atlas assembly
├── icons.zig       interface icons from distance fields
├── appicon.zig     application icon
├── png.zig         minimal PNG writer, for the .icns
├── macos.zig       transparent title bar (macOS only)
├── font_data.zig   generated: metrics and range table
└── font.dat        generated: 8-bit glyph coverage
tools/
├── genfont.c       typeface generator (only to re-bake it)
├── mkiconset.zig   renders the .iconset for iconutil
└── bundle.sh       assembles ztabb.app
```

Every module builds and tests on its own: `zig build test` runs eleven
independent suites.

### Re-baking the typeface

Only needed to change the character set or the faces. Requires macOS (CoreText)
and JetBrains Mono installed; the result is committed, so an ordinary build
depends on neither. The generator refuses to run if the font is missing rather
than silently baking whatever CoreText substitutes.

```sh
cc -O2 -o /tmp/genfont tools/genfont.c -lm \
   -framework CoreText -framework CoreGraphics -framework CoreFoundation
/tmp/genfont                    # writes src/font.dat and src/font_data.zig
/tmp/genfont 0x41 0x2500        # dump glyphs as ASCII art
```

## Platform

Built and measured on macOS. The core — pty, terminal, tabs, fonts, themes —
takes its constants from the platform rather than hardcoding BSD values, and
cross-compiles to Linux; the build links `libutil` there, where `openpty` lives.
The transparent title bar is macOS-only, and elsewhere the window keeps an
ordinary system title.

## Roadmap

- [x] ZSH and font support
- [x] Light and dark themes, switchable live
- [x] SSH connections from `~/.ssh/config`, with keys
- [x] Command syntax colouring
- [x] Powerline glyphs for `agnoster`-style prompts
- [x] Mouse tab control and icons drawn from geometry
- [x] Application icon and an `.app` bundle
- [x] JetBrains Mono at 13 pt, with size steps
- [x] Memory ceiling on a tab's history
- [x] Mouse selection and copying a range
- [x] Bracketed paste
- [ ] Splitting a tab into panes
- [ ] Custom themes and key bindings from a config file
