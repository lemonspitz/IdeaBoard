# Idea Board

An infinite-canvas whiteboard for macOS and the web, in the spirit of Miro: sticky notes, shapes,
text, connectors, freehand pen, frames, images and templates, with **live collaboration**.
Boards save as `.ideaboard` files.

**Use it in the browser:** https://lemonspitz.github.io/IdeaBoard/

## Work together live

Click **Share → Start live session** and send the link. Anyone who opens it (in a browser on
any computer or phone) edits the same board in real time, with live cursors and names. Mac app users
can paste the link or join code into **Share → Join**, or open `ideaboard://join/CODE`.

- Peer-to-peer: the board travels directly between computers over WebRTC. The free public
  PeerJS broker is only used to introduce them; it never sees the board.
- The host's board is the hub. The session lasts while the host keeps the board open; when it ends,
  everyone keeps a copy.
- Undo (⌘Z) only undoes your own changes, never someone else's.
- Very strict company or school networks can block peer-to-peer connections.

## Build

    ./build.sh            # build/Idea Board.app (universal, macOS 13+)
    ./build.sh --install  # also copy to /Applications

The whiteboard engine is one file, `Resources/web/index.html`; it also runs in any browser
(boards autosave to localStorage there). `Sources/main.swift` wraps it in a native window
with File/Edit/View menus, open/save panels, PNG export and autosave to
`~/Library/Application Support/Idea Board`.

## Shortcuts

| Key | Tool / action | Key | Tool / action |
|---|---|---|---|
| V | Select | H / Space-drag | Pan |
| N | Sticky note | T | Text |
| R / O / D | Rectangle / ellipse / diamond | L | Connector |
| P | Pen | E | Eraser |
| F | Frame | I | Image |
| ⌘Z / ⇧⌘Z | Undo / redo | ⌘D, ⌥-drag | Duplicate |
| ⌘C / ⌘X / ⌘V | Copy / cut / paste (text and images too) | ⌫ | Delete |
| ] / [ | Front / back | Enter | Edit text |
| ⌘+ / ⌘− / ⌘0 / ⇧1 | Zoom in / out / 100% / fit | G | Grid |

Double-click empty space for a sticky note. Moving a frame moves everything inside it.
Pasting several lines of text makes one sticky per line.

Self-test: `IDEABOARD_SUPPORT=/tmp/x "build/Idea Board.app/Contents/MacOS/Idea Board" --selftest`

MIT · @lemonspitz
