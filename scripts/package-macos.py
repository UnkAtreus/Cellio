#!/usr/bin/env python3
"""Package an already signed universal app as an app-only ZIP and install DMG.

Uses macOS tools only. Does not sign, install, publish, or change the source app.
"""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def verify(app):
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "org.openbattery.mac" or info.get("CFBundleExecutable") != "cellio":
        raise ValueError("Expected the main Cellio app")
    architectures = set(run("/usr/bin/xcrun", "lipo", "-archs", app / "Contents/MacOS/cellio",
                            capture_output=True, text=True).stdout.split())
    if not {"arm64", "x86_64"}.issubset(architectures):
        raise ValueError("Expected a universal arm64 and x86_64 app")
    resources = app / "Contents/Resources"
    for bundled, canonical in (("LICENSE", ROOT / "LICENSE"),
                               ("THIRD_PARTY_NOTICES.md", ROOT / "THIRD_PARTY_NOTICES.md"),
                               ("Sparkle-LICENSE", ROOT / "Vendor/Sparkle-LICENSE")):
        if (resources / bundled).read_bytes() != canonical.read_bytes():
            raise ValueError(f"Missing or mismatched bundled notice: {bundled}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/Cellio.app")
    parser.add_argument("--version", required=True, help="Release label, e.g. 1.0.0-alpha.3")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}(?:-[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)*)?", args.version):
        parser.error("Invalid release label")
    app = args.app.expanduser().resolve(strict=True)
    if app.name != "Cellio.app" or not app.is_dir():
        parser.error("--app must be a Cellio.app directory")
    output = args.output_dir.expanduser().resolve()
    if output == app or app in output.parents:
        parser.error("Output directory must be outside the app")
    verify(app)
    output.mkdir(parents=True, exist_ok=True)
    stem = f"Cellio-{args.version}-macos-universal"
    destinations = [output / f"{stem}.{suffix}" for suffix in ("zip", "dmg")]
    if any(path.exists() or path.is_symlink() for path in destinations):
        parser.error("Output already exists; use a fresh output directory")
    with tempfile.TemporaryDirectory(prefix=".cellio-package-", dir=output) as temporary:
        staging = Path(temporary)
        volume = staging / "volume"
        volume.mkdir()
        copied_app = volume / "Cellio.app"
        run("/usr/bin/ditto", "--norsrc", "--noextattr", "--noqtn", app, copied_app)
        verify(copied_app)
        zip_path, dmg_path = (staging / path.name for path in destinations)
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn",
            copied_app, zip_path)
        (volume / "Applications").symlink_to("/Applications", target_is_directory=True)
        run("/usr/bin/hdiutil", "create", "-quiet", "-srcfolder", volume, "-volname", "Cellio",
            "-fs", "HFS+", "-format", "UDZO", "-nospotlight", dmg_path)
        run("/usr/bin/hdiutil", "verify", "-quiet", dmg_path)
        # Exclusive hard links refuse to replace an existing release archive.
        for source, destination in zip((zip_path, dmg_path), destinations):
            destination.hardlink_to(source)
            print(destination)


if __name__ == "__main__":
    main()
