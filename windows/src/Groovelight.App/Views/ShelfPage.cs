using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.System;

namespace Groovelight.Views;

/// <summary>
/// The Shelf: Cover Flow, as on the first iPhone's iPod app and iTunes 7 (the Mac's ShelfView). Tilted covers on a
/// glossy black floor; the wheel, dragging, the arrow keys and the scrubber move through the albums, and clicking the
/// center cover flips it over to its songs.
/// </summary>
public sealed partial class ShelfPage : PageView
{
    private const int VisibleRadius = 9;
    private readonly Canvas stage = new();
    private readonly Grid root = new();
    private readonly TextBlock title = new() { FontSize = 17, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock artist = new() { FontSize = 14, Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(166, 255, 255, 255)), TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StackPanel caption = new() { Spacing = 4 };
    private readonly Slider scrubber = new() { Minimum = 0, StepFrequency = 0.01, IsThumbToolTipEnabled = false };
    private readonly Border scrubberHost;
    private readonly Dictionary<int, ShelfCover> covers = [];
    private List<AlbumSummary> albums = [];
    /// <summary>Fractional index of the cover in the center, and where it is heading (a spring).</summary>
    private double position, velocity, target;
    private double spread, spreadTarget;
    private string? flippedKey;
    private double scrollAccumulator;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? snapTimer;
    private bool updatingScrubber;
    private bool animating;

    public ShelfPage()
    {
        root.Background = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(0, 1),
            GradientStops =
            {
                new GradientStop { Color = Microsoft.UI.Colors.Black, Offset = 0 },
                new GradientStop { Color = Windows.UI.Color.FromArgb(255, 15, 15, 15), Offset = 0.5 },
                new GradientStop { Color = Microsoft.UI.Colors.Black, Offset = 1 },
            },
        };
        RequestedTheme = ElementTheme.Dark;
        caption.Children.Add(title);
        caption.Children.Add(artist);
        stage.Children.Add(caption);
        root.Children.Add(stage);
        scrubberHost = new Border
        {
            Child = scrubber, Padding = new Thickness(14, 4, 14, 4), CornerRadius = new CornerRadius(20), VerticalAlignment = VerticalAlignment.Bottom,
            HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 18), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(40, 255, 255, 255)),
        };
        root.Children.Add(scrubberHost);
        Content = root;
        IsTabStop = true;
        root.SizeChanged += (_, args) =>
        {
            root.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, args.NewSize.Width, args.NewSize.Height) };
            Layout();
        };
        scrubber.ValueChanged += (_, args) =>
        {
            if (updatingScrubber) return;
            // Scrubs continuously while dragging, then springs to the nearest album.
            FlipBack();
            position = target = args.NewValue;
            velocity = 0;
            Layout();
            ScheduleSnap();
        };
        root.PointerWheelChanged += OnWheel;
        root.ManipulationMode = ManipulationModes.TranslateX | ManipulationModes.TranslateInertia | ManipulationModes.Scale;
        double dragStart = 0;
        double? pinchStart = null;
        root.ManipulationStarted += (_, _) => { dragStart = position; pinchStart = CoverSize.Shelf.Current; FlipBack(); };
        root.ManipulationDelta += (_, args) =>
        {
            if (Math.Abs(args.Cumulative.Scale - 1) > 0.02 && pinchStart is { } start)
            {
                Model.Preferences.Set(CoverSize.Shelf.Key, CoverSize.Shelf.Clamped(start * args.Cumulative.Scale));
                return;
            }
            var spacing = Size * 0.28;
            position = target = Math.Clamp(dragStart - args.Cumulative.Translation.X / spacing, -0.4, albums.Count - 0.6);
            velocity = 0;
            Layout();
        };
        root.ManipulationCompleted += (_, _) => { pinchStart = null; Snap(); };
        KeyDown += OnKey;
        Loaded += (_, _) => Focus(FocusState.Programmatic);
        Model.Preferences.Changed += OnPreferenceChanged;
        Observations.Add(Model.Database, db => db.Albums(AlbumSort.Artist), value =>
        {
            albums = value;
            position = target = Math.Min(position, Math.Max(value.Count - 1, 0));
            foreach (var cover in covers.Values) stage.Children.Remove(cover);
            covers.Clear();
            scrubber.Maximum = Math.Max(albums.Count - 1, 1);
            Layout();
        });
    }

    public override string Title => "Shelf";

    private void OnPreferenceChanged(string key)
    {
        if (key == CoverSize.Shelf.Key) DispatcherQueue.TryEnqueue(Layout);
    }

    public override IEnumerable<UIElement> Toolbar()
    {
        var slider = new Slider { Width = 110, Minimum = CoverSize.Shelf.Min, Maximum = CoverSize.Shelf.Max, Value = CoverSize.Shelf.Current, VerticalAlignment = VerticalAlignment.Center };
        slider.ValueChanged += (_, args) => Model.Preferences.Set(CoverSize.Shelf.Key, args.NewValue);
        ToolTipService.SetToolTip(slider, "Cover size");
        yield return Ui.Row(6, Ui.Icon("", 10, "SecondaryIcon"), slider, Ui.Icon("", 14, "SecondaryIcon")).With(row => row.VerticalAlignment = VerticalAlignment.Center);
    }

    /// <summary>The size drawn: the chosen one, made smaller when the window is too short for it.</summary>
    private double Size
    {
        get
        {
            var height = root.ActualHeight;
            if (height <= 0) return CoverSize.Shelf.Current;
            // The center cover sits at 45% of the height; its title ends 0.62 cover below that plus 50, the scrubber needs 70.
            var fitting = (height * 0.55 - 120) / 0.62;
            return Math.Min(CoverSize.Shelf.Current, Math.Max(fitting, CoverSize.Shelf.Min));
        }
    }

    private int CenterIndex => Math.Clamp((int)Math.Round(position), 0, Math.Max(albums.Count - 1, 0));

    // MARK: Layout

    private void Layout()
    {
        var width = root.ActualWidth;
        var height = root.ActualHeight;
        if (width <= 0 || height <= 0) return;
        scrubberHost.Width = Math.Min(width * 0.5, 520) + 28;
        updatingScrubber = true;
        scrubber.Value = Math.Clamp(position, 0, scrubber.Maximum);
        updatingScrubber = false;
        if (albums.Count == 0)
        {
            title.Text = "No albums yet";
            artist.Text = "";
            PlaceCaption(width, height, Size);
            return;
        }
        var size = Size;
        var centerY = height * 0.45;
        var center = CenterIndex;
        var visible = Enumerable.Range(Math.Max(0, center - VisibleRadius), Math.Min(albums.Count - 1, center + VisibleRadius) - Math.Max(0, center - VisibleRadius) + 1).ToHashSet();
        foreach (var index in covers.Keys.Where(index => !visible.Contains(index)).ToList())
        {
            stage.Children.Remove(covers[index]);
            covers.Remove(index);
        }
        foreach (var index in visible)
        {
            if (!covers.TryGetValue(index, out var cover))
            {
                cover = new ShelfCover(this, albums[index], index);
                covers[index] = cover;
                stage.Children.Add(cover);
            }
            cover.SetSize(size);
            // Flat in the middle, tilted 60 degrees on the sides; neighbors slide out while the center is flipped.
            var offset = index - position;
            var distance = Math.Abs(offset);
            var side = offset < 0 ? -1 : 1;
            var centerGap = size * (0.62 + 0.3 * spread);
            var sideSpacing = size * 0.28;
            var x = distance < 1 ? offset * centerGap : side * (centerGap + (distance - 1) * sideSpacing);
            var angle = distance < 1 ? -offset * 60 : -side * 60;
            var scale = 1 - Math.Min(distance, 1) * 0.12;
            cover.Place(width / 2 + x - size / 2, centerY - size / 2, angle, scale, Math.Min(distance, 4) * 0.06, (int)(1000 - distance * 10));
        }
        var album = albums[center];
        title.Text = album.Title;
        artist.Text = album.Artist;
        PlaceCaption(width, height, size);
    }

    private void PlaceCaption(double width, double height, double size)
    {
        caption.Width = width * 0.6;
        Canvas.SetLeft(caption, width * 0.2);
        Canvas.SetTop(caption, height * 0.45 + size * 0.62 + 6);
        Canvas.SetZIndex(caption, 2000);
    }

    // MARK: Motion

    /// <summary>Springs <see cref="position"/> to <see cref="target"/> (and the spread), frame by frame.</summary>
    private void Animate()
    {
        if (animating) return;
        animating = true;
        CompositionTarget.Rendering += OnRendering;
    }

    private DateTime lastFrame = DateTime.UtcNow;

    private void OnRendering(object? sender, object args)
    {
        var now = DateTime.UtcNow;
        var dt = Math.Clamp((now - lastFrame).TotalSeconds, 0.001, 0.05);
        lastFrame = now;
        // A slightly underdamped spring, like the Mac's .spring(duration: 0.45, bounce: 0.1).
        const double stiffness = 190, damping = 24;
        var force = stiffness * (target - position) - damping * velocity;
        velocity += force * dt;
        position += velocity * dt;
        spread += (spreadTarget - spread) * Math.Min(1, dt * 12);
        if (Math.Abs(target - position) < 0.0005 && Math.Abs(velocity) < 0.001 && Math.Abs(spreadTarget - spread) < 0.001)
        {
            position = target;
            spread = spreadTarget;
            velocity = 0;
            animating = false;
            CompositionTarget.Rendering -= OnRendering;
        }
        Layout();
    }

    private void MoveTo(double index)
    {
        target = Math.Clamp(index, 0, Math.Max(albums.Count - 1, 0));
        lastFrame = DateTime.UtcNow;
        Animate();
    }

    private void Snap() => MoveTo(Math.Round(position));

    private void ScheduleSnap()
    {
        snapTimer ??= DispatcherQueue.CreateTimer();
        snapTimer.Interval = TimeSpan.FromMilliseconds(180);
        snapTimer.IsRepeating = false;
        snapTimer.Tick -= OnSnapTimer;
        snapTimer.Tick += OnSnapTimer;
        snapTimer.Start();
    }

    private void OnSnapTimer(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args) => Snap();

    private void OnWheel(object sender, PointerRoutedEventArgs args)
    {
        if (flippedKey is not null || albums.Count == 0) return;
        var point = args.GetCurrentPoint(root);
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var delta = point.Properties.MouseWheelDelta;
        if (ctrl)
        {
            Model.Preferences.Set(CoverSize.Shelf.Key, CoverSize.Shelf.Clamped(CoverSize.Shelf.Current + delta / 120.0 * 20));
            args.Handled = true;
            return;
        }
        // A notched wheel moves one album per notch; a touchpad scrolls smoothly.
        var horizontal = point.Properties.IsHorizontalMouseWheel;
        var steps = (horizontal ? delta : -delta) / 120.0;
        scrollAccumulator += steps;
        var whole = Math.Truncate(scrollAccumulator);
        if (Math.Abs(delta) % 120 == 0 && whole != 0)
        {
            scrollAccumulator -= whole;
            MoveTo(Math.Round(target) + whole);
        }
        else if (Math.Abs(delta) % 120 != 0)
        {
            position = target = Math.Clamp(position + steps * 0.5, -0.4, albums.Count - 0.6);
            scrollAccumulator = 0;
            Layout();
            ScheduleSnap();
        }
        args.Handled = true;
    }

    private void OnKey(object sender, KeyRoutedEventArgs args)
    {
        switch (args.Key)
        {
            case VirtualKey.Left:
                FlipBack();
                MoveTo(Math.Round(target) - 1);
                break;
            case VirtualKey.Right:
                FlipBack();
                MoveTo(Math.Round(target) + 1);
                break;
            case VirtualKey.Enter:
                if (albums.Count > 0) Model.PlayAlbum(albums[CenterIndex]);
                break;
            case VirtualKey.Escape when flippedKey is not null:
                FlipBack();
                break;
            default:
                return;
        }
        args.Handled = true;
    }

    internal void CoverTapped(int index)
    {
        var album = albums[index];
        Focus(FocusState.Programmatic);
        // Still between two covers: settle first, flip on the next click.
        if (Math.Abs(position - Math.Round(position)) > 0.01)
        {
            FlipBack();
            MoveTo(index);
            return;
        }
        if (index == CenterIndex)
        {
            if (flippedKey == album.AlbumKey) FlipBack();
            else
            {
                flippedKey = album.AlbumKey;
                spreadTarget = 1;
                covers[index].Flip(true);
                Animate();
            }
        }
        else
        {
            FlipBack();
            MoveTo(index);
        }
    }

    internal void FlipBack()
    {
        if (flippedKey is null) return;
        foreach (var cover in covers.Values) cover.Flip(false);
        flippedKey = null;
        spreadTarget = 0;
        Animate();
    }

    internal bool IsFlipped(string albumKey) => flippedKey == albumKey;

    public override void Dispose()
    {
        CompositionTarget.Rendering -= OnRendering;
        Model.Preferences.Changed -= OnPreferenceChanged;
        base.Dispose();
    }
}

