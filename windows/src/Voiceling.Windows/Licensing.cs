using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows.Automation;
using System.Windows.Input;

namespace Voiceling.Windows;

internal sealed class LicenseManager
{
    private readonly string path;
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Voiceling-License-V1");
    public LicenseRecord Record { get; private set; }
    public LicenseStatus Status { get; private set; }
    public event Action? Changed;
    public LicenseManager(string directory, bool isolated)
    {
        path = Path.Combine(isolated ? directory : Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VoicelingLicensing"), "record.bin");
        if (File.Exists(path))
        {
            if (new FileInfo(path).Length > 16384) throw new InvalidDataException("License record is too large.");
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
            Record = JsonSerializer.Deserialize<LicenseRecord>(plain) ?? throw new InvalidDataException("License record is invalid.");
        }
        else { Record = new(DateTimeOffset.UtcNow); Save(Record); }
        Status = LicensePolicy.Status(Record, DateTimeOffset.UtcNow);
    }
    public void Refresh()
    {
        // Permanent entitlements do not need signature verification on every UI tick.
        if (Status.Kind is LicenseKind.Licensed or LicenseKind.IncludedWithDeskling) return;
        var next = LicensePolicy.Status(Record, DateTimeOffset.UtcNow);
        if (Status == next) return;
        Status = next; Changed?.Invoke();
    }
    public bool CanDictate { get { Refresh(); return Status.CanDictate; } }
    public string? Activate(string text)
    {
        if (LicensePolicy.Verify(text) is null) return "That key is not valid. Copy it again from your purchase page.";
        try { Update(Record with { Key = LicensePolicy.Compact(text) }); return null; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException)
        { return "The license could not be saved. Your previous license is unchanged."; }
    }
    public void NoteDesklingConnected()
    {
        if (Record.DesklingSeen is not null) return;
        Update(Record with { DesklingSeen = DateTimeOffset.UtcNow });
    }
    private void Update(LicenseRecord next)
    {
        Save(next); Record = next;
        var updated = LicensePolicy.Status(Record, DateTimeOffset.UtcNow);
        if (updated != Status) { Status = updated; Changed?.Invoke(); }
    }
    private void Save(LicenseRecord record)
    {
        var data = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(record), Entropy, DataProtectionScope.CurrentUser);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { file.Write(data); file.Flush(true); }
            File.Move(temp, path, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public static void Buy() => Process.Start(new ProcessStartInfo(LicensePolicy.CheckoutUrl) { UseShellExecute = true });
}

internal sealed class LicenseWindow : Window
{
    private readonly TextBox key = new() { MinHeight = 36, MaxLength = 4096, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock status = MainWindow.Text("");
    private readonly TextBlock feedback = MainWindow.Text("", 8);
    public LicenseWindow(LicenseManager manager)
    {
        Title = "Voiceling license"; Width = 470; MinWidth = 380; Height = 390; MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new FontFamily("Segoe UI"); FontSize = 14;
        Background = SystemParameters.HighContrast ? SystemColors.WindowBrush : new SolidColorBrush(Color.FromRgb(243, 246, 243));
        Foreground = SystemParameters.HighContrast ? SystemColors.WindowTextBrush : new SolidColorBrush(Color.FromRgb(32, 51, 45));
        if (!SystemParameters.HighContrast) Resources.MergedDictionaries.Add(new ResourceDictionary
        { Source = new Uri("pack://application:,,,/voiceling;component/Theme.xaml") });
        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(new TextBlock { Text = "Voiceling", FontSize = 26, FontWeight = FontWeights.SemiBold });
        status.Margin = new Thickness(0, 8, 0, 16); panel.Children.Add(status);
        panel.Children.Add(MainWindow.Text("$5.99 once · Mac and Windows · Included with Deskling", 0, 16));
        panel.Children.Add(MainWindow.Label("_License key", key));
        AutomationProperties.SetName(key, "Voiceling license key");
        panel.Children.Add(key); panel.Children.Add(feedback);
        AutomationProperties.SetLiveSetting(feedback, AutomationLiveSetting.Polite);
        var buy = MainWindow.Button("_Buy Voiceling", () =>
        { try { LicenseManager.Buy(); } catch { feedback.Text = "Open deskling-site.vercel.app/voiceling in your browser."; } });
        var activate = MainWindow.Button("_Activate", () =>
        {
            var error = manager.Activate(key.Text);
            feedback.Text = error ?? "Voiceling is activated. Thank you!";
            key.BorderBrush = error is null ? SystemColors.ControlDarkBrush : Brushes.Firebrick;
            if (error is null) key.Clear(); else key.Focus();
            Refresh();
        }); activate.IsDefault = true;
        var close = MainWindow.Button("_Close", Close);
        panel.Children.Add(MainWindow.Row(activate, buy, close));
        panel.Children.Add(MainWindow.Text("Activation is checked on this PC. No account or internet connection is needed to dictate.", 14));
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        void Refresh() { manager.Refresh(); status.Text = manager.Status.Label;
            buy.Visibility = manager.Status.Kind is LicenseKind.Trial or LicenseKind.Expired ? Visibility.Visible : Visibility.Collapsed; }
        Refresh(); manager.Changed += Refresh; Closed += (_, _) => manager.Changed -= Refresh;
        Loaded += (_, _) => key.Focus();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { Close(); e.Handled = true; } };
    }
}
