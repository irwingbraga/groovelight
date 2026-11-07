namespace Groovelight.Audio;

/// <summary>Something the player can play. Kept independent of the library database.</summary>
public sealed record PlayableItem
{
    public long Id { get; init; }
    public required string Path { get; init; }
    public string Title { get; init; } = "";
    public string Artist { get; init; } = "";
    public string Album { get; init; } = "";
    public double Duration { get; init; }
    public string? ArtworkPath { get; init; }
    /// <summary>The library's artwork hash (the app's small and large images).</summary>
    public string? ArtworkHash { get; init; }
    /// <summary>For a track of a CUE sheet: where it starts and ends in the file (null end: the end of the file).</summary>
    public double? StartTime { get; init; }
    public double? EndTime { get; init; }
    public double? SampleRate { get; init; }
    /// <summary>Identifies the album (crossfade can skip songs that follow each other on one album).</summary>
    public string? AlbumKey { get; init; }
    /// <summary>Loudness gains in dB (ReplayGain tags, or measured), applied when volume normalization is on.</summary>
    public double? TrackGain { get; init; }
    public double? AlbumGain { get; init; }
    /// <summary>Bits per sample of the file (null for lossy formats), to tell whether the device takes them whole.</summary>
    public int? BitDepth { get; init; }
}

public enum RepeatMode { Off, All, One }

/// <summary>Ordered play queue with shuffle and repeat, plus an "Up Next" area for Play Next / Play Later.</summary>
public sealed class PlayQueue
{
    private List<PlayableItem> items = [];
    /// <summary>Original (unshuffled) order, used to restore when shuffle is turned off.</summary>
    private List<PlayableItem> originalOrder = [];

    /// <summary>Items in play order (already shuffled when shuffle is on).</summary>
    public IReadOnlyList<PlayableItem> Items => items;
    public int? CurrentIndex { get; private set; }
    public RepeatMode RepeatMode { get; set; } = RepeatMode.Off;
    public bool IsShuffled { get; private set; }

    public PlayableItem? Current => CurrentIndex is { } index ? items[index] : null;

    /// <summary>Items after the current one, in order.</summary>
    public IReadOnlyList<PlayableItem> Upcoming => CurrentIndex is { } index ? items[(index + 1)..] : items;

    public IReadOnlyList<PlayableItem> History => CurrentIndex is { } index ? items[..index] : [];

    /// <summary>Replaces the queue and starts at <paramref name="startIndex"/>.</summary>
    public void Set(IReadOnlyList<PlayableItem> newItems, int startIndex = 0, bool shuffle = false, Random? random = null)
    {
        originalOrder = [.. newItems];
        IsShuffled = shuffle;
        if (newItems.Count == 0)
        {
            items = [];
            CurrentIndex = null;
            return;
        }
        var start = Math.Clamp(startIndex, 0, newItems.Count - 1);
        if (shuffle)
        {
            var rest = newItems.ToList();
            var first = rest[start];
            rest.RemoveAt(start);
            Shuffle(rest, random);
            items = [first, .. rest];
            CurrentIndex = 0;
        }
        else
        {
            items = [.. newItems];
            CurrentIndex = start;
        }
    }

    /// <summary>The item that should follow the current one when it ends naturally (used for gapless pre-enqueueing).</summary>
    public PlayableItem? NextForAutoAdvance => CurrentIndex is not { } index ? null : RepeatMode switch
    {
        RepeatMode.One => items[index],
        RepeatMode.All => items.Count == 0 ? null : items[(index + 1) % items.Count],
        _ => index + 1 < items.Count ? items[index + 1] : null,
    };

    /// <summary>Advances after the current item ended on its own.</summary>
    public PlayableItem? AdvanceAfterEnd()
    {
        if (CurrentIndex is not { } index) return null;
        switch (RepeatMode)
        {
            case RepeatMode.One:
                return items[index];
            case RepeatMode.All:
                CurrentIndex = (index + 1) % items.Count;
                break;
            default:
                if (index + 1 >= items.Count)
                {
                    CurrentIndex = null;
                    return null;
                }
                CurrentIndex = index + 1;
                break;
        }
        return Current;
    }

    /// <summary>The user pressed Next: repeat-one does not trap the user on the same track.</summary>
    public PlayableItem? SkipForward()
    {
        if (CurrentIndex is not { } index) return null;
        if (index + 1 < items.Count) CurrentIndex = index + 1;
        else if (RepeatMode == RepeatMode.Off) return null;
        else CurrentIndex = 0;
        return Current;
    }

