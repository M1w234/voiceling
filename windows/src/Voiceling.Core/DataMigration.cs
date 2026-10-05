namespace Voiceling.Core;

/// One-time copy of the former Windows data tree. Publish only a complete copy;
/// preserve the original and every existing Voiceling edit for rollback.
public static class DataMigration
{
    public static string EnsureDirectory(string localDataRoot)
    {
        string current = Path.Combine(localDataRoot, "Voiceling");
        string previous = Path.Combine(localDataRoot, "YaprFlow");
        if (Directory.Exists(current)) return current;
        if (!Directory.Exists(previous)) { Directory.CreateDirectory(current); return current; }
        string staging = current + ".migrating-" + Guid.NewGuid().ToString("N");
        try
        {
            CopyDirectory(previous, staging);
            // Do not replace a destination created concurrently.
            Directory.Move(staging, current);
            return current;
        }
        finally { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
    }

    private static void CopyDirectory(string source, string target)
    {
        if ((File.GetAttributes(source) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Migration cannot follow directory links.");
        Directory.CreateDirectory(target);
        foreach (string file in Directory.EnumerateFiles(source))
        {
            if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Migration cannot follow file links.");
            File.Copy(file, Path.Combine(target, Path.GetFileName(file)));
        }
        foreach (string directory in Directory.EnumerateDirectories(source))
            CopyDirectory(directory, Path.Combine(target, Path.GetFileName(directory)));
    }
}
