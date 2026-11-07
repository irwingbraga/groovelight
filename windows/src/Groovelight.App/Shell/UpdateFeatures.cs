using System.ComponentModel;
using Groovelight.Model;
using Groovelight.Support;
using Groovelight.Views;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Groovelight.Shell;

/// <summary>Updates in the window: Help, Check for Updates; Settings, General; and the question once a new version is downloaded.</summary>
internal static class UpdateFeatures
{
    public static void Register()
    {
        var model = AppModel.Current;
        var updates = model.Updates;
        AppMenus.HelpItems.Add(() =>
        [
            updates.ReadyVersion is { } version
                ? Menus.Item($"Restart to Update to {version}", updates.RestartToUpdate, Glyphs.Download)
                : Menus.Item("Check for Updates…", () => _ = CheckAndTellAsync(), Glyphs.Download),
            new MenuFlyoutSeparator(),
        ]);
        var asked = false;
        updates.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName != nameof(Updates.ReadyVersion) || updates.ReadyVersion is not { } version || asked) return;
            asked = true;
            model.Queue.TryEnqueue(async () =>
            {
                if (MainWindow.Current.RootXamlRoot is not { } root) return;
                var dialog = new ContentDialog
                {
                    Title = $"Groovelight {version} is ready", Content = "Restart Groovelight now to install it, or later: it installs the next time Groovelight restarts from here.",
                    PrimaryButtonText = "Restart Now", CloseButtonText = "Later", DefaultButton = ContentDialogButton.Primary, XamlRoot = root,
                };
                if (await ContentDialogs.ShowAsync(dialog) == ContentDialogResult.Primary) updates.RestartToUpdate();
            });
        };
        SettingsPage.GeneralExtras.Add(page =>
        {
            var status = Ui.Text(updates.Status, "SecondaryText");
            PropertyChangedEventHandler handler = (_, _) => model.Queue.TryEnqueue(() => status.Text = updates.Status);
            updates.PropertyChanged += handler;
            status.Unloaded += (_, _) => updates.PropertyChanged -= handler;
            var check = Ui.Button("Check Now", () => _ = updates.CheckAsync());
            check.IsEnabled = updates.IsInstalled;
            var panel = Ui.Column(4, SettingsPage.Header("Updates"),
                new SettingsCard($"Groovelight {updates.CurrentVersion}", updates.IsInstalled
                        ? "New versions come from Groovelight's releases on GitHub, checked against the release before they install."
                        : "This build was not installed with the installer, so it does not update itself.", Ui.Row(12, status, check), Glyphs.Download),
                new SettingsCard("Download updates automatically", "Checks once a day and downloads in the background; a new version installs when Groovelight restarts.",
                    SettingsPage.Toggle(model.Preferences.Bool(Updates.AutomaticKey, true), on => model.Preferences.Set(Updates.AutomaticKey, on))));
            return panel;
        });
    }

    private static async Task CheckAndTellAsync()
    {
        var updates = AppModel.Current.Updates;
        await updates.CheckAsync();
        if (updates.ReadyVersion is null && MainWindow.Current.RootXamlRoot is { } root) await Ui.Alert(root, "Check for Updates", updates.Status);
    }
}
