# Ask Claude for KOReader

Ask Claude about the book you're reading in KOReader. You ask and read the answers on the Kindle; the computer only runs Claude Code to send answers back, and is where you tune what Claude does through the modules in [`server/modules/`](server/modules/). By default, Claude only sees the text up to your current page.

> [!NOTE]
> This extension is vibe-coded. I mainly use it myself, as an assistant for the books I read on my Kindle.

<p align="center">
  <img src="docs/whos-who.png" width="360" alt="A “Who's who” answer from Ask Claude in KOReader on the Kindle">
  <br>
  <sub>Asking “who is each character?” on the Kindle, early in Chapter 1 of <i>The Picture of Dorian Gray</i>.</sub>
</p>

## Requirements

- Claude Code on the computer, and calibre for EPUB/MOBI books
- KOReader on a Kindle, with `ssh kindle` working
- A Kindle key pair: private key at `koreader/settings/SSH/id_laptop`, public key on the computer at `~/.ssh/kindle_to_laptop.pub`

Both are covered in [docs/setup.md](docs/setup.md).

## Setup

```sh
git clone https://github.com/rfvasile/kindle-askclaude.git
cd kindle-askclaude
SUBNET=192.168.1.0/24 bash setup-laptop.sh
bash install-kindle.sh
```

Then restart KOReader, select some text and tap **Ask Claude…**. More in [docs/usage.md](docs/usage.md).
