# ClaudeDrop

A drop box for Claude on macOS. Press a hotkey, drop in a link, note, screenshot or file, pick a project, and Claude can read it later through a local connector.

ClaudeDrop is an independent community project. It is not affiliated with, endorsed by, or supported by Anthropic.

## How it works

ClaudeDrop has two parts:

- **The app**: a small menu bar app (Swift). Control+Option+D opens a floating panel where you paste or drag things and file them under a project.
- **The connector**: a zero-dependency MCP server (Node) that lets Claude list and open what you saved.

Everything stays on your Mac, in `~/ClaudeDrop/Inbox/<Project>/`. Nothing is uploaded until Claude opens an item in a conversation.

## Requirements

- macOS 13 or later
- Xcode command line tools, to build the app (`xcode-select --install`)
- Node.js 18 or later, to run the connector
- The Claude desktop app, or Claude Code

## Install

```bash
git clone https://github.com/AI-Gizmos/ClaudeDrop.git
```

```bash
cd ClaudeDrop && ./install.sh
```

The installer:

1. Copies the source to `~/ClaudeDrop` and builds the app into `~/Applications/ClaudeDrop.app`.
2. Adds a `claudedrop` entry to the Claude desktop app's `claude_desktop_config.json`. The previous file is saved next to it as `claude_desktop_config.json.bak-before-claudedrop`.
3. Launches the app.

Quit and reopen the Claude desktop app afterwards so it loads the connector.

### Claude Code

The installer only registers the connector with the desktop app. For Claude Code, add it yourself:

```bash
claude mcp add --scope user claudedrop -- node ~/ClaudeDrop/connector/server.mjs
```

## Use

- **Control+Option+D** opens the panel. The menu bar icon does the same.
- **Command+V** stages whatever is on the clipboard: files, an image, a link or text. You can also drag things onto the panel.
- Add an optional note, pick a project (or create one with **+**), and press **Return**.
- **Pin to Top** keeps the panel open after each add.
- **Launch at Login** is in the menu bar menu.

Then, in Claude, mention the drop box: "check my drop box for the Website project". Claude lists the new items and opens the ones it needs.

PDFs, Word documents, RTF and HTML files have their text extracted when you drop them, so Claude can read them. Large images are downscaled before they are sent.

### Archiving

Once Claude has opened an item and brought it up with you, it archives that item without asking and tells you so. Archived items stay on disk in `Inbox/<Project>/archived/` and Claude can restore them on request. Nothing is deleted.

### Command line

```bash
~/Applications/ClaudeDrop.app/Contents/MacOS/ClaudeDrop --add "Project name" ~/Desktop/notes.pdf https://example.com "a plain note"
```

## Configuration

- **Hotkey**: set at build time. Edit the three `hotKey…` lines at the top of `src/main.swift` and run `./build.sh`. If another app already holds the hotkey, ClaudeDrop logs the failure and the menu bar icon still works.
- **Inbox location**: set `CLAUDEDROP_INBOX` to a folder path for both the app and the connector. The default is `~/ClaudeDrop/Inbox`.

## Security notes

- The connector only reads and moves files inside the inbox folder.
- Anything you drop is passed to Claude as content when it opens the item. Treat dropped web pages and documents from other people like any other untrusted input to a model.
- The app is signed ad hoc on your machine when you build it. No prebuilt binary is distributed.

## Uninstall

1. Turn off **Launch at Login** in the menu bar menu, then choose **Quit ClaudeDrop**.
2. Delete `~/Applications/ClaudeDrop.app`.
3. Remove the `claudedrop` entry from `~/Library/Application Support/Claude/claude_desktop_config.json`. For Claude Code, run `claude mcp remove claudedrop`.
4. Delete `~/ClaudeDrop`. This also deletes everything in your inbox, so move anything you want to keep first.

## Layout

```
src/         Swift sources for the menu bar app
connector/   MCP server (server.mjs)
build.sh     Builds the app and copies it to ~/Applications
install.sh   Full install: copy, build, register the connector, launch
```

## License

MIT. See [LICENSE](LICENSE).
