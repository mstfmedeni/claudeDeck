#!/usr/bin/env python3
"""Merges open-screen-sharing's UI strings into ClaudeDeck's string catalog.

Inside the ScreenSharingKit framework the strings resolve against the app's bundle, so the
screen tab is only translated if its keys are in Support/Localizable.xcstrings. Run this after
every bump of the Vendor/open-screen-sharing submodule:

    tools/merge-screen-sharing-strings.py

Only the languages ClaudeDeck already has are taken (a half-translated app in 50 languages would
be worse than English), and a key that's in both keeps ClaudeDeck's entry.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OURS = os.path.join(ROOT, "Support", "Localizable.xcstrings")
THEIRS = os.path.join(ROOT, "Vendor", "open-screen-sharing", "OpenScreenSharing", "Resources", "Localizable.xcstrings")


def main() -> int:
    if not os.path.exists(THEIRS):
        print(f"❌ {THEIRS} not found (git submodule update --init)", file=sys.stderr)
        return 1
    with open(OURS, encoding="utf-8") as f:
        ours = json.load(f)
    with open(THEIRS, encoding="utf-8") as f:
        theirs = json.load(f)

    languages = {ours.get("sourceLanguage", "en")}
    for entry in ours["strings"].values():
        languages |= set((entry.get("localizations") or {}).keys())

    added = updated = 0
    for key, entry in theirs["strings"].items():
        localizations = {lang: value for lang, value in (entry.get("localizations") or {}).items() if lang in languages}
        if key in ours["strings"]:
            # Ours wins, but a language we don't have for this key yet is filled in.
            mine = ours["strings"][key].setdefault("localizations", {})
            missing = {lang: value for lang, value in localizations.items() if lang not in mine}
            if missing:
                mine.update(missing)
                updated += 1
            continue
        merged = {k: v for k, v in entry.items() if k != "localizations"}
        if localizations:
            merged["localizations"] = localizations
        ours["strings"][key] = merged
        added += 1

    with open(OURS, "w", encoding="utf-8") as f:
        json.dump(ours, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"✅ {added} strings added, {updated} filled in ({', '.join(sorted(languages))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