/// <summary>One cover on the Shelf with its reflection on the floor; it flips over to show the album's songs.</summary>
public sealed partial class ShelfCover : Grid
{
    private readonly ShelfPage shelf;
    private readonly AlbumSummary album;
    private readonly int index;
    private readonly Grid face = new();
    private readonly ArtworkImage front;
    private readonly ArtworkImage reflection;
    private readonly Border reflectionFade = new();
    private readonly Border shade = new() { Background = new SolidColorBrush(Microsoft.UI.Colors.Black), IsHitTestVisible = false };
    private readonly PlaneProjection projection = new();
    private readonly PlaneProjection faceProjection = new();
    private readonly ScaleTransform scaleTransform = new();
    private Border? back;
    private double size;

    public ShelfCover(ShelfPage shelf, AlbumSummary album, int index)
    {
        this.shelf = shelf;
        this.album = album;
        this.index = index;
        front = new ArtworkImage { Hash = album.ArtworkHash, IsLarge = true, Radius = 2 };
        reflection = new ArtworkImage { Hash = album.ArtworkHash, Radius = 2, IsHitTestVisible = false, Opacity = 0.35, RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5), RenderTransform = new ScaleTransform { ScaleY = -1 } };
        // The floor is black: a gradient from clear to black over the mirrored cover fades it like the Mac's mask.
        reflectionFade.Background = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(0, 1),
            GradientStops =
            {
                new GradientStop { Color = Windows.UI.Color.FromArgb(0, 0, 0, 0), Offset = 0 },
                new GradientStop { Color = Windows.UI.Color.FromArgb(255, 8, 8, 8), Offset = 1 },
            },
        };
        reflectionFade.IsHitTestVisible = false;
        face.Children.Add(front);
        face.Projection = faceProjection;
        var reflectionHost = new Grid { IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Top };
        reflectionHost.Children.Add(reflection);
        reflectionHost.Children.Add(reflectionFade);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Children.Add(face);
        Children.Add(reflectionHost.At(0, 1));
        Children.Add(shade.At(0, 0, rowSpan: 2));
        Projection = projection;
        RenderTransform = scaleTransform;
        Background = Images.Transparent;
        Tapped += (_, args) =>
        {
            if (back is not null && args.OriginalSource is DependencyObject source && IsInside(source, back)) return;
            shelf.CoverTapped(index);
        };
    }

    private static bool IsInside(DependencyObject element, DependencyObject container)
    {
        for (var current = element; current is not null; current = VisualTreeHelper.GetParent(current)) if (current == container) return true;
        return false;
    }

    public void SetSize(double value)
    {
        if (Math.Abs(value - size) < 0.5) return;
        size = value;
        face.Width = face.Height = size;
        reflection.Width = reflection.Height = size;
        ((Grid)reflection.Parent).Margin = new Thickness(0, 2, 0, 0);
        RowDefinitions[1].Height = new GridLength(size * 0.45);
        ((Grid)reflection.Parent).Height = size * 0.45;
        ((Grid)reflection.Parent).Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, size, size * 0.45) };
        // The mirrored image shows its top part (the bottom of the cover) right under the cover.
        reflection.VerticalAlignment = VerticalAlignment.Top;
        Width = size;
        scaleTransform.CenterX = size / 2;
        scaleTransform.CenterY = size / 2;
        if (back is not null) back.Width = back.Height = size;
    }

    public void Place(double left, double top, double angle, double scale, double darken, int z)
    {
        Canvas.SetLeft(this, left);
        Canvas.SetTop(this, top);
        Canvas.SetZIndex(this, z);
        projection.RotationY = angle;
        projection.CenterOfRotationX = 0.5;
        scaleTransform.ScaleX = scaleTransform.ScaleY = scale;
        shade.Opacity = darken;
    }

    /// <summary>
    /// The flip in two halves: the cover turns away to 90 degrees, then the song list turns in from -90 to 0, so at
    /// rest the list has no 3D transform (and its clicks and scrolling work).
    /// </summary>
    public void Flip(bool toBack)
    {
        if (toBack == back is not null) return;
        if (toBack)
        {
            back = Backside();
            back.Width = back.Height = size;
            back.VerticalAlignment = VerticalAlignment.Top;
            var backProjection = new PlaneProjection { RotationY = -90 };
            back.Projection = backProjection;
            back.Opacity = 0;
            Children.Add(back);
            var turnAway = Animation(faceProjection, 0, 90, 160, new QuadraticEase { EasingMode = EasingMode.EaseIn });
            turnAway.Completed += (_, _) =>
            {
                face.Opacity = 0;
                back.Opacity = 1;
                ((Grid)reflection.Parent).Opacity = 0;
                var turnIn = Animation(backProjection, -90, 0, 350, new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.3 });
                turnIn.Completed += (_, _) => { if (back is not null) back.Projection = null; };
                turnIn.Begin();
            };
            turnAway.Begin();
        }
        else if (back is { } shown)
        {
            var backProjection = new PlaneProjection();
            shown.Projection = backProjection;
            back = null;
            var turnAway = Animation(backProjection, 0, -90, 160, new QuadraticEase { EasingMode = EasingMode.EaseIn });
            turnAway.Completed += (_, _) =>
            {
                Children.Remove(shown);
                face.Opacity = 1;
                ((Grid)reflection.Parent).Opacity = 1;
                Animation(faceProjection, 90, 0, 350, new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.3 }).Begin();
            };
            turnAway.Begin();
        }
    }

    private static Storyboard Animation(PlaneProjection target, double from, double to, int milliseconds, EasingFunctionBase easing)
    {
        var animation = new DoubleAnimation { From = from, To = to, Duration = TimeSpan.FromMilliseconds(milliseconds), EasingFunction = easing, EnableDependentAnimation = true };
        Storyboard.SetTarget(animation, target);
        Storyboard.SetTargetProperty(animation, nameof(PlaneProjection.RotationY));
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        return storyboard;
    }

    /// <summary>The back of the flipped cover: the album's songs, with Play and the way back to the cover.</summary>
    private Border Backside()
    {
        var model = AppModel.Current;
        var list = new TrackList { ListStyle = TrackListStyle.Album, IsCompact = true, AlbumKey = album.AlbumKey };
        _ = LoadAsync(list);
        var header = Ui.Grid("*,auto,auto");
        header.ColumnSpacing = 8;
        header.Padding = new Thickness(10);
        header.Children.Add(Ui.Column(0, Ui.Text(album.Title, "StrongText", 13), Ui.Text(album.Artist, "CaptionText", 11)));
        header.Children.Add(Ui.IconButton(Glyphs.Play, "Play Album", () => model.PlayAlbum(album), 12, "CircleButton").At(1));
        header.Children.Add(Ui.IconButton("", "Show Cover (Esc)", shelf.FlipBack, 12, "CircleButton").At(2));
        var grid = Ui.Grid("", "auto,auto,*");
        grid.Children.Add(header);
        grid.Children.Add(Ui.Separator().At(0, 1));
        grid.Children.Add(new ScrollViewer { Content = list.Margin(0, 4, 0, 4) }.At(0, 2));
        // Opaque: the neighboring covers must not show through the list.
        return new Border { Child = grid, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 28, 28, 28)), RequestedTheme = ElementTheme.Dark };
    }

    private async Task LoadAsync(TrackList list)
    {
        var key = album.AlbumKey;
        list.Tracks = await Task.Run(() => AppModel.Current.Database.Read(db => db.TracksOfAlbum(key)));
    }
}
