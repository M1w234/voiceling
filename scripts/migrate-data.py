#!/usr/bin/env python3
"""Merge the former app's data without replacing newer Voiceling edits.

Default is a plan. --apply requires both apps to be stopped. Old data remains
untouched; changed destination files are backed up before atomic replacement.
Only aggregate counts are printed, never transcript or vocabulary contents.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone


def atomic_write(path, data, backup):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        saved = backup / path.name
        saved.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, saved)
    fd, name = tempfile.mkstemp(prefix=".migration-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def merge_rows(old, new, kind):
    """Destination edits win. History identity is its UUID, vocabulary its term."""
    def identity(row):
        return row["id"] if kind == "history" else row["term"].casefold()
    seen = {identity(row) for row in new}
    result = list(new)
    for row in old:
        key = identity(row)
        if key not in seen:
            result.append(row)
            seen.add(key)
    if kind == "history":
        result.sort(key=lambda row: (row.get("isPinned", False), row["timestamp"]), reverse=True)
    return result


def migrate(home, apply=False):
    library = home / "Library/Containers"
    old = library / "com.teamwong.yaprflow/Data/Library"
    new = library / "com.teamwong.voiceling/Data/Library"
    if not old.is_dir():
        return {"oldData": False, "changes": []}
    if not new.is_dir():
        raise ValueError("Open Voiceling once before migrating.")
    if apply:
        for app in ("yaprflow", "Voiceling"):
            result = subprocess.run(["pgrep", "-x", app], stdout=subprocess.DEVNULL)
            if result.returncode == 0:
                raise ValueError("Quit both dictation apps before migrating.")
            if result.returncode != 1:
                raise RuntimeError("Could not confirm stopped apps; migration was not applied.")
    backup = new / "Application Support/Migration Backups" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    changes = []
    old_prefs = old / "Preferences/com.teamwong.yaprflow.plist"
    new_prefs = new / "Preferences/com.teamwong.voiceling.plist"
    if old_prefs.exists():
        source = plistlib.loads(old_prefs.read_bytes())
        destination = plistlib.loads(new_prefs.read_bytes()) if new_prefs.exists() else {}
        merged = dict(destination)
        for key, value in source.items():
            if not key.startswith("yaprflow."):
                continue
            key = "voiceling." + key[len("yaprflow."):]
            if key == "voiceling.didCompleteOnboarding":
                continue  # macOS grants belong to the new app identity.
            if key in ("voiceling.startSoundName", "voiceling.stopSoundName") and isinstance(value, str) and value.startswith("Yapr "):
                value = "Voiceling " + value[5:]
            merged.setdefault(key, value)
        if merged != destination:
            changes.append({"kind": "settings", "added": len(merged) - len(destination)})
            if apply:
                atomic_write(new_prefs, plistlib.dumps(merged), backup / "settings")
                if home == Path.home():
                    subprocess.run(["defaults", "import", str(new_prefs.with_suffix("")), str(new_prefs)], check=True)
    for name, kind in (("history.json", "history"), ("vocabulary.json", "vocabulary")):
        source_path = old / "Application Support/yaprflow" / name
        destination_path = new / "Application Support/Voiceling" / name
        if not source_path.exists():
            continue
        source = json.loads(source_path.read_text())
        destination = json.loads(destination_path.read_text()) if destination_path.exists() else ([] if kind == "history" else {"entries": []})
        rows = merge_rows(source if kind == "history" else source["entries"], destination if kind == "history" else destination["entries"], kind)
        merged = rows if kind == "history" else {**destination, "entries": rows}
        if kind == "history" and len(rows) > 500:
            preferences = plistlib.loads(new_prefs.read_bytes()) if new_prefs.exists() else {}
            capacity = max(500, preferences.get("voiceling.historyCapacity", 500))
            if capacity < len(rows):
                preferences["voiceling.historyCapacity"] = len(rows)
                changes.append({"kind": "historyCapacity", "capacity": len(rows)})
                if apply:
                    atomic_write(new_prefs, plistlib.dumps(preferences), backup / "capacity")
                    if home == Path.home():
                        subprocess.run(["defaults", "import", str(new_prefs.with_suffix("")), str(new_prefs)], check=True)
        if merged != destination:
            changes.append({"kind": kind, "added": len(rows) - len(destination if kind == "history" else destination["entries"])})
            if apply:
                atomic_write(destination_path, json.dumps(merged, ensure_ascii=False).encode(), backup / kind)
    for source_dir, destination_dir in (
        (old / "Application Support/yaprflow", new / "Application Support/Voiceling"),
        (old / "Caches/com.teamwong.yaprflow/models", new / "Caches/com.teamwong.voiceling/models"),
        (old / "Application Support/FluidAudio", new / "Application Support/FluidAudio"),
    ):
        if not source_dir.is_dir():
            continue
        for source in source_dir.rglob("*"):
            if not source.is_file() or source.is_symlink() or source.name in {"history.json", "vocabulary.json"}:
                continue
            target = destination_dir / source.relative_to(source_dir)
            if not target.exists():
                changes.append({"kind": "file", "bytes": source.stat().st_size})
                if apply:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, target)
    return {"oldData": True, "applied": apply, "changes": changes, "backup": str(backup) if apply and changes else None}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    print(json.dumps(migrate(Path.home(), args.apply), indent=2))
