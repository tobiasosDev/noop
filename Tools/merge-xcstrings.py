#!/usr/bin/env python3
"""Union-merge a conflicted .xcstrings (String Catalog) during a git merge.

Takes ours (:2:) and theirs (:3:) from the index, merges the "strings" dict:
- key only in one side -> kept
- key in both -> union the per-language localizations, ours winning per language
Writes the merged catalog over the working-tree file.
"""
import json
import subprocess

PATH = "Strand/Resources/Localizable.xcstrings"


def show(stage: int):
    out = subprocess.run(
        ["git", "show", f":{stage}:{PATH}"],
        capture_output=True, check=True
    ).stdout
    return json.loads(out)


ours = show(2)
theirs = show(3)

merged = dict(ours)
m = merged["strings"]
added = 0
langs_added = 0
for key, tval in theirs["strings"].items():
    if key not in m:
        m[key] = tval
        added += 1
        continue
    oloc = m[key].setdefault("localizations", {})
    for lang, lval in tval.get("localizations", {}).items():
        if lang not in oloc:
            oloc[lang] = lval
            langs_added += 1

with open(PATH, "w", encoding="utf-8") as f:
    json.dump(merged, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")

print(f"keys: ours={len(ours['strings'])} theirs={len(theirs['strings'])} "
      f"merged={len(m)} (+{added} new keys, +{langs_added} new translations)")
