using System.ComponentModel;
using Windows.Media;
using Windows.Media.Playback;
using Windows.Storage;
using Windows.Storage.Streams;

namespace Groovelight.Audio.Windows;

/// <summary>
/// The Windows media controls (media keys, the volume flyout, the lock screen): the song with its cover and position,
/// and Play, Pause, Next, Previous and seeking sent back to the player (Control Center and media keys on the Mac).
/// Uses a MediaPlayer's controls with its own playback off, which works without a window.
/// </summary>
public sealed class MediaControls : IDisposable
{
    private readonly MediaPlayer host = new();
    private readonly SystemMediaTransportControls controls;
    private readonly PlaybackController player;
    private readonly Action<Action> post;
    private readonly Func<PlayableItem, string?> artworkPath;
    private PlayableItem? shown;

    /// <param name="post">Runs work on the player's thread (button presses arrive on another one).</param>
    /// <param name="artworkPath">The cover image file for a song, if any.</param>
    public MediaControls(PlaybackController player, Action<Action> post, Func<PlayableItem, string?> artworkPath)
    {
        this.player = player;
        this.post = post;
        this.artworkPath = artworkPath;
        host.CommandManager.IsEnabled = false;
        controls = host.SystemMediaTransportControls;
        controls.IsEnabled = true;
        controls.IsPlayEnabled = controls.IsPauseEnabled = controls.IsNextEnabled = controls.IsPreviousEnabled = controls.IsStopEnabled = true;
        controls.ButtonPressed += OnButtonPressed;
        controls.PlaybackPositionChangeRequested += (_, request) => post(() => player.Seek(request.RequestedPlaybackPosition.TotalSeconds));
        player.PropertyChanged += OnPlayerChanged;
        Update();
    }

    private void OnButtonPressed(SystemMediaTransportControls sender, SystemMediaTransportControlsButtonPressedEventArgs args) => post(() =>
    {
        switch (args.Button)
        {
            case SystemMediaTransportControlsButton.Play: player.TogglePlayPause(); break;
            case SystemMediaTransportControlsButton.Pause: player.Pause(); break;
            case SystemMediaTransportControlsButton.Stop: player.Pause(); break;
            case SystemMediaTransportControlsButton.Next: player.Next(); break;
            case SystemMediaTransportControlsButton.Previous: player.Previous(); break;
        }
    });

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(PlaybackController.State) or nameof(PlaybackController.Current) or nameof(PlaybackController.Duration)) Update();
        // The position is sent now and then, not every tick (the flyout moves it on by itself).
        else if (args.PropertyName == nameof(PlaybackController.CurrentTime) && (int)player.CurrentTime % 5 == 0) UpdateTimeline();
    }

    private void Update()
    {
        controls.PlaybackStatus = player.State switch
        {
            PlaybackState.Playing => MediaPlaybackStatus.Playing,
            PlaybackState.Paused => MediaPlaybackStatus.Paused,
            _ => player.Current is null ? MediaPlaybackStatus.Closed : MediaPlaybackStatus.Stopped,
        };
        if (player.Current is { } item && item != shown)
        {
            shown = item;
            var updater = controls.DisplayUpdater;
            updater.Type = MediaPlaybackType.Music;
            updater.MusicProperties.Title = item.Title;
            updater.MusicProperties.Artist = item.Artist;
            updater.MusicProperties.AlbumTitle = item.Album;
            updater.Thumbnail = null;
            updater.Update();
            _ = SetThumbnailAsync(item);
        }
        UpdateTimeline();
    }

    private async Task SetThumbnailAsync(PlayableItem item)
    {
        if (artworkPath(item) is not { } path || !File.Exists(path)) return;
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(path);
            if (shown != item) return;
            controls.DisplayUpdater.Thumbnail = RandomAccessStreamReference.CreateFromFile(file);
            controls.DisplayUpdater.Update();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException) { }
    }

    private void UpdateTimeline()
    {
        controls.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties
        {
            StartTime = TimeSpan.Zero,
            MinSeekTime = TimeSpan.Zero,
            Position = TimeSpan.FromSeconds(player.CurrentTime),
            MaxSeekTime = TimeSpan.FromSeconds(player.Duration),
            EndTime = TimeSpan.FromSeconds(player.Duration),
        });
    }

    public void Dispose()
    {
        player.PropertyChanged -= OnPlayerChanged;
        controls.ButtonPressed -= OnButtonPressed;
        controls.DisplayUpdater.ClearAll();
        host.Dispose();
    }
}
