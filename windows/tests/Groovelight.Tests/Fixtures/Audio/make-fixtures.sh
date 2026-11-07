#!/bin/sh
# Makes the audio fixtures: one second of a 440 Hz tone, mono, untagged, one file per format the library reads.
# Needs ffmpeg (with libmp3lame, libopus). The tests copy them and write tags with TagLib#.
set -e
cd "$(dirname "$0")"
tone="-f lavfi -i sine=frequency=440:sample_rate=44100:duration=1 -ac 1 -map_metadata -1 -y -loglevel error"
ffmpeg $tone -c:a flac tone.flac
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=96000:duration=1 -ac 1 -map_metadata -1 -y -loglevel error -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 tone-hires.flac
ffmpeg $tone -c:a libmp3lame -b:a 320k tone.mp3
ffmpeg $tone -c:a aac -b:a 256k tone-aac.m4a
ffmpeg $tone -c:a alac tone-alac.m4a
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=44100:duration=1 -ac 2 -map_metadata -1 -y -loglevel error -c:a vorbis -strict -2 tone.ogg
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=48000:duration=1 -ac 1 -map_metadata -1 -y -loglevel error -c:a libopus -b:a 160k tone.opus
ffmpeg $tone -c:a pcm_s16le tone.wav
ffmpeg $tone -c:a pcm_s16be tone.aiff
ffmpeg $tone -c:a wavpack tone.wv
ffmpeg $tone -c:a tta tone.tta
ffmpeg $tone -c:a mp2 -b:a 192k tone.mp2
