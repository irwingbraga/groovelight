using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Groovelight.Views;

/// <summary>A page of the library window: it keeps its database observations and drops them when it goes away.</summary>
public abstract partial class PageView : UserControl, IDisposable
{
    protected AppModel Model => AppModel.Current;
    protected Observations Observations { get; } = new();

    /// <summary>The page's name (the window's title and the back stack).</summary>
    public virtual string Title => "";

    /// <summary>Controls the page adds to the title bar's right side (sort, cover size, New Playlist).</summary>
    public virtual IEnumerable<UIElement> Toolbar() => [];

    public virtual void Dispose()
    {
        Observations.Dispose();
        GC.SuppressFinalize(this);
    }

    /// <summary>A ScrollViewer with the page's padding around <paramref name="content"/>.</summary>
    protected static ScrollViewer Scroll(UIElement content, double padding = 28) => new()
    {
        Content = new Border { Padding = new Thickness(padding, padding, padding, padding + 8), Child = content },
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
    };
}
