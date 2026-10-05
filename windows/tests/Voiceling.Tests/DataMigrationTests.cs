using Voiceling.Core;
using Xunit;

namespace Voiceling.Tests;

public sealed class DataMigrationTests
{
    [Fact]
    public void UpgradePreservesOldFilesAndModelsAndDoesNotReplaceNewEdits()
    {
        string root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            string old = Path.Combine(root, "YaprFlow");
            Directory.CreateDirectory(Path.Combine(old, "models", "speech"));
            File.WriteAllText(Path.Combine(old, "history.json"), "original history");
            File.WriteAllBytes(Path.Combine(old, "models", "speech", "model.bin"), [0, 1, 2, 255]);
            string current = DataMigration.EnsureDirectory(root);
            Assert.Equal("original history", File.ReadAllText(Path.Combine(current, "history.json")));
            Assert.Equal(File.ReadAllBytes(Path.Combine(old, "models", "speech", "model.bin")), File.ReadAllBytes(Path.Combine(current, "models", "speech", "model.bin")));
            File.WriteAllText(Path.Combine(current, "history.json"), "new dictation");
            Assert.Equal(current, DataMigration.EnsureDirectory(root));
            Assert.Equal("new dictation", File.ReadAllText(Path.Combine(current, "history.json")));
            Assert.Equal("original history", File.ReadAllText(Path.Combine(old, "history.json")));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
