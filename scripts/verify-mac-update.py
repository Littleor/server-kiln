#!/usr/bin/env python3
"""Validate the actual app inside a DMG and the generated Sparkle feed."""
import hashlib
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
METADATA = ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "SUPublicEDKey")


def metadata(app):
    with (app / "Contents/Info.plist").open("rb") as f:
        return plistlib.load(f)


def require_same_metadata(expected, actual):
    for key in METADATA:
        if not expected.get(key) or actual.get(key) != expected[key]:
            raise ValueError(f"DMG app {key} mismatch: expected {expected.get(key)!r}, got {actual.get(key)!r}")


def manifest(app):
    result = {}
    for path in app.rglob("*"):
        relative = str(path.relative_to(app))
        if path.is_symlink():
            result[relative] = ("link", str(path.readlink()))
        elif path.is_file():
            result[relative] = ("file", hashlib.sha256(path.read_bytes()).hexdigest())
    return result


def verify_dmg(app, dmg):
    expected = metadata(app)
    with tempfile.TemporaryDirectory(prefix="serverkiln-verify-") as tmp:
        mount = pathlib.Path(tmp) / "image"
        mount.mkdir()
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                        "-mountpoint", str(mount), str(dmg.resolve())],
                       check=True, stdout=subprocess.DEVNULL)
        try:
            apps = list(mount.glob("*.app"))
            if len(apps) != 1 or apps[0].is_symlink():
                raise ValueError("DMG must contain exactly one real application bundle")
            contained = apps[0]
            require_same_metadata(expected, metadata(contained))
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contained)], check=True)
            if manifest(app) != manifest(contained):
                raise ValueError("DMG application contents differ from the exported application")
        finally:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True, stdout=subprocess.DEVNULL)
    print("PASS: DMG contains the exact exported app, version and signing key")


def verify_feed(folder, asset, version, build):
    items = ET.parse(folder / "appcast.xml").findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Expected exactly one appcast item")
    item = items[0]
    for key, value in [("version", build), ("shortVersionString", version)]:
        if item.findtext(SPARKLE + key) != value:
            raise ValueError(f"Appcast {key} does not match exported app: expected {value}")
    enclosure = item.find("enclosure")
    expected_url = f"https://github.com/Littleor/server-kiln/releases/download/v{version}/{asset}"
    if enclosure is None or not enclosure.get(SPARKLE + "edSignature"):
        raise ValueError("Missing update signature")
    if enclosure.get("url") != expected_url:
        raise ValueError("Unexpected update URL")
    if int(enclosure.get("length", "-1")) != (folder / asset).stat().st_size:
        raise ValueError("Update length mismatch")
    (folder / "SHA256SUMS").write_text("".join(
        hashlib.sha256((folder / name).read_bytes()).hexdigest() + "  " + name + "\n"
        for name in [asset, "appcast.xml"]))
    print("PASS: appcast version, build, URL, signature presence and length")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "dmg":
            verify_dmg(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
        elif sys.argv[1] == "feed":
            verify_feed(pathlib.Path(sys.argv[2]), *sys.argv[3:6])
        else:
            raise ValueError("Expected dmg or feed")
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
