using System.ComponentModel;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Groovelight.Views;

/// <summary>Settings, Last.fm: the API account, connecting the user's Last.fm account, what is sent and what is waiting.</summary>
public static class LastFmSettings
{
    public const string Glyph = "";

    public static void Register() => SettingsPage.Extra.Add((70, new SettingsSection("Last.fm", Glyph, Build)));

    public static FrameworkElement Build(SettingsPage page)
    {
        var model = AppModel.Current;
        var lastfm = model.LastFm;
        var panel = new StackPanel { Spacing = 4 };

        panel.Children.Add(SettingsPage.Header("Account"));
        var account = new StackPanel { Spacing = 4 };
        panel.Children.Add(account);
        void UpdateAccount()
        {
            account.Children.Clear();
            if (lastfm.IsConnected)
            {
                var name = Ui.Link(lastfm.Username ?? "", lastfm.ProfileUrl is { } url ? () => AppModel.OpenUrl(url) : null, "BodyText", "Open your Last.fm profile");
                account.Children.Add(new SettingsCard("Connected as", null, Ui.Row(12, name, Ui.Button("Disconnect", lastfm.Disconnect)), Glyph));
                return;
            }
            var key = new TextBox { Text = lastfm.ApiKey, PlaceholderText = "Paste the API key", Width = 300 };
            key.TextChanged += (_, _) => lastfm.ApiKey = key.Text;
            account.Children.Add(new SettingsCard("API key", null, key));
            var secret = new PasswordBox { Password = lastfm.Secret, PlaceholderText = "Paste the shared secret", Width = 300 };
            secret.PasswordChanged += (_, _) => lastfm.Secret = secret.Password;
            account.Children.Add(new SettingsCard("Shared secret", null, secret));
            FrameworkElement action;
            if (lastfm.IsConnecting)
            {
                action = Ui.Row(12, new ProgressRing { IsActive = true, Width = 16, Height = 16 },
                    Ui.Text("Allow Groovelight on the Last.fm page that opened in your browser…", "SecondaryText"), Ui.Button("Cancel", lastfm.CancelConnecting));
            }
            else
            {
                var connect = new Button { Content = "Connect to Last.fm…", Style = Ui.Style("AccentButtonStyle"), IsEnabled = lastfm.HasCredentials };
                connect.Click += (_, _) => lastfm.Connect();
                PropertyChangedEventHandler credentials = (_, args) =>
                {
                    if (args.PropertyName == nameof(LastFmStore.HasCredentials)) connect.IsEnabled = lastfm.HasCredentials;
                };
                lastfm.PropertyChanged += credentials;
                connect.Unloaded += (_, _) => lastfm.PropertyChanged -= credentials;
                action = connect;
            }
            action.HorizontalAlignment = HorizontalAlignment.Right;
            account.Children.Add(action.Margin(0, 6, 0, 0));
            var help = Ui.Column(2,
                SettingsPage.Footer("Last.fm needs an API account for Groovelight: create one on Last.fm (any name and description; the callback URL can stay empty), then paste its API key and shared secret here. The secret and your session are kept encrypted for your Windows account."),
                Ui.Link("Create an API account on Last.fm", () => AppModel.OpenUrl("https://www.last.fm/api/account/create"), "SecondaryText").Margin(4, 0, 0, 0));
            account.Children.Add(help);
        }

        panel.Children.Add(SettingsPage.Header("Sharing"));
        SettingsCard Option(string title, string key) =>
            new(title, null, SettingsPage.Toggle(model.Preferences.Bool(key, true), on => model.Preferences.Set(key, on)));
        panel.Children.Add(Option("Scrobble songs", LastFmStore.ScrobbleKey));
        panel.Children.Add(Option("Show what is playing now on Last.fm", LastFmStore.NowPlayingKey));
        panel.Children.Add(Option("Love and unlove songs on Last.fm too", LastFmStore.SyncLovesKey));
        panel.Children.Add(SettingsPage.Footer("A song is scrobbled when it is longer than 30 seconds and was played for half of its length or 4 minutes, whichever comes first. Scrobbles made offline, and songs played on paired phones, are sent later."));

        panel.Children.Add(SettingsPage.Header("Status"));
        var status = new StackPanel { Spacing = 4 };
        panel.Children.Add(status);
        void UpdateStatus()
        {
            status.Children.Clear();
            var send = Ui.Button("Send Now", lastfm.SendNow);
            send.IsEnabled = lastfm.IsConnected && lastfm.PendingCount > 0 && !lastfm.IsSending;
            var waiting = Ui.Row(12, Ui.Text(lastfm.PendingCount.ToString(System.Globalization.CultureInfo.CurrentCulture), "SecondaryText"));
            if (lastfm.IsSending) waiting.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            waiting.Children.Add(send);
            status.Children.Add(new SettingsCard("Waiting to be sent", null, waiting));
            if (lastfm.LastSentAt is { } sent) status.Children.Add(new SettingsCard("Last sent", null, Ui.Text(Format.Relative(sent), "SecondaryText")));
            if (lastfm.Problem is { } problem)
                status.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Message = problem });
        }

        string[] accountProperties = [nameof(LastFmStore.IsConnected), nameof(LastFmStore.IsConnecting), nameof(LastFmStore.Username)];
        string[] statusProperties = [nameof(LastFmStore.PendingCount), nameof(LastFmStore.IsSending), nameof(LastFmStore.LastSentAt), nameof(LastFmStore.Problem), nameof(LastFmStore.IsConnected)];
        PropertyChangedEventHandler changed = (_, args) => model.Queue.TryEnqueue(() =>
        {
            if (accountProperties.Contains(args.PropertyName)) UpdateAccount();
            if (statusProperties.Contains(args.PropertyName)) UpdateStatus();
        });
        lastfm.PropertyChanged += changed;
        panel.Unloaded += (_, _) => lastfm.PropertyChanged -= changed;
        UpdateAccount();
        UpdateStatus();
        return panel;
    }
}