    public PlayableItem? SkipBackward()
    {
        if (CurrentIndex is not { } index) return null;
        if (index > 0) CurrentIndex = index - 1;
        else if (RepeatMode == RepeatMode.All && items.Count > 0) CurrentIndex = items.Count - 1;
        return Current;
    }

    public PlayableItem? Jump(int itemIndex)
    {
        if (itemIndex < 0 || itemIndex >= items.Count) return null;
        CurrentIndex = itemIndex;
        return Current;
    }

    /// <summary>Marks <paramref name="item"/> as current if it is in the queue (when the engine reports a gapless transition).</summary>
    public void SyncCurrent(PlayableItem item)
    {
        if (CurrentIndex is { } index && items[index] == item) return;
        if (CurrentIndex is { } current && current + 1 < items.Count && items[current + 1] == item) CurrentIndex = current + 1;
        else if (items.IndexOf(item) is var found and >= 0) CurrentIndex = found;
    }

    public void PlayNext(IReadOnlyList<PlayableItem> newItems)
    {
        items.InsertRange((CurrentIndex ?? -1) + 1, newItems);
        originalOrder.AddRange(newItems);
        if (CurrentIndex is null && items.Count > 0) CurrentIndex = 0;
    }

    public void PlayLater(IReadOnlyList<PlayableItem> newItems)
    {
        items.AddRange(newItems);
        originalOrder.AddRange(newItems);
        if (CurrentIndex is null && items.Count > 0) CurrentIndex = 0;
    }

    public void Remove(int itemIndex)
    {
        if (itemIndex < 0 || itemIndex >= items.Count || itemIndex == CurrentIndex) return;
        var removed = items[itemIndex];
        items.RemoveAt(itemIndex);
        originalOrder.Remove(removed);
        if (CurrentIndex is { } index && itemIndex < index) CurrentIndex = index - 1;
    }

    /// <summary>Moves the items at <paramref name="source"/> before <paramref name="destination"/> (SwiftUI's move semantics).</summary>
    public void Move(IReadOnlyCollection<int> source, int destination)
    {
        var current = Current;
        var moving = source.Order().Select(index => items[index]).ToList();
        var adjusted = destination - source.Count(index => index < destination);
        foreach (var index in source.OrderDescending()) items.RemoveAt(index);
        items.InsertRange(Math.Clamp(adjusted, 0, items.Count), moving);
        if (current is not null) CurrentIndex = items.IndexOf(current);
    }

    public void SetShuffle(bool enabled, Random? random = null)
    {
        if (enabled == IsShuffled) return;
        IsShuffled = enabled;
        var current = Current;
        if (enabled)
        {
            var rest = Upcoming.ToList();
            Shuffle(rest, random);
            items = [.. History, .. current is null ? [] : new[] { current }, .. rest];
        }
        else
        {
            items = [.. originalOrder];
            if (current is not null) CurrentIndex = items.IndexOf(current);
        }
    }

    private static void Shuffle(List<PlayableItem> list, Random? random)
    {
        random ??= Random.Shared;
        for (var index = list.Count - 1; index > 0; index--)
        {
            var other = random.Next(index + 1);
            (list[index], list[other]) = (list[other], list[index]);
        }
    }

    /// <summary>The queue by item ids, to save across launches (the Mac's JSON).</summary>
    public sealed record Snapshot(List<long> ItemIds, List<long> OriginalIds, int? CurrentIndex, bool IsShuffled, RepeatMode RepeatMode);

    public Snapshot TakeSnapshot() =>
        new(items.Select(item => item.Id).ToList(), originalOrder.Select(item => item.Id).ToList(), CurrentIndex, IsShuffled, RepeatMode);

    /// <summary>
    /// Rebuilds a saved queue from the items still available (songs removed since are dropped; when the current one is
    /// gone, the next remaining one becomes current).
    /// </summary>
    public void Restore(Snapshot snapshot, IReadOnlyDictionary<long, PlayableItem> available)
    {
        int? current = null;
        var restored = new List<PlayableItem>();
        for (var index = 0; index < snapshot.ItemIds.Count; index++)
        {
            if (!available.TryGetValue(snapshot.ItemIds[index], out var item)) continue;
            if (current is null && snapshot.CurrentIndex is { } saved && index >= saved) current = restored.Count;
            restored.Add(item);
        }
        items = restored;
        originalOrder = snapshot.OriginalIds.Where(available.ContainsKey).Select(id => available[id]).ToList();
        CurrentIndex = restored.Count == 0 ? null : Math.Min(current ?? 0, restored.Count - 1);
        IsShuffled = snapshot.IsShuffled;
        RepeatMode = snapshot.RepeatMode;
    }

    public void Clear()
    {
        items = [];
        originalOrder = [];
        CurrentIndex = null;
    }
}
