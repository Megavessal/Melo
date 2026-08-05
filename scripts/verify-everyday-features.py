#!/usr/bin/env python3
"""Small release guard for Melo's consumer-facing additions.

This is intentionally structural rather than a Swift compiler replacement. It
prevents packaging a source tree that accidentally omitted one of the new
feature entry points or reverted the user-facing wording to technical jargon.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
checks = {
    "Scenes model": ("Sources/Melo/Models/ConsumerExperience.swift", "struct ConsumerScene"),
    "Automations": ("Sources/Melo/Coordination/ConsumerAutomationManager.swift", "final class ConsumerAutomationManager"),
    "Undo history": ("Sources/Melo/Coordination/ConsumerUndoManager.swift", "final class ConsumerUndoManager"),
    "Everyday settings": ("Sources/Melo/Views/Settings/Tabs/EverydayTab.swift", 'SettingsSection("Scenes")'),
    "Command search": ("Sources/Melo/Views/Components/ConsumerCommandPalette.swift", 'TextField("What would you like Melo to do?"'),
    "Audio repair": ("Sources/Melo/Audio/Engine/AudioEngine.swift", "func repairConsumerAudio()"),
    "Scene import/export": ("Sources/Melo/Views/Settings/Tabs/EverydayTab.swift", ".melo-scene.json"),
    "Menu bar details": ("Sources/Melo/Settings/Types/SettingsUITypes.swift", "enum MenuBarInfoStyle"),
    "Friendly device summary": ("Sources/Melo/Views/Sheets/DeviceDetailSheet.swift", 'title: "Quality"'),
    "Safe signing cleanup": ("scripts/build-app.sh", 'xattr -cr "$APP_BUNDLE"'),
    "Release version": ("Config/Info.plist", "<string>2.9.0</string>"),
}

failures = []
for label, (relative, needle) in checks.items():
    path = root / relative
    if not path.is_file():
        failures.append(f"{label}: missing {relative}")
        continue
    if needle not in path.read_text(errors="replace"):
        failures.append(f"{label}: expected marker not found in {relative}")

if failures:
    print("Everyday feature verification failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print(f"Everyday feature verification passed ({len(checks)} checks).")
