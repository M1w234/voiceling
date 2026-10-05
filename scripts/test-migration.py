import importlib.util
from pathlib import Path
import unittest
import tempfile
import json
import plistlib
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("migration", Path(__file__).with_name("migrate-data.py"))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MergeTests(unittest.TestCase):
    def test_existing_history_edits_and_new_dictations_survive(self):
        old = [{"id": "same", "timestamp": 1, "text": "old", "isPinned": False}, {"id": "older", "timestamp": 0, "text": "retained"}]
        new = [{"id": "same", "timestamp": 1, "text": "edited", "isPinned": True}, {"id": "newer", "timestamp": 2, "text": "new"}]
        result = migration.merge_rows(old, new, "history")
        self.assertEqual(len(result), 3)
        self.assertEqual(result[0], new[0])
        self.assertEqual(migration.merge_rows(old, result, "history"), result)

    def test_process_lookup_failure_refuses_data_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            for bundle in ["com.teamwong.yaprflow", "com.teamwong.voiceling"]:
                (home / "Library/Containers" / bundle / "Data/Library").mkdir(parents=True)
            with patch.object(migration.subprocess, "run") as run:
                run.return_value.returncode = 3
                with self.assertRaisesRegex(RuntimeError, "not applied"):
                    migration.migrate(home, True)
            self.assertFalse(any(home.rglob("Migration Backups")))

    def test_combined_history_capacity_survives_app_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            old = home / "Library/Containers/com.teamwong.yaprflow/Data/Library/Application Support/yaprflow"
            new = home / "Library/Containers/com.teamwong.voiceling/Data/Library/Application Support/Voiceling"
            old.mkdir(parents=True); new.mkdir(parents=True)
            rows = lambda prefix: [{"id": f"{prefix}{i}", "timestamp": i, "text": "fixture"} for i in range(500)]
            (old / "history.json").write_text(json.dumps(rows("old")))
            (new / "history.json").write_text(json.dumps(rows("new")))
            with patch.object(migration.subprocess, "run") as run:
                run.return_value.returncode = 1
                migration.migrate(home, True)
            self.assertEqual(len(json.loads((new / "history.json").read_text())), 1000)
            prefs = new.parents[1] / "Preferences/com.teamwong.voiceling.plist"
            self.assertEqual(plistlib.loads(prefs.read_bytes())["voiceling.historyCapacity"], 1000)

    def test_disabled_and_edited_vocabulary_wins_over_legacy(self):
        old = [{"term": "Claude", "isEnabled": True, "misheard": ["cloud"]}, {"term": "Michael", "misheard": ["mikel"]}]
        new = [{"term": "claude", "isEnabled": False, "misheard": []}]
        result = migration.merge_rows(old, new, "vocabulary")
        self.assertEqual(result, [new[0], old[1]])


if __name__ == "__main__":
    unittest.main()
