using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>
/// The SQLite library. Its schema, migrations and value formats are the Mac's (GRDB), so a library database or a
/// backup made on one opens on the other. Reads may run on any thread; writes are serialized.
/// </summary>
public sealed partial class LibraryDatabase : IDisposable
{
    private readonly string connectionString;
    /// <summary>Keeps an in-memory database alive between connections.</summary>
    private readonly SqliteConnection? keepAlive;
    private readonly Lock writeLock = new();

    /// <summary>Raised after every write, for views to refresh (GRDB's observation on the Mac).</summary>
    public event Action? Changed;

    private LibraryDatabase(string connectionString, bool inMemory)
    {
        this.connectionString = connectionString;
        if (inMemory)
        {
            keepAlive = new SqliteConnection(connectionString);
            keepAlive.Open();
        }
        using var connection = Open();
        if (!inMemory)
        {
            // GRDB's DatabasePool works in WAL mode.
            connection.Execute("PRAGMA journal_mode = WAL");
        }
        Migrations.Migrate(connection);
    }

    /// <summary>Opens (or creates) the database at <paramref name="path"/>.</summary>
    public static LibraryDatabase Open(string path)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!);
        var builder = new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = true };
        return new LibraryDatabase(builder.ToString(), inMemory: false);
    }

    /// <summary>In-memory database, for tests.</summary>
    public static LibraryDatabase InMemory()
    {
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = $"file:groovelight-{Guid.NewGuid():N}?mode=memory&cache=shared",
            Mode = SqliteOpenMode.Memory,
            Cache = SqliteCacheMode.Shared,
        };
        return new LibraryDatabase(builder.ToString(), inMemory: true);
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection(connectionString);
        connection.Open();
        // Another Groovelight on this library may be writing: wait for it rather than fail.
        connection.Execute("PRAGMA busy_timeout = 10000");
        connection.Execute("PRAGMA foreign_keys = ON");
        SmartPlaylistSql.RegisterFunctions(connection);
        return connection;
    }

    public T Read<T>(Func<SqliteConnection, T> read)
    {
        using var connection = Open();
        return read(connection);
    }

    /// <summary>Runs <paramref name="write"/> in a transaction, then raises <see cref="Changed"/>.</summary>
    public T Write<T>(Func<SqliteConnection, T> write)
    {
        T result;
        lock (writeLock)
        {
            using var connection = Open();
            connection.Execute("BEGIN IMMEDIATE");
            try
            {
                result = write(connection);
                connection.Execute("COMMIT");
            }
            catch
            {
                connection.Execute("ROLLBACK");
                throw;
            }
        }
        Changed?.Invoke();
        return result;
    }

    public void Write(Action<SqliteConnection> write) => Write(connection => { write(connection); return 0; });

    /// <summary>Copies the whole database to <paramref name="path"/> as one self-contained file (for backups).</summary>
    public void BackUp(string path)
    {
        using var source = Open();
        using var destination = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
        destination.Open();
        source.BackupDatabase(destination);
        destination.Execute("PRAGMA journal_mode = DELETE");
    }

    public void Dispose()
    {
        keepAlive?.Dispose();
        SqliteConnection.ClearPool(new SqliteConnection(connectionString));
    }
}

