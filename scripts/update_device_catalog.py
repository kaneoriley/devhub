#!/usr/bin/env python3
"""Refresh bundled Android hardware profiles from a pinned AOSP tools/base revision."""
import argparse
import base64
import json
import os
from pathlib import Path
import tempfile
from urllib.parse import quote
from urllib.request import urlopen
from xml.etree import ElementTree

ROOT = "https://android.googlesource.com/platform/tools/base"
PROFILE_PATH = "sdklib/src/main/resources/com/android/sdklib/devices"
PROJECT = Path(__file__).resolve().parents[1]
RESOURCES = PROJECT / "Sources/DevHub/Android/Resources"


def download(url):
    with urlopen(url, timeout=45) as response:
        return response.read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="mirror-goog-studio-main", help="AOSP commit or branch (default: mirror-goog-studio-main)")
    args = parser.parse_args()
    commit = json.loads(download(f"{ROOT}/+/{quote(args.revision, safe='')}?format=JSON")[4:])["commit"]
    files = {}
    for name in ("nexus.xml", "devices.xml"):
        xml = base64.b64decode(download(f"{ROOT}/+/{commit}/{PROFILE_PATH}/{name}?format=TEXT"), validate=False)
        root = ElementTree.fromstring(xml)
        count = sum(child.tag.rsplit("}", 1)[-1] == "device" for child in root)
        if not root.tag.endswith("devices") or count == 0:
            raise ValueError(f"{name} is not a device catalog")
        files[name] = xml
        print(f"{name}: {count} profiles")
    license_text = download("https://www.apache.org/licenses/LICENSE-2.0.txt")
    files["android-tools-LICENSE.txt"] = license_text
    files["device-catalog-NOTICE.txt"] = (
        "Android hardware profiles from the Android Open Source Project.\n"
        f"Repository: {ROOT}\nRevision: {commit}\n"
        f"Source: {ROOT}/+/{commit}/{PROFILE_PATH}/\n"
        "Files: nexus.xml, devices.xml (unmodified upstream definitions).\n"
        "Copyright The Android Open Source Project. Apache License 2.0.\n"
        "License: android-tools-LICENSE.txt\n"
        "Update: python3 scripts/update_device_catalog.py\n"
        "Reproduce: python3 scripts/update_device_catalog.py --revision " + commit + "\n"
    ).encode()
    # Download and validate everything before replacing the bundled snapshot.
    with tempfile.TemporaryDirectory(prefix="catalog-update-", dir=RESOURCES) as temporary:
        for name, data in files.items():
            (Path(temporary) / name).write_bytes(data)
        for name in files:
            os.replace(Path(temporary) / name, RESOURCES / name)
    (PROJECT / "ThirdParty/android-tools-LICENSE").write_bytes(license_text)
    print(f"Pinned AOSP tools/base revision {commit}")


if __name__ == "__main__":
    main()
