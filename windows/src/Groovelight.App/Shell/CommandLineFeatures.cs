using Groovelight.Model;
using Groovelight.Support;
using Groovelight.Views;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Shell;

/// <summary>Settings, General: the <c>groovelight</c> command in terminals, and connecting Groovelight to Claude.</summary>
internal static class CommandLineFeatures
{
    public static void Register() => SettingsPage.GeneralExtras.Add(_ => Build());

    private static FrameworkElement Build()
    {
        var model = AppModel.Current;
        var panel = Ui.Column(4, SettingsPage.Header("Command Line"));
        if (!CommandLineTool.Exists)
        {
            panel.Children.Add(new SettingsCard("The command line tool is missing", $"groovelight.com is not in {CommandLineTool.Folder}. Install Groovelight again to get it.", null, Glyphs.Warning));
            return panel;
        }
        var state = new StackPanel { Spacing = 4 };
        void Update()
        {
            state.Children.Clear();
            if (CommandLineTool.IsOnPath())
            {
                state.Children.Add(new SettingsCard("groovelight in terminals", "Ready in new Terminal, PowerShell and Command Prompt windows: groovelight status, search, import, fix-metadata, organize, undo, play and more (groovelight --help). Add --json for scripts. The tool asks this app to do the work, and starts it when needed.",
                    Ui.Button("Remove from PATH", () => { CommandLineTool.RemoveFromPath(); Update(); }), ""));
            }
            else
            {
                state.Children.Add(new SettingsCard("groovelight in terminals", "Adds Groovelight's folder to your PATH, so groovelight status, search, import, play and more work in new terminal windows. Only for your Windows account.",
                    Ui.Button("Add to PATH", () => { CommandLineTool.AddToPath(); Update(); }), ""));
            }
        }
        Update();
        panel.Children.Add(state);
        if (!model.Control.IsListening)
            panel.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Message = "Another copy of Groovelight is answering the command line." });

        panel.Children.Add(SettingsPage.Header("Use with Claude"));
        panel.Children.Add(new SettingsCard("Claude Desktop", "Download Groovelight.mcpb from the latest release and open it to install the extension.",
            Ui.Button("Get the Extension", () => AppModel.OpenUrl(AppLinks.Repository + "/releases/latest")), Glyphs.Download));
        var claudeCode = $"claude mcp add groovelight -- \"{CommandLineTool.ToolPath}\" mcp";
        panel.Children.Add(new SettingsCard("Claude Code: run this once", null, Copyable(claudeCode), "", stacked: true));
        panel.Children.Add(SettingsPage.Footer("Claude can then search your library, play music, and import, fix and organize files. Changes to files always come as a preview first, and Claude applies them only after you agree."));
        return panel;
    }

    /// <summary>A command to copy into a terminal.</summary>
    private static FrameworkElement Copyable(string command)
    {
        var text = new TextBlock
        {
            Text = command, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Button? copy = null;
        copy = Ui.Button("Copy", () =>
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(command);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
            copy!.Content = "Copied";
        });
        var grid = Ui.Grid("*,auto");
        grid.ColumnSpacing = 12;
        grid.Children.Add(text);
        grid.Children.Add(copy.At(1));
        return grid;
    }
}
