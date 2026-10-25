#!/usr/bin/env python3
"""Embed the immutable offline Sparkle framework, or sign/verify its nested code."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "Vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"


def run(*arguments, capture=False):
    return subprocess.run([str(x) for x in arguments], check=True,
                          capture_output=capture, text=capture)


def main():
    operation, app_path = sys.argv[1:]
    app = Path(app_path).resolve(strict=True)
    framework = app / "Contents/Frameworks/Sparkle.framework"
    if operation == "embed":
        receipt = json.loads((ROOT / "Vendor/Sparkle-version.json").read_text())
        version = plistlib.loads((VENDOR / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
        if (receipt["version"] != "2.10.0" or version != "2.10.0"
                or receipt["archiveSHA256"] != "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
                or hashlib.sha256((VENDOR / "Versions/B/Sparkle").read_bytes()).hexdigest()
                != "b57162032b569fce26c8ba162a54c55740da362822f80eac72dbad41d6edc374"):
            raise ValueError("Offline Sparkle pin/receipt does not match approved 2.10.0")
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", VENDOR)
        framework.parent.mkdir(parents=True, exist_ok=True)
        run("/usr/bin/ditto", VENDOR, framework)
        run("/bin/cp", ROOT / "Vendor/Sparkle-LICENSE", app / "Contents/Resources/Sparkle-LICENSE")
    elif operation != "sign":
        raise ValueError("Use embed or sign")
    version_dir = framework / "Versions/B"
    # Explicit inside-out signing; never use --deep to sign.
    nested = [version_dir / "Autoupdate",
              version_dir / "Updater.app",
              version_dir / "XPCServices/Downloader.xpc",
              version_dir / "XPCServices/Installer.xpc", framework]
    binaries = [version_dir / "Autoupdate", version_dir / "Sparkle",
                version_dir / "Updater.app/Contents/MacOS/Updater",
                version_dir / "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
                version_dir / "XPCServices/Installer.xpc/Contents/MacOS/Installer"]
    for binary in binaries:
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError("Missing executable Sparkle helper: " + str(binary))
        run("/usr/bin/lipo", binary, "-verify_arch", "arm64", "x86_64")
    for link in (framework / "Versions/Current", framework / "Sparkle", framework / "Resources"):
        if not link.is_symlink() or not link.resolve().is_relative_to(framework):
            raise ValueError("Required official framework symlink missing: " + str(link))
    binary = app / "Contents/MacOS/cellio"
    for architecture in ("arm64", "x86_64"):
        loads = run("/usr/bin/otool", "-arch", architecture, "-l", binary, capture=True).stdout
        libraries = run("/usr/bin/otool", "-arch", architecture, "-L", binary, capture=True).stdout
        if "path @executable_path/../Frameworks (" not in loads or "@rpath/Sparkle.framework/Versions/B/Sparkle" not in libraries:
            raise ValueError("Missing bundled Sparkle linkage/rpath for " + architecture)
    if operation == "sign":
        identity = os.environ.get("CELLIO_SIGN_IDENTITY") or "-"
        arguments = ["--force", "--sign", identity, "--preserve-metadata=entitlements", "--generate-entitlement-der"]
        keychain = os.environ.get("CELLIO_SIGN_KEYCHAIN")
        if keychain:
            arguments += ["--keychain", keychain]
        if os.environ.get("CELLIO_SIGN_MODE") == "developer-id":
            arguments += ["--options", "runtime", "--timestamp"]
        else:
            arguments += ["--timestamp=none"]
        for code in nested:
            run("/usr/bin/codesign", *arguments, code)
            run("/usr/bin/codesign", "--verify", "--strict", code)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", framework)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Sparkle packaging failed: " + str(error), file=sys.stderr)
        sys.exit(1)
