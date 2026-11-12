# Backing up to a NAS

Groovelight for Mac can back up its data and your music library to a NAS (or any other disk) on its own, at night by default, so the NAS's drives wake once a night and sleep the rest of the day. Your library stays where it is (an internal or external drive); the NAS keeps the copy.

The example here is a **UGREEN DXP2800** on UGOS Pro. Any NAS that shares folders over SMB (Synology, QNAP, TrueNAS, a Windows or Mac share) works the same way.

- [What is backed up](#what-is-backed-up)
- [Set up the NAS](#set-up-the-nas)
- [Set up Groovelight](#set-up-groovelight)
- [How the music backup works](#how-the-music-backup-works)
- [Getting music back](#getting-music-back)
- [Command line and Claude](#command-line-and-claude)
- [Troubleshooting](#troubleshooting)

## What is backed up

The folder you choose gets two folders:

```
Groovelight/
├── Data/      Groovelight Backup 2026-11-12 02.10.groovelightbackup, ...   (the newest N)
│   └── Artwork/   the covers, shared by the backups
└── Music/
    ├── FLAC/  the library folder "FLAC", with its own folders and files
    ├── .Removed/2026-11-12/...   songs removed from the library, kept for a while
    └── .groovelight-mirror.json  what was copied (Groovelight also keeps it on the Mac)
```

- **Data:** playlists and their covers, smart playlists, play counts, ratings, loved songs, metadata fixes, lyrics, artwork, credits and settings, the same as Back Up… in Settings, Backups. Restore one with Restore…. The covers are kept once in `Data/Artwork` for all the backups, and each backup copies only the new ones: every file costs a fraction of a second on a NAS, so copying them all again each night would take minutes. Covers no backup uses any more are removed.
- **Music** (when it is on): each library folder as it is, with the same folders, names and formats, so the copy can be played or used by any app.

## Set up the NAS

On UGOS Pro (the DXP2800's web interface or app):

1. **A shared folder:** Control Panel, Shared Folders, Create: `Backups`, on the hard drive pool (RAID 1 with two drives).
2. **A user for Groovelight:** Control Panel, Users, Create: for example `groovelight`, with read and write access to `Backups` only. Groovelight then cannot touch anything else on the NAS, and it does not get in the way of your own login in the Finder.
3. **SMB on:** Control Panel, File Services, SMB.
4. **Snapshots of `Backups`:** Storage, Snapshots (Btrfs): daily, kept 30 days. Groovelight keeps one copy of your music; the snapshots keep older versions of it, in case a file is damaged on the Mac and the damage is copied.
5. **Let the drives sleep:** Control Panel, Hardware and Power, Hard Drive Hibernation after 20 to 30 minutes. Leave `Backups` out of UGOS's photo and media indexing, or the NAS reads the music and keeps the drives awake.

The NVMe slots are not needed for this: the copy lives on the hard drives, which sleep outside the backup.

## Set up Groovelight

In Groovelight, Settings, Backups:

1. **Folder:** Choose…, then the `Backups` share in the sidebar (connect to it once in the Finder with Go, Connect to Server, `smb://dxp2800.local/Backups`), and a folder in it, for example `Groovelight` (New Folder).
2. **Connect to the NAS as:** the shared folder (filled in), the user `groovelight` and its password, then Save. The password goes in your Keychain. Groovelight connects with it when the share is not connected (after a restart, a sleep, or when you ejected it), with no dialog. The folder line shows the result, for example "Groovelight on Backups, 3.2 TB free", or why it could not connect ("The NAS refused the user groovelight").
3. **Every** Day, **When** At night (2:00 to 6:00). A night missed (the Mac off or asleep) is made up later in the day. **Only when this Mac is plugged in** for a laptop.
4. **Also when Groovelight is closed:** Groovelight opens hidden at night when a backup is due, then quits. macOS asks you to allow it once in System Settings, General, Login Items. Groovelight only runs at night if the Mac is awake then: a Mac that sleeps backs up when it wakes, or set it to wake in System Settings, Energy (or with `sudo pmset repeat wake MTWRFSU 01:55:00`).
5. **Music:** turn on **Back up the music library** and choose the library folders. **Keep removed songs** 30 days.
6. **Back Up Now** to start. The first copy of the music takes as long as copying the whole library over the network (about 3 hours for 1 TB over wired gigabit Ethernet, longer on Wi-Fi). It goes on over several nights if it has to, from where it stopped.

## How the music backup works

- **Only what changed:** Groovelight keeps a list of what it copied (on the Mac and on the NAS), and compares it with your library folders, which are on the Mac. So it reads the NAS only to copy, and the NAS's drives stay asleep when there is nothing to do.
- **Renamed files are moved, not copied again:** a file renamed or moved by Organize keeps its size and date, and its contents are compared to be sure.
- **Edited files are copied again:** a tag edit or a fixed cover changes the file.
- **Nothing is deleted at once:** songs gone from the library move to `Music/.Removed/<date>/` on the NAS, and are deleted after the days you chose (or never).
- **Offline folders are left alone:** a library folder on an unplugged drive is skipped, and its copy stays as it is.
- **A folder that lost many files waits:** when a library folder has more than a quarter fewer files than last time (more than 20), its backup waits and Settings asks whether that was on purpose (Back Up Anyway). A notification says so too.
- **Quitting during a backup:** Groovelight asks first: Quit When Done, Quit Now (the data backup does not count and runs again, the music goes on from where it stopped next time), or Cancel.
- **Whole files only:** each file is copied under a hidden temporary name and renamed when complete, so a copy cut short (the NAS or the Wi-Fi gone, the Mac asleep) never replaces a good one. The next run goes on where it stopped.
- **Checked:** each new copy is read back and compared with the original, and every month a sample (1%) of the copies is read again. A damaged or missing copy is copied again.
- **Not copied onto itself:** a library folder that is on the NAS already (music played from the NAS) is left out.

## Getting music back

In Settings, Backups, Music, **Restore…**:

- **Play from NAS:** the library folder's songs point at their copy on the NAS, with their play counts, playlists and ratings. For when a drive is lost or away: play from the NAS while you get a new one.
- **Copy Back…:** copies the whole folder to a folder you choose (a new drive) and points the library at it.
- **Removed songs:** albums removed in the last days, to put back where they were (Put Back).

**A new Mac:** restore the data backup (Restore… with the newest one in `Data`; Groovelight then asks for the `Data` folder too, for the covers beside it). Groovelight asks to locate each library folder: **Use NAS Copy** plays it from the NAS at once, or locate it on a drive.

## Command line and Claude

```sh
groovelight backup status     # where backups go, the last and next one, the music backup's last run
groovelight backup now        # back up now (--data-only for the data alone)
```

Claude can do the same with the `backup_status` and `back_up_now` tools: see [CLI.md](CLI.md) and [MCP.md](MCP.md).

## Troubleshooting

- **"Not reachable":** the NAS is off or asleep and does not wake for the network, the Mac is on another network, or the share's name changed. Try Again connects once more; Groovelight also tries again every 15 minutes in the night window.
- **"The NAS refused the user":** the user or password changed on the NAS, or the user has no access to the shared folder. Type the password again and Save.
- **"Groovelight cannot write to this folder":** the user has read access only. Give it read and write access to the shared folder.
- **"Not enough space":** the NAS has less free space than the files to copy. Nothing is copied until there is room.
- **The drives wake during the day:** check that UGOS's indexing leaves `Backups` alone, and that no other app on the Mac browses the share.
- **Windows:** backups to a NAS are not in Groovelight for Windows yet.
