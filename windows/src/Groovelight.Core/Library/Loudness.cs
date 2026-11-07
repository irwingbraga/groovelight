using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>The library side of loudness measuring (songs without ReplayGain tags are measured in the background).</summary>
public static class LoudnessQueries
{
    /// <summary>Songs whose loudness is unknown: no ReplayGain tag and never measured, most recently added first.</summary>
    public static List<long> TrackIdsNeedingLoudness(this SqliteConnection db, int limit) => db.Column<long>("""
        SELECT id FROM track WHERE replayGainTrackGain IS NULL AND loudnessCheckedAt IS NULL
        ORDER BY dateAdded DESC LIMIT ?
        """, limit);

    /// <summary>Which of <paramref name="ids"/> still need measuring.</summary>
    public static List<long> TrackIdsNeedingLoudness(this SqliteConnection db, IReadOnlyList<long> ids)
    {
        if (ids.Count == 0) return [];
        var found = db.Column<long>($"""
            SELECT id FROM track WHERE id IN ({string.Join(",", ids.Select(_ => "?"))})
            AND replayGainTrackGain IS NULL AND loudnessCheckedAt IS NULL
            """, [.. ids.Cast<object?>()]).ToHashSet();
        return ids.Where(found.Contains).ToList();
    }

    public static (int Measured, int Total) LoudnessProgress(this SqliteConnection db) =>
        (db.Scalar<int>("SELECT COUNT(*) FROM track WHERE replayGainTrackGain IS NULL AND loudnessCheckedAt IS NOT NULL"),
         db.Scalar<int>("SELECT COUNT(*) FROM track WHERE replayGainTrackGain IS NULL"));
}

public sealed partial class LibraryDatabase
{
    /// <summary>Saves a song's measured loudness (null: could not be measured; it is not tried again).</summary>
    public void SetLoudness(double? loudness, long trackId) =>
        Write(db => db.Execute("UPDATE track SET loudness = ?, loudnessCheckedAt = ? WHERE id = ?", loudness, DateTime.UtcNow, trackId));
}
