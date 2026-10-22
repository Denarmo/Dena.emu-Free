#!/usr/bin/env python3
"""License gate for CI. Spec: docs/specs/ci.md

1. Every Dart package in app/pubspec.lock and every directory in
   host/third_party/ must have a row in docs/licenses.md.
2. Every Dart package's LICENSE file (from the pub cache, after `flutter pub get`)
   must match an allowed license and the license recorded in docs/licenses.md.
3. Banned projects (CLAUDE.md section 3) must not appear in code or build files.

Usage: python tools/licenses/check_licenses.py [--report | --write-dart-table]
  --write-dart-table rewrites the Dart package table in docs/licenses.md from the
  detected licenses; review the diff (and any "?") before committing.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[2]
LICENSES_MD = ROOT / "docs" / "licenses.md"

ALLOWED = {"MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "MPL-2.0",
           "GPL-2.0-or-later", "GPL-3.0-or-later", "LGPL-2.1-or-later", "Zlib", "ISC"}

# (regex, SPDX id); first match wins. Order matters: BSD-3 text contains BSD-2 text.
SIGNATURES = [
    (r"Apache License,?\s+Version 2\.0", "Apache-2.0"),
    (r"Mozilla Public License,?\s+(v\.|version)\s*2\.0", "MPL-2.0"),
    (r"GNU GENERAL PUBLIC LICENSE\s+Version 3", "GPL-3.0-or-later"),
    (r"GNU GENERAL PUBLIC LICENSE\s+Version 2", "GPL-2.0-or-later"),
    (r"GNU LESSER GENERAL PUBLIC LICENSE", "LGPL-2.1-or-later"),
    (r"Neither the name|names of its\s+contributors", "BSD-3-Clause"),
    (r"Redistribution and use in source and binary forms", "BSD-2-Clause"),
    (r"Permission is hereby granted, free of charge", "MIT"),
    (r"Permission to use, copy, modify, and/or distribute", "ISC"),
    (r"This software is provided 'as-is'", "Zlib"),
]

BANNED = re.compile(r"snes9x|genesis[\s_-]*plus[\s_-]*gx|picodrive|duckstation|deltacore",
                    re.IGNORECASE)
# Files allowed to *name* banned projects (to ban them).
BANNED_SCAN_EXCLUDE = {"CLAUDE.md", "docs", "tools/licenses"}
SCAN_SUFFIXES = {".c", ".h", ".cc", ".cpp", ".hpp", ".dart", ".kt", ".kts", ".swift",
                 ".py", ".sh", ".cmake", ".txt", ".yaml", ".yml", ".json", ".gradle",
                 ".toml", ".gitmodules"}


def classify(text: str) -> str | None:
    for pattern, spdx in SIGNATURES:
        if re.search(pattern, text, re.IGNORECASE):
            return spdx
    return None


def documented() -> dict[str, str]:
    """Rows of the dependency table: | name | license | ... |"""
    rows: dict[str, str] = {}
    for line in LICENSES_MD.read_text(encoding="utf-8").splitlines():
        cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and line.lstrip().startswith("|") and cells[0] not in ("Name", "") \
                and not set(cells[0]) <= set("-: "):
            rows[cells[0]] = cells[1]
    return rows


def pub_packages() -> dict[str, Path | None]:
    lock = (ROOT / "app" / "pubspec.lock").read_text(encoding="utf-8")
    names = re.findall(r"^  ([a-z0-9_]+):\n", lock, re.MULTILINE)
    roots: dict[str, Path | None] = {n: None for n in names}
    cfg = ROOT / "app" / ".dart_tool" / "package_config.json"
    if cfg.exists():
        for pkg in json.loads(cfg.read_text(encoding="utf-8"))["packages"]:
            if pkg["name"] not in roots:
                continue
            uri = pkg["rootUri"]
            if uri.startswith("file:"):
                path = unquote(urlparse(uri).path)
                if re.match(r"^/[A-Za-z]:", path):  # Windows drive letter
                    path = path[1:]
                roots[pkg["name"]] = Path(path)
            else:  # path dependency, relative to .dart_tool/
                roots[pkg["name"]] = (cfg.parent / unquote(uri)).resolve()
    return roots


def license_text(root: Path) -> str | None:
    for name in ("LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING"):
        if (root / name).exists():
            return (root / name).read_text(encoding="utf-8", errors="replace")
    return None


DART_TABLE_HEAD = "| Name | License | Kind |\n| --- | --- | --- |\n"


def write_dart_table(rows: list[str]) -> None:
    text = LICENSES_MD.read_text(encoding="utf-8")
    start = text.index(DART_TABLE_HEAD) + len(DART_TABLE_HEAD)
    end = text.index("\n\n", start)
    LICENSES_MD.write_text(text[:start] + "\n".join(rows) + text[end:], encoding="utf-8")


def main(argv: list[str]) -> int:
    report = "--report" in argv or "--write-dart-table" in argv
    rows: list[str] = []
    errors: list[str] = []
    docs = documented() if LICENSES_MD.exists() else {}

    for name, root in sorted(pub_packages().items()):
        detected = None
        if root is not None:
            text = license_text(root)
            detected = classify(text) if text else None
            # Our own path packages are covered by the repository's license.
            if root.resolve().is_relative_to(ROOT):
                detected = "GPL-3.0-or-later"
            # SDK packages ship with Flutter (BSD-3-Clause) and may lack a LICENSE file.
            if detected is None and "flutter" in str(root).replace("\\", "/").split("/"):
                detected = "BSD-3-Clause"
        if report:
            ours = root is not None and root.resolve().is_relative_to(ROOT)
            kind = (f"Dart package (ours, `{root.resolve().relative_to(ROOT).as_posix()}`)"
                    if ours else "Dart package")
            rows.append(f"| `{name}` | {detected or '?'} | {kind} |")
            continue
        if name not in docs:
            errors.append(f"pub package {name} is not listed in docs/licenses.md")
            continue
        if docs[name] not in ALLOWED:
            errors.append(f"{name}: documented license {docs[name]} is not allowed")
        if root is not None and detected != docs[name]:
            errors.append(f"{name}: LICENSE file looks like {detected}, docs say {docs[name]}")

    for d in sorted((ROOT / "host" / "third_party").iterdir()):
        if d.is_dir() and d.name not in docs:
            errors.append(f"host/third_party/{d.name} is not listed in docs/licenses.md")

    for path in ROOT.rglob("*"):
        rel = path.relative_to(ROOT).as_posix()
        if not path.is_file() or path.suffix not in SCAN_SUFFIXES:
            continue
        if any(rel == e or rel.startswith(e + "/") for e in BANNED_SCAN_EXCLUDE):
            continue
        if any(part in ("build", ".dart_tool", ".git", "third_party") for part in path.parts):
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="replace")
                                      .splitlines(), 1):
            if BANNED.search(line):
                errors.append(f"{rel}:{lineno}: references a banned project")

    if report:
        if "--write-dart-table" in argv:
            write_dart_table(rows)
        else:
            print("\n".join(rows))
        return 0
    for e in errors:
        print(f"ERROR: {e}")
    print("license check:", "FAILED" if errors else "OK")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
