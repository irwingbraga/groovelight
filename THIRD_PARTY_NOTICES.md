# Third-party software

Groovelight is licensed under the GNU General Public License v3.0 (see `LICENSE`). It includes the following software, each under its own license. Every license below is compatible with GPL-3.0. The full license texts ship with each package (Swift Package Manager checkouts, Maven artifacts) and are linked here.

## Mac app (Swift packages)

| Software | Used for | License |
|---|---|---|
| [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) and its helpers (AVFAudioExtensions, CXXAudioRingBuffer, CXXDispatchSemaphore, CXXMessageQueue, CXXQueue, CXXUnfairLock) | Decoding and playback | MIT |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | Library database (SQLite) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Updates | MIT (and others, see its repository) |
| [FLAC](https://xiph.org/flac/) | FLAC decoding | BSD-3-Clause |
| [Ogg](https://xiph.org/ogg/), [Vorbis](https://xiph.org/vorbis/), [Opus](https://opus-codec.org), [Speex](https://speex.org) | Ogg, Vorbis, Opus and Speex decoding | BSD-3-Clause |
| [WavPack](https://www.wavpack.com) | WavPack decoding | BSD-3-Clause |
| [Musepack](https://www.musepack.net) | Musepack decoding | BSD-3-Clause (and LGPL-2.1) |
| [Monkey's Audio](https://www.monkeysaudio.com) | APE decoding | BSD-3-Clause |
| [DUMB](http://dumb.sf.net/) | Tracker modules (MOD, S3M, XM, IT) | DUMB license (zlib-style) |
| [TagLib](https://taglib.org) | Reading and writing tags | LGPL-2.1 (dual-licensed with MPL-1.1; used under LGPL-2.1) |
| [mpg123](https://www.mpg123.de) | MP3 decoding | LGPL-2.1 |
| [libsndfile](https://libsndfile.github.io/libsndfile/) | WAV, AIFF and other PCM formats | LGPL-2.1 |
| [LAME](https://lame.sourceforge.io) | MP3 encoding (bundled by SFBAudioEngine) | LGPL-2.0 or later |
| [TTA](https://sourceforge.net/projects/tta/) | True Audio decoding | LGPL-3.0 |

The LGPL libraries are separate dynamic frameworks inside `Groovelight.app/Contents/Frameworks` (TagLib is compiled from source); their source is available at the links above, and Groovelight's own source is this repository.

## Android app (Groovelight Sync)

| Software | License |
|---|---|
| Kotlin standard library and kotlinx.coroutines | Apache-2.0 |
| AndroidX (Activity, Compose, Material 3, Lifecycle, WorkManager, DocumentFile, Core) | Apache-2.0 |

## Online services

Groovelight looks things up in these services when the corresponding settings are on: [MusicBrainz](https://musicbrainz.org) and the [Cover Art Archive](https://coverartarchive.org) (data under CC0; covers belong to their owners), the iTunes Search API (artwork), [LRCLIB](https://lrclib.net) (lyrics, contributed by its users), [Wikipedia and Wikidata](https://www.wikipedia.org) (text under CC BY-SA, shown with a link to the article) and [Last.fm](https://www.last.fm) (scrobbling). Their terms apply to what they return.
