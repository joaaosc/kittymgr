# kittymgr

Safe, reversible configuration manager for the [kitty](https://sw.kovidgoyal.net/kitty/) terminal.

[![CI](https://github.com/joaaosc/kittymgr/actions/workflows/ci.yml/badge.svg)](https://github.com/joaaosc/kittymgr/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)

kittymgr organizes a kitty setup into profiles you can switch between, without ever
rewriting your `kitty.conf` by hand. It adds a single fenced `include` line to your
config and keeps everything it manages in its own folder. Every change is backed up
first and can be undone.

Use it to keep separate setups (work, personal, presentations), try themes and
keybindings safely, and reproduce the same kitty configuration on another machine.

## How it works

kittymgr adds one clearly marked block to the **top** of your `kitty.conf`:

```
# >>> kittymgr (managed) >>>
# Managed by kittymgr. Do not edit inside these markers.
include kittymgr/active.conf
# <<< kittymgr (managed) <<<
```

Everything below that block stays yours and always wins, because kitty applies the
last setting it reads. kittymgr only ever touches its own `kittymgr/` folder and that
single include line. Switching a profile just rewrites `kittymgr/active.conf` and asks
kitty to reload. Before any change, kittymgr takes a snapshot, so `backup restore`
returns you to exactly where you were.

<!-- Drop a screenshot or GIF at docs/screenshot.png to show the terminal UI here. -->
![kittymgr terminal UI](docs/screenshot.png)

## Install

Every release ships a prebuilt, checksum-verified binary. No toolchain required.

### Requirements

- macOS 13 or later, or Linux with glibc (x86_64).
- Optional: `kitty` on your PATH (enables config validation and live reload) and
  `git` (for installing themes/plugins from git). Both are optional — kittymgr works
  without them and tells you what is missing via `kittymgr doctor`.

### macOS (without Homebrew)

Download the installer, read it, preview what it will do, then run it:

```sh
curl -fsSLO https://raw.githubusercontent.com/joaaosc/kittymgr/main/install.sh
less install.sh                # review before running
sh install.sh --dry-run        # shows platform, release, and target; writes nothing
sh install.sh                  # installs to ~/.local/bin/kittymgr
```

Prefer a manual download? Grab `kittymgr-<version>-macos-universal.tar.gz` and
`SHA256SUMS` from the [releases page](https://github.com/joaaosc/kittymgr/releases):

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
tar -xzf kittymgr-<version>-macos-universal.tar.gz
install -m 0755 kittymgr-<version>-macos-universal/kittymgr ~/.local/bin/kittymgr
```

### Linux

Same installer — it detects the platform automatically:

```sh
curl -fsSLO https://raw.githubusercontent.com/joaaosc/kittymgr/main/install.sh
less install.sh
sh install.sh --dry-run
sh install.sh
```

Or manually, with `kittymgr-<version>-linux-x86_64.tar.gz` and `SHA256SUMS`:

```sh
sha256sum -c --ignore-missing SHA256SUMS
tar -xzf kittymgr-<version>-linux-x86_64.tar.gz
install -m 0755 kittymgr-<version>-linux-x86_64/kittymgr ~/.local/bin/kittymgr
```

If `~/.local/bin` is not on your PATH, add it:

```sh
export PATH="$HOME/.local/bin:$PATH"   # add to ~/.zshrc or ~/.bashrc to keep it
```

The installer verifies the checksum before doing anything, writes only
`<prefix>/bin/kittymgr`, never uses `sudo`, and reinstalling the same version does
nothing. Use `--prefix DIR` to install elsewhere and `--version X.Y.Z` to pick a
specific release.

### Uninstall

```sh
kittymgr uninstall           # remove the managed block; asks for confirmation first
kittymgr uninstall --purge   # also delete the kittymgr/ folder (--force skips the prompt)
rm ~/.local/bin/kittymgr     # remove the binary
```

## Usage

```sh
kittymgr init                 # attach the managed block to kitty.conf
kittymgr create work          # create a profile
#   put your .conf snippets in kittymgr/profiles/work/, then:
kittymgr switch work          # validate, apply, and reload kitty
kittymgr current              # show the active profile
kittymgr                      # or do it all from the interactive UI (alias: kittymgr ui)
```

Common tasks:

```sh
kittymgr list                          # list profiles
kittymgr theme install gruvbox         # install a theme from the built-in catalog
kittymgr theme switch gruvbox          # one active theme at a time
kittymgr plugin enable theme-sample    # turn a config bundle on for this profile
kittymgr backup list                   # list snapshots
kittymgr backup restore <id>           # roll back to a snapshot
kittymgr doctor                        # check environment and store health
```

Preview any change without writing by adding `--dry-run`; it prints a diff of what
would happen. Every command accepts `--help`.

```sh
kittymgr switch work --dry-run
kittymgr --help
```

Full command reference is in `kittymgr --help`. To build from source instead of using
a release binary, see [How to build](#how-to-build).

## How to build

Requires a Swift 6.1+ toolchain.

```sh
swift build -c release
install -m 0755 .build/release/kittymgr ~/.local/bin/kittymgr
kittymgr --version
```

## Planned features

Ideas on the roadmap. Suggestions and issues are welcome.

- `kittymgr diff <profile>` to compare two profiles side by side.
- Profile import/export as a single shareable file.
- A `--json` output mode for scripting.
- Shell completions for bash, zsh, and fish.
- A first-run wizard that detects an existing kitty setup and offers to import it.
- Optional git integration to version the `kittymgr/` folder automatically.
- A Homebrew tap for one-line installs on macOS and Linux.
- A Brazilian Portuguese (pt-BR) language option for the CLI and UI.
- Prebuilt Linux aarch64 binaries in every release.

## License

Released under the [MIT License](LICENSE).

## Donations

If kittymgr is useful to you and you would like to support its development, you can
sponsor the project here:

- GitHub Sponsors: https://github.com/sponsors/joaaosc

Every contribution is appreciated and helps keep the project maintained.

## Known problems

- The Homebrew tap is not published yet. Use the installer or a manual download for now.
- Only Linux x86_64 has a prebuilt binary. On Linux aarch64 (ARM), build from source
  until an ARM release is published.
- Live reload needs a running kitty with `allow_remote_control` enabled. Without it,
  changes are still saved correctly but you have to reload kitty yourself (restart it,
  or run `kitten @ load-config`).
- The interactive UI (`kittymgr ui`) needs a real terminal. In a pipe or CI it exits
  with a message — use the plain commands with `--dry-run` there instead.
