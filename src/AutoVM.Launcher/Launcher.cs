// AutoVM launcher.
//
// A tiny Windows executable so that AutoVM has a real icon, a real
// double-clickable entry point and a single elevation prompt. It does nothing
// but locate a PowerShell host and start the wizard next to itself.
//
// Compiled against .NET Framework 4, which is present on every supported
// version of Windows, so the installed application needs no extra runtime.

using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Launcher
{
    private const string ScriptName = "AutoVM.ps1";

    [STAThread]
    private static int Main(string[] args)
    {
        string appDir = Path.GetDirectoryName(Application.ExecutablePath);
        string script = Path.Combine(appDir, ScriptName);

        if (!File.Exists(script))
        {
            Fail("AutoVM is missing part of its installation (" + ScriptName + " was not found).\n\n" +
                 "Reinstall AutoVM to repair it.");
            return 2;
        }

        string host = FindHost();
        if (host == null)
        {
            Fail("Windows PowerShell could not be found on this computer, so AutoVM cannot start.");
            return 3;
        }

        // Windows PowerShell runs single-threaded-apartment by default, which is
        // what the wizard's window needs; the script re-checks and recovers if a
        // different host is ever used.
        string arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
        foreach (string arg in args)
        {
            arguments += " \"" + arg.Replace("\"", "\\\"") + "\"";
        }

        try
        {
            ProcessStartInfo start = new ProcessStartInfo(host, arguments)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = appDir
            };
            Process.Start(start);
            return 0;
        }
        catch (Exception ex)
        {
            Fail("AutoVM could not start.\n\n" + ex.Message);
            return 4;
        }
    }

    private static string FindHost()
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string[] candidates =
        {
            Path.Combine(windows, @"System32\WindowsPowerShell\v1.0\powershell.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe")
        };

        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate)) { return candidate; }
        }
        return null;
    }

    private static void Fail(string message)
    {
        MessageBox.Show(message, "AutoVM", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}
