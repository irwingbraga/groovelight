# Groovelight command line

`groovelight` controls Groovelight from Terminal, scripts and AI tools: look things up in the library, import music (songs, folders, archives), fix metadata, organize files, make playlists and control playback.

It ships inside the app (`Groovelight.app/Contents/Helpers/groovelight`) and never opens the library itself: every command goes to the running app, which does the work with the same code as its windows. So the library, undo and the windows stay in step, and the tool always matches the app it came with. When Groovelight is not running, the tool starts it in the background.

For Claude and other AI tools, the same commands are available as an MCP server: see [MCP.md](MCP.md).

- [Install](#install)
- [Quick start](#quick-start)
- [How names are matched](#how-names-are-matched)
- [Commands](#commands): [library](#library), [import and files](#import-and-files), [metadata](#metadata), [playlists](#playlists), [playback](#playback), [mcp](#mcp)
- [Output, JSON and exit codes](#output-json-and-exit-codes)
- [Scripting examples](#scripting-examples)
- [Troubleshooting](#troubleshooting)

## Install

Groovelight is sandboxed, so it cannot put the tool in your `PATH` itself. Run this once in Terminal (Settings, General, Command Line shows it with a Copy button):

```sh
sudo mkdir -p /usr/local/bin && sudo ln -sf '/Applications/Groovelight.app/Contents/Helpers/groovelight' /usr/local/bin/groovelight
```

It is a link: updates of the app update the tool. Check it with:

```sh
groovelight --version
groovelight status
```

Requirements: Groovelight 0.4 or later (the first version with the tool), macOS 15 or later, and a library folder (Settings, Library) for imports.

## Quick start

```sh
groovelight status                                        # library size, folders, what is playing
groovelight search karma police                           # artists, albums and songs (songs with their ids)
groovelight import ~/Downloads/album.zip --dry-run         # what an import would do
groovelight import ~/Downloads/album.zip --trash-archives # do it, then move the archive to the Trash
groovelight undo                                          # take the last import (or organize) back
groovelight fix-metadata --album "OK Computer" --dry-run  # tag changes from the best MusicBrainz release
groovelight play --song "Karma Police" --artist Radiohead
groovelight create-playlist "Road Trip" --songs 2798 2765 2801
```

Every command has help: `groovelight help <command>` or `groovelight <command> --help`.

## How names are matched

Commands that take a name (`--album`, `--artist`, `--playlist`, `--folder`) match it ignoring case and accents. The exact name wins; otherwise a part of the name is enough when only one thing contains it. When several match, the command stops and lists them: add `--artist` to tell albums with the same title apart, or be more specific.

Songs are best given by id: `groovelight search` shows them in brackets (`[2798] Living Inside Myself by Gino Vannelli, Nightwalker`) and in its JSON.

## Commands

### Library

#### `status`

The app's version, the number of songs, albums and artists, each library folder (its song count, whether it is available, which one imports go to) and what is playing.

```sh
groovelight status [--json]
```

#### `search`

Searches titles, artists, albums, lyrics and credits.

```sh
groovelight search <query> ... [--limit <n>] [--json]
```

| Option | |
|---|---|
| `--limit <n>` | How many of each kind (artists, albums, songs) to show. Default 10. |

#### `rescan`

Checks every file of every library folder (like Settings, Library, Rescan Now) and reports what was added, updated, removed and could not be read.

```sh
groovelight rescan [--json]
```

### Import and files

#### `import`

Imports songs, folders or archives into the library, like File, Import in the app: songs are identified on MusicBrainz, tagged and named with your naming settings (Settings, Files), then moved into the library folder.

```sh
groovelight import <paths> ... [--folder <name>] [--copy] [--no-online] [--no-tags] [--trash-archives] [--dry-run] [--json]
```

| Option | |
|---|---|
| `<paths>` | Songs, folders, cue sheets or archives: zip, 7z, rar, tar (also `.tar.gz`, `.tgz`, `.tar.bz2`, `.tar.xz`). |
| `--folder <name>` | The library folder to import into (its name or path). Default: the one set in Settings, Library, Import into. |
| `--copy` | Copy the files instead of moving them. Songs from archives are always moved out of the temporary folder they were extracted to. |
| `--no-online` | Keep the files' own tags instead of the metadata found on MusicBrainz. |
| `--no-tags` | Do not write tags and covers into the files. |
| `--trash-archives` | Move each archive to the Trash once everything from it is imported (only when none of its songs failed). Undo puts it back. |
| `--dry-run` | Show each album as identified and where each file would go, without changing anything. |

Songs already in the library are left out. Archives are extracted with the `bsdtar` that comes with macOS; password-protected and multi-part archives are not supported.

How the sandboxed app gets to read your files: the tool opens them with Groovelight through Launch Services, the way Finder's Open With does, which gives the app access to exactly those paths until it quits.

Since that access lasts, some places are refused (the tool, the MCP server and the app all check, after following symbolic links): `/`, your home folder as a whole and the folders above it, `/Volumes` itself, `~/Library` (except iCloud Drive in `~/Library/Mobile Documents` and cloud storage in `~/Library/CloudStorage`), hidden folders in your home (such as `~/.ssh`), and system folders (`/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/sbin`, `/etc`, `/opt`). Point the import at the folder or archive with the music instead.

Symbolic links inside an archive are removed after it is extracted: a "song" in a download cannot point at another file on your Mac.

#### `organize`

Renames and moves files with the naming settings (Settings, Files), like Library, Organize Library Files.

```sh
groovelight organize [--album <title>] [--artist <name>] [--dry-run] [--json]
```

| Option | |
|---|---|
| `--album <title>` | Only this album's files. |
| `--artist <name>` | Only this artist's files (or, with `--album`, the album's artist). |
| `--dry-run` | Show the new names without renaming anything. |

Without `--album` and `--artist` it plans the whole library.

#### `undo`

Undoes the last import or organize, like Library, Undo Import / Undo Organize Files: imported songs leave the library (moved back where they came from, or their copies removed), organized files get their old names. For an archive that was moved to the Trash, the archive comes back and the songs taken from it go to the Trash; otherwise those songs are removed, since the archive still has them.

```sh
groovelight undo [--json]
```

### Metadata

#### `fix-metadata`

Fixes an album's tags with a release found on MusicBrainz, like Fix Metadata in the app: album, album artist, year, genre, track and disc numbers, titles, MusicBrainz ids and the cover.

```sh
groovelight fix-metadata (--album <title> [--artist <name>] | --artist <name> | --songs <id> ...)
                         [--search-album <title>] [--search-artist <name>]
                         [--release <id> | --auto] [--include-unmatched] [--no-cover]
                         [--write-tags | --no-write-tags] [--dry-run] [--json]
```

| Option | |
|---|---|
| `--album <title>` | The album to fix. |
| `--artist <name>` | The album's artist, to tell albums with the same title apart; alone, every song of the artist. |
| `--songs <id> ...` | Songs to fix as one album (for an album whose songs were imported with mixed-up tags). |
| `--search-album`, `--search-artist` | What to search MusicBrainz for instead of the songs' own album and artist. `""` leaves the field out of the search. |
| `--release <id>` | The MusicBrainz release to apply. |
| `--auto` | Apply the best match. |
| `--include-unmatched` | Also give the album's details (album, album artist, year, genre) to songs that are not on the release, keeping their own titles and numbers. |
| `--no-cover` | Keep the current cover. |
| `--write-tags`, `--no-write-tags` | Write the tags into the files too, or only in the library. Default: the setting in Settings, Metadata. |
| `--dry-run` | Show the changes song by song, and the other releases found, without changing anything. |

Nothing is applied blindly: without `--release` or `--auto`, the command lists the releases it found and exits with an error asking you to choose. The usual flow:

```sh
groovelight fix-metadata --album "OK Computer" --dry-run      # the best match, its changes, the other releases
groovelight fix-metadata --album "OK Computer" --release 52709206-8816-3c12-9ff6-f957f2f1eecf
```

Metadata fixes cannot be undone (as in the app). When a file cannot be written, the fix is kept in the library and the command names the file.

### Playlists

#### `playlists`

Lists the playlists with their song counts (smart playlists are marked).

```sh
groovelight playlists [--json]
```

#### `create-playlist`

Creates a playlist of songs, in the order given, with a generated cover showing its name. It appears in the sidebar at once.

```sh
groovelight create-playlist <name> --songs <id> ... [--json]
```

A name already used by a playlist is refused (add to that one instead), and so are ids that are not songs of the library (nothing is created then).

#### `add-to-playlist`

Adds songs at the end of a playlist, found by name. Smart playlists cannot take songs: their rules choose them.

```sh
groovelight add-to-playlist <playlist> --songs <id> ... [--json]
```

### Playback

#### `play`

```sh
groovelight play [--song <title>] [--songs <id> ...] [<query> ...] [--album <title>] [--artist <name>] [--playlist <name>] [--shuffle] [--json]
```

What plays, in this order:

1. `--songs <id> ...`: those songs, in that order.
2. `--song <title>`: one song, the exact title first. `--artist` and `--album` narrow it down (`--song "Living Inside Myself" --artist "Gino Vannelli"` is that song, not every song of the artist).
3. `<query>`: the songs a search finds, narrowed by `--artist` and `--album` when given.
4. `--album <title>`: the album (`--artist` tells albums apart).
5. `--artist <name>`: every song of the artist.
6. `--playlist <name>`: the playlist.
7. Nothing: resume.

`--shuffle` shuffles what is played.

#### `pause`, `resume`, `play-pause`, `next`, `previous`, `stop`

```sh
groovelight pause | resume | play-pause | next | previous | stop [--json]
```

Each prints what is playing afterwards.

#### `now-playing`

The song playing (or paused), its album, and the position.

```sh
groovelight now-playing [--json]
```

### `mcp`

Runs the MCP server for Claude and other AI tools over stdin and stdout. It is not meant to be run by hand: see [MCP.md](MCP.md).

```sh
groovelight mcp
```

## Output, JSON and exit codes

- **Results** go to standard output, as text for people.
- **Progress** of long commands (import, fix-metadata, organize, rescan) goes to standard error, on one line in a terminal and a line per step otherwise, so it never mixes with the result.
- **`--json`** prints the result as JSON instead (pretty-printed, keys sorted). On an error it prints `{"error": "…", "data": …}`, with `data` holding what there is (the releases found, for example).

| Exit code | Meaning |
|---|---|
| 0 | Done. |
| 1 | The command failed: the app reported an error (no such album, busy with another command), or the app could not be reached or started. |
| 64 | The command was not right: an unknown option, a missing argument. |

JSON shapes (fields without a value are left out):

| Command | `data` |
|---|---|
| `status` | `version`, `build`, `songs`, `albums`, `artists`, `folders` (`path`, `songs`, `available`, `importsHere`), `nowPlaying` |
| `search` | `artists` (names), `albums` (`title`, `artist`, `year`, `songs`), `songs` (`id`, `title`, `artist`, `album`, `albumArtist`, `year`, `trackNumber`, `discNumber`, `genre`, `duration`, `path`, `loved`, `plays`) |
| `import` | `dryRun`, `folder`, `albums` (`album`, `artist`, `matchedRelease`, `songs`: `source`, `destination`, `alreadyInLibrary`); after an import also `imported`, `skipped`, `failed`, `trashedArchives` |
| `fix-metadata` | `dryRun`, `release` (`id`, `title`, `artist`, `year`, `country`, `tracks`, `format`), `matched`, `songs`, `changes` (`id`, `title`, `path`, `changes`: `field`, `from`, `to`), `cover`, `candidates`; after applying also `updated`, `failedWrites` |
| `organize` | `dryRun`, `checked`, `renames` (`from`, `to`, `numbered`) |
| `undo` | `undone` |
| `rescan` | `added`, `updated`, `removed`, `unreadable` |
| `play` | `playing` |
| `now-playing` and playback commands | `id`, `title`, `artist`, `album`, `state` (`playing`, `paused`, `stopped`), `position`, `duration` (seconds); `null` when nothing is playing |
| `playlists` | `playlists` (`id`, `name`, `smart`, `songs`) |
| `create-playlist`, `add-to-playlist` | `id`, `name`, `smart`, `songs` |

## Scripting examples

Import every archive in Downloads, one at a time:

```sh
for archive in ~/Downloads/*.{zip,7z,rar}(N); do
    groovelight import "$archive" --trash-archives || echo "Not imported: $archive"
done
```

Find a song's id:

```sh
groovelight search "living inside myself" --json | jq '.songs[] | {id, album}'
```

A playlist from a search:

```sh
ids=($(groovelight search "gino vannelli" --limit 50 --json | jq '.songs[].id'))
groovelight create-playlist "All Gino" --songs $ids
```

Albums whose tags would change:

```sh
groovelight fix-metadata --album "Brother to Brother" --dry-run --json | jq '.changes | length'
```

What is playing, for a status bar:

```sh
groovelight now-playing --json | jq -r 'if . == null then "" else "\(.title) - \(.artist)" end'
```

## Troubleshooting

| Message | What to do |
|---|---|
| `Groovelight is not installed` | Install the app in Applications. The tool looks for the app around itself first, then by its bundle id. |
| `Groovelight did not start` | Open Groovelight once yourself (macOS may ask to confirm the first launch), then try again. |
| `Groovelight did not answer in time. It may be showing a dialog` | The app is waiting on a dialog, often a keychain or permission prompt: answer it and try again. |
| `Groovelight is busy with another command` | One import, fix, organize or rescan runs at a time: try again when it is done. |
| `Several albums match` | Add `--artist`, or use more of the title. |
| `Add a library folder first` | Imports go into a library folder: add one in Settings, Library. |
| `Another copy of Groovelight is answering the command line` (Settings) | Two copies of the app are running (an installed one and a build): quit one. Debug builds use their own channel, so this means two copies of the same kind. |
| A protocol version error | The tool and the app come from different builds: use the tool inside the app (`/usr/local/bin/groovelight` links to it). |

How the tool and the app talk (the message port, jobs, file access) is described for developers in [DEVELOPMENT.md](DEVELOPMENT.md#command-line-tool).