/// <summary>The Mac's migrations, in order, with the same identifiers (GRDB's <c>grdb_migrations</c> table) and DDL.</summary>
internal static class Migrations
{
    private static readonly (string Id, string[] Statements)[] All =
    [
        ("v1", [
            """CREATE TABLE "libraryRoot" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "path" TEXT NOT NULL UNIQUE, "bookmark" BLOB NOT NULL, "addedAt" DATETIME NOT NULL, "lastScanAt" DATETIME)""",
            """CREATE TABLE "track" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "rootId" INTEGER NOT NULL REFERENCES "libraryRoot"("id") ON DELETE CASCADE, "path" TEXT NOT NULL UNIQUE, "fileSize" INTEGER NOT NULL, "modifiedAt" DATETIME NOT NULL, "title" TEXT NOT NULL, "artist" TEXT, "album" TEXT, "albumArtist" TEXT, "composer" TEXT, "genre" TEXT, "year" INTEGER, "trackNumber" INTEGER, "trackTotal" INTEGER, "discNumber" INTEGER, "discTotal" INTEGER, "isCompilation" BOOLEAN NOT NULL DEFAULT 0, "bpm" INTEGER, "comment" TEXT, "lyrics" TEXT, "musicBrainzRecordingId" TEXT, "musicBrainzReleaseId" TEXT, "replayGainTrackGain" DOUBLE, "replayGainAlbumGain" DOUBLE, "duration" DOUBLE NOT NULL, "format" TEXT, "sampleRate" DOUBLE, "bitDepth" INTEGER, "bitrate" DOUBLE, "channels" INTEGER, "artworkHash" TEXT, "albumKey" TEXT NOT NULL, "rating" INTEGER NOT NULL DEFAULT 0, "isLoved" BOOLEAN NOT NULL DEFAULT 0, "playCount" INTEGER NOT NULL DEFAULT 0, "skipCount" INTEGER NOT NULL DEFAULT 0, "lastPlayedAt" DATETIME, "dateAdded" DATETIME NOT NULL)""",
            """CREATE INDEX "track_on_rootId" ON "track"("rootId")""",
            """CREATE INDEX "track_on_albumKey" ON "track"("albumKey")""",
            """CREATE INDEX "track_on_dateAdded" ON "track"("dateAdded")""",
            """CREATE INDEX "track_on_artist" ON "track"("artist")""",
            """CREATE INDEX "track_on_albumArtist" ON "track"("albumArtist")""",
            """CREATE VIRTUAL TABLE "track_ft" USING fts5(title, artist, album, albumArtist, composer, genre, tokenize='''unicode61'' ''remove_diacritics'' ''2''', content='track', content_rowid='id')""",
            """
            CREATE TRIGGER "__track_ft_ai" AFTER INSERT ON "track" BEGIN
                INSERT INTO "track_ft"("rowid", "title", "artist", "album", "albumArtist", "composer", "genre") VALUES (new."id", new."title", new."artist", new."album", new."albumArtist", new."composer", new."genre");
            END
            """,
            """
            CREATE TRIGGER "__track_ft_ad" AFTER DELETE ON "track" BEGIN
                INSERT INTO "track_ft"("track_ft", "rowid", "title", "artist", "album", "albumArtist", "composer", "genre") VALUES('delete', old."id", old."title", old."artist", old."album", old."albumArtist", old."composer", old."genre");
            END
            """,
            """
            CREATE TRIGGER "__track_ft_au" AFTER UPDATE ON "track" BEGIN
                INSERT INTO "track_ft"("track_ft", "rowid", "title", "artist", "album", "albumArtist", "composer", "genre") VALUES('delete', old."id", old."title", old."artist", old."album", old."albumArtist", old."composer", old."genre");
                INSERT INTO "track_ft"("rowid", "title", "artist", "album", "albumArtist", "composer", "genre") VALUES (new."id", new."title", new."artist", new."album", new."albumArtist", new."composer", new."genre");
            END
            """,
            """INSERT INTO "track_ft"("track_ft") VALUES('rebuild')""",
            """CREATE TABLE "playlist" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, "smartRules" BLOB)""",
            """CREATE TABLE "playlistItem" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "playlistId" INTEGER NOT NULL REFERENCES "playlist"("id") ON DELETE CASCADE, "trackId" INTEGER NOT NULL REFERENCES "track"("id") ON DELETE CASCADE, "position" INTEGER NOT NULL)""",
            """CREATE INDEX "playlistItem_on_playlistId" ON "playlistItem"("playlistId")""",
            """CREATE INDEX "playlistItem_on_trackId" ON "playlistItem"("trackId")""",
        ]),
        ("v2-metadata", [
            """ALTER TABLE "track" ADD COLUMN "metadataOverrides" BLOB""",
            """ALTER TABLE "track" ADD COLUMN "fetchedLyrics" TEXT""",
            """ALTER TABLE "track" ADD COLUMN "lyricsCheckedAt" DATETIME""",
            """ALTER TABLE "track" ADD COLUMN "fetchedArtworkHash" TEXT""",
        ]),
        ("v3-lovedAt", ["""ALTER TABLE "track" ADD COLUMN "lovedAt" DATETIME"""]),
        ("v4-playlistCover", ["""ALTER TABLE "playlist" ADD COLUMN "cover" BLOB"""]),
        ("v5-albumInfo", ["""CREATE TABLE "albumInfo" ("albumKey" TEXT PRIMARY KEY NOT NULL, "data" BLOB NOT NULL, "fetchedAt" DATETIME NOT NULL)"""]),
        ("v6-artistInfo", ["""CREATE TABLE "artistInfo" ("artistKey" TEXT PRIMARY KEY NOT NULL, "data" BLOB NOT NULL, "fetchedAt" DATETIME NOT NULL)"""]),
        ("v7-creditIndex", [
            """CREATE TABLE "creditIndex" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "nameKey" TEXT NOT NULL, "artistId" TEXT, "albumKey" TEXT NOT NULL, "trackId" INTEGER, "roles" TEXT NOT NULL, "wholeRelease" BOOLEAN NOT NULL DEFAULT 0)""",
            """CREATE INDEX "creditIndex_on_nameKey" ON "creditIndex"("nameKey")""",
            """CREATE INDEX "creditIndex_on_artistId" ON "creditIndex"("artistId")""",
            """CREATE INDEX "creditIndex_on_albumKey" ON "creditIndex"("albumKey")""",
        ]),
        ("v8-cueTracks", [
            """ALTER TABLE "track" ADD COLUMN "audioPath" TEXT""",
            """ALTER TABLE "track" ADD COLUMN "startTime" DOUBLE""",
            """ALTER TABLE "track" ADD COLUMN "endTime" DOUBLE""",
        ]),
        ("v9-watchState", [
            """ALTER TABLE "libraryRoot" ADD COLUMN "eventId" INTEGER""",
            """ALTER TABLE "libraryRoot" ADD COLUMN "eventsVolumeId" TEXT""",
            """ALTER TABLE "libraryRoot" ADD COLUMN "lastFullScanAt" DATETIME""",
        ]),
        ("v10-lastfmQueue", [
            """CREATE TABLE "lastfmQueue" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "kind" TEXT NOT NULL, "artist" TEXT NOT NULL, "track" TEXT NOT NULL, "album" TEXT, "albumArtist" TEXT, "duration" DOUBLE, "trackNumber" INTEGER, "timestamp" DATETIME NOT NULL, "attempts" INTEGER NOT NULL DEFAULT 0)""",
            """CREATE INDEX "lastfmQueue_on_timestamp" ON "lastfmQueue"("timestamp")""",
        ]),
        ("v11-loudness", [
            """ALTER TABLE "track" ADD COLUMN "loudness" DOUBLE""",
            """ALTER TABLE "track" ADD COLUMN "loudnessCheckedAt" DATETIME""",
        ]),
        ("v12-deviceHistory", [
            """CREATE TABLE "deviceHistoryEvent" ("deviceId" TEXT NOT NULL, "eventId" TEXT NOT NULL, "appliedAt" DATETIME NOT NULL, "localPlaylistId" INTEGER, "playlistId" INTEGER, PRIMARY KEY ("deviceId", "eventId"))""",
        ]),
    ];

    public static IReadOnlyList<string> Identifiers => All.Select(migration => migration.Id).ToList();

    public static void Migrate(SqliteConnection connection)
    {
        connection.Execute("CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)");
        var applied = connection.Column<string>("SELECT identifier FROM grdb_migrations").ToHashSet();
        foreach (var (id, statements) in All)
        {
            if (applied.Contains(id)) continue;
            connection.Execute("BEGIN IMMEDIATE");
            try
            {
                foreach (var statement in statements) connection.Execute(statement);
                connection.Execute("INSERT INTO grdb_migrations (identifier) VALUES (?)", id);
                connection.Execute("COMMIT");
            }
            catch
            {
                connection.Execute("ROLLBACK");
                throw;
            }
        }
    }
}
