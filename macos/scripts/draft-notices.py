#!/usr/bin/env python3
"""Generate an explicitly incomplete third-party-notices draft from a sidecar.

Usage: python3 macos/scripts/draft-notices.py /path/to/FreeLLMAPI > notices.draft.txt
This is evidence for review, not a license-compliance determination.
"""

import json
import pathlib
import subprocess
import sys


def local_text(root: pathlib.Path, relative: pathlib.Path) -> str:
    """Never read through a symlink outside the selected artifact."""
    try:
        path = (root / relative).resolve(strict=True)
        if not path.is_relative_to(root) or not path.is_file():
            return "MISSING OR OUTSIDE SIDECAR — REVIEW REQUIRED"
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError, ValueError):
        return "MISSING OR UNREADABLE — REVIEW REQUIRED"


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    root = pathlib.Path(sys.argv[1]).resolve(strict=True)
    inventory_script = pathlib.Path(__file__).with_name("inventory-licenses.py")
    inventory = json.loads(subprocess.run(
        [sys.executable, str(inventory_script), str(root)], check=True,
        stdout=subprocess.PIPE, text=True,
    ).stdout)
    print("THIRD-PARTY NOTICES — DRAFT; REVIEW REQUIRED")
    print("Generated from files and metadata in this sidecar; this is not a compliance determination.")
    print("Missing texts, source obligations, bundled JavaScript and native libraries require independent review.")
    print("FreeLLMAPI revision:", inventory.get("revision") or "UNAVAILABLE")
    for name in ("LICENSE-FreeLLMAPI", "LICENSE-Node"):
        print(f"\n===== {name} =====\n")
        print(local_text(root, pathlib.Path(name)))

    records = inventory.get("packages", [])
    for pkg in records:
        print(f"\n===== {pkg['name']}@{pkg['version']} =====")
        print("Declared license:", pkg.get("declared_license") or "UNAVAILABLE — REVIEW REQUIRED")
        print("Artifact path:", pkg["path"])
        if not pkg.get("license_notice_files"):
            print("MISSING LOCAL LICENSE/NOTICE — REVIEW UPSTREAM")
        for name in pkg.get("license_notice_files", []):
            print(f"\n--- {name} ---\n")
            print(local_text(root, pathlib.Path(pkg["path"]) / name))

    bundle = inventory.get("bundle_inventory", {})
    print("\n===== SERVER BUNDLE BUILD INPUT INVENTORY =====")
    print("Status:", bundle.get("status", "unavailable"))
    if bundle.get("status") == "available":
        matching = bundle.get("server_sha256_matches") is True
        print("Bundle SHA-256 matches inventory:", "yes" if matching else "NO — REVIEW REQUIRED")
        print("Input count:", bundle.get("input_count"))
        packaged = {(pkg["name"], pkg["version"]) for pkg in records}
        for pkg in bundle.get("packages", []):
            present = (pkg.get("name"), pkg.get("version")) in packaged
            print(f"- {pkg.get('name')}@{pkg.get('version')} | declared={pkg.get('declared_license')} | "
                  f"source={pkg.get('path')} | matching node_modules package={'yes' if present else 'NO — REVIEW REQUIRED'}")
            if not pkg.get("license_notice_files"):
                print("  No license/notice recorded in source package — REVIEW REQUIRED")
        print("External imports:", ", ".join(bundle.get("external_imports", [])) or "none recorded")
        for unresolved in bundle.get("unresolved_inputs", []):
            print("Unresolved input:", unresolved.get("input"), "—", unresolved.get("reason"))
    else:
        print(bundle.get("reason", "Bundle input inventory is unavailable — REVIEW REQUIRED"))
    for issue in inventory.get("read_errors", []):
        print("Inventory read error:", issue.get("path"), "—", issue.get("error"))
    print("\nEND OF DRAFT — independently verify licenses, notices, source and native dependencies.")


if __name__ == "__main__":
    main()
