using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

// Windows notification protocol activation needs an application handler.
// Only session addresses are accepted; no script paths or commands come from the URI.
internal static class AgentRecall
{
    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int processId);

    [STAThread]
    private static int Main(string[] args)
    {
        string directory = AppDomain.CurrentDomain.BaseDirectory;
        try
        {
            const string id = "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}";
            if (args.Length != 1 || !Regex.IsMatch(args[0],
                "\\Aclauderecall://(?:(?:codex|claude)/)?" + id + "/?\\z", RegexOptions.IgnoreCase))
            {
                Log(directory, "Rejected invalid session address");
                return 2;
            }
            Log(directory, "Activation received: " + args[0]);
            string script = Path.Combine(directory, "handle-click.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Session handler missing", script);
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            var start = new ProcessStartInfo(powershell,
                "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script +
                "\" -Uri \"" + args[0] + "\"");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            using (var child = Process.Start(start))
            {
                // Pass the user's activation permission to the focus handler.
                bool allowed = AllowSetForegroundWindow(child.Id);
                Log(directory, "Handler started pid=" + child.Id + " foregroundPermission=" + allowed);
            }
            return 0;
        }
        catch (Exception error)
        {
            Log(directory, "Launch failed: " + error.Message);
            return 1;
        }
    }

    private static void Log(string directory, string message)
    {
        try { File.AppendAllText(Path.Combine(directory, "protocol-launcher.log"),
            DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine); }
        catch { }
    }
}
