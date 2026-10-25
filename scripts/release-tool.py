#!/usr/bin/env python3
"""Local build configuration, signed archives/appcasts, and bounded QA serving.

Does not download dependencies, access Keychain, publish remotely, or install updates.
"""
import argparse
import base64
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def fail(message):
    raise ValueError(message)


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def key_bytes(value):
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        fail("Public key must be base64 Ed25519 (32 bytes)")
    if len(data) != 32 or base64.b64encode(data).decode() != value:
        fail("Public key must be canonical base64 Ed25519 (32 bytes)")
    return data


def valid_url(value, qa):
    try:
        parts = urllib.parse.urlsplit(value)
        port = parts.port
    except ValueError:
        fail("Invalid URL")
    if (not parts.hostname or parts.username is not None or parts.password is not None
            or "#" in value or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value)
            or (port is not None and not 1 <= port <= 65535)):
        fail("URL must be absolute, without credentials, whitespace, or fragment")
    if parts.scheme != "https" and not (qa and parts.scheme == "http" and parts.hostname == "127.0.0.1"):
        fail("HTTPS is required; explicit QA permits HTTP at exact 127.0.0.1 only")
    return value


def version(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value) or not any(int(x) for x in value.split(".")):
        fail("Bundle version must be one to three numeric components, greater than zero")
    return tuple(int(x) for x in value.split(".")) + (0,) * (3 - len(value.split(".")))


def require_pre_extraction_verification(info):
    if info.get("SUVerifyUpdateBeforeExtraction") is not True:
        fail("Configured apps require SUVerifyUpdateBeforeExtraction=YES")


def build_configuration():
    env = os.environ
    marker = env.get("CELLIO_LOCAL_UPDATE_QA", "0")
    if marker not in ("0", "1"):
        fail("CELLIO_LOCAL_UPDATE_QA must be 0 or 1")
    qa = marker == "1"
    identity = env.get("CELLIO_BUNDLE_ID", "org.openbattery.mac")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", identity):
        fail("Invalid CELLIO_BUNDLE_ID")
    qa_identity = identity.startswith("org.openbattery.qa.")
    if qa != qa_identity:
        fail("QA flag and separate org.openbattery.qa.* identity must be supplied together")
    explicit_output = env.get("CELLIO_OUTPUT_APP")
    output = Path(explicit_output or ROOT / "dist/Cellio.app").expanduser().resolve()
    if output.suffix != ".app" or output.name != "Cellio.app":
        fail("CELLIO_OUTPUT_APP must end in /Cellio.app")
    if qa and (not explicit_output or output.is_relative_to(ROOT / "dist")):
        fail("QA requires an explicit CELLIO_OUTPUT_APP outside normal dist")
    if output.exists() and (not output.is_dir() or output.is_symlink()):
        fail("Output must be a real application directory")
    bundle_version = env.get("CELLIO_BUNDLE_VERSION", "1")
    version(bundle_version)
    display_version = env.get("CELLIO_DISPLAY_VERSION", "1.0")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", display_version):
        fail("CELLIO_DISPLAY_VERSION must have one to three numeric components")
    feed, key = env.get("CELLIO_UPDATE_FEED_URL"), env.get("CELLIO_UPDATE_PUBLIC_KEY")
    if (feed is None) != (key is None):
        fail("Supply both CELLIO_UPDATE_FEED_URL and CELLIO_UPDATE_PUBLIC_KEY")
    if feed is not None:
        valid_url(feed, qa)
        key_bytes(key)
    if qa and feed is None:
        fail("QA build requires explicit feed and public key")
    info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    for name in ("SUFeedURL", "SUPublicEDKey", "CellioLocalUpdateQA", "NSAppTransportSecurity"):
        info.pop(name, None)
    info.update(CFBundleIdentifier=identity, CFBundleVersion=bundle_version,
                CFBundleShortVersionString=display_version,
                SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                SUAllowsAutomaticUpdates=True, SUVerifyUpdateBeforeExtraction=True)
    if feed is not None:
        info.update(SUFeedURL=feed, SUPublicEDKey=key)
        require_pre_extraction_verification(info)
    if qa:
        info["CellioLocalUpdateQA"] = True
        if urllib.parse.urlsplit(feed).scheme == "http":
            info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True,
                "NSExceptionDomains": {"127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True}}}
    return output, info


def app_info(app):
    app = Path(app).resolve(strict=True)
    if app.suffix != ".app":
        fail("Input must be a packaged .app")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if "SUFeedURL" in info or "SUPublicEDKey" in info:
        require_pre_extraction_verification(info)
    architectures = set(run("/usr/bin/xcrun", "lipo", "-archs",
                            app / "Contents/MacOS" / info["CFBundleExecutable"],
                            capture_output=True, text=True).stdout.split())
    if not {"arm64", "x86_64"}.issubset(architectures):
        fail("Packaged app must contain arm64 and x86_64 slices")
    return app, info


def prepare(args):
    app, info = app_info(args.app)
    old, previous = app_info(args.previous_app)
    require_pre_extraction_verification(info)
    require_pre_extraction_verification(previous)
    if old == app:
        fail("Previous and newer app paths must differ")
    identity = info["CFBundleIdentifier"]
    if previous["CFBundleIdentifier"] != identity:
        fail("Old/new bundle identities must match")
    if version(info["CFBundleVersion"]) <= version(previous["CFBundleVersion"]):
        fail("New CFBundleVersion must increase")
    if args.qa != identity.startswith("org.openbattery.qa.") or args.qa != (info.get("CellioLocalUpdateQA") is True):
        fail("QA release flag must match the QA app identity/marker")
    if previous.get("CellioLocalUpdateQA", False) != info.get("CellioLocalUpdateQA", False):
        fail("Old/new QA markers must match")
    feed_url, download_url = valid_url(args.feed_url, args.qa), valid_url(args.download_url, args.qa)
    if info.get("SUFeedURL") != feed_url or previous.get("SUFeedURL") != feed_url:
        fail("Feed URL must match both packaged apps")
    expected_key = key_bytes(info.get("SUPublicEDKey"))
    if previous.get("SUPublicEDKey") != info.get("SUPublicEDKey"):
        fail("Old/new update public keys must match")
    key_path = Path(args.private_key_file).expanduser().resolve(strict=True)
    if key_path.is_relative_to(ROOT) or key_path.is_relative_to(app) or key_path.is_relative_to(old):
        fail("Signing seed must be outside the workspace and applications")
    if stat.S_IMODE(key_path.stat().st_mode) != 0o600 or not key_path.is_file():
        fail("Signing seed must be a regular mode-0600 file")
    signer = Path(args.sign_tool).expanduser().resolve(strict=True)
    if not signer.is_file() or not os.access(signer, os.X_OK):
        fail("Supply an executable official sign_update tool")
    output = Path(args.output_dir).expanduser().resolve()
    if output.exists() or output.is_relative_to(app) or output.is_relative_to(old) or key_path.is_relative_to(output):
        fail("Release output must be a new directory separate from input apps and key")
    if args.qa and output.is_relative_to(ROOT / "dist"):
        fail("QA release output must be outside normal dist")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".cellio-release-", dir=output.parent) as temporary:
        stage = Path(temporary)
        archive = stage / "Cellio.zip"
        if Path(urllib.parse.unquote(urllib.parse.urlsplit(download_url).path)).name != archive.name:
            fail("Download URL must end in Cellio.zip")
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        # Official signing tool operates on the explicit seed file, never Keychain.
        signed = run(signer, "--ed-key-file", key_path, archive, capture_output=True, text=True).stdout
        signature = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', signed)
        length = re.search(r'length="([0-9]+)"', signed)
        if not signature or not length or int(length[1]) != archive.stat().st_size:
            fail("Unexpected sign_update output; expected Ed25519 signature and exact archive length")
        # Verify that the caller's private seed signed for the app's public key.
        run("/usr/bin/xcrun", "swift", ROOT / "scripts/release-crypto.swift", "verify",
            base64.b64encode(expected_key).decode(), signature[1], archive)
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "Cellio updates"
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = "Cellio " + info["CFBundleShortVersionString"]
        ET.SubElement(item, f"{{{SPARKLE}}}version").text = info["CFBundleVersion"]
        ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = info["CFBundleShortVersionString"]
        ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
        ET.SubElement(item, "enclosure", {"url": download_url, "length": length[1], "type": "application/octet-stream",
            f"{{{SPARKLE}}}edSignature": signature[1]})
        ET.ElementTree(rss).write(stage / "appcast.xml", encoding="utf-8", xml_declaration=True)
        manifest = {"bundleIdentifier": identity, "fromVersion": previous["CFBundleVersion"],
            "toVersion": info["CFBundleVersion"], "feedURL": feed_url, "downloadURL": download_url,
            "archiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest(), "localQA": args.qa}
        (stage / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
        stage.rename(output)
    print(output)


def serve(args):
    directory = Path(args.directory).resolve(strict=True)
    if not 1 <= args.seconds <= 3600 or not 1 <= args.port <= 65535:
        fail("Serve for 1–3600 seconds on port 1–65535")
    if not (directory / "appcast.xml").is_file() or not (directory / "Cellio.zip").is_file():
        fail("Serve a prepared release directory")
    # Only the three release artifacts are exposed; no directory listing/symlinks.
    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if urllib.parse.urlsplit(self.path).path not in ("/appcast.xml", "/Cellio.zip", "/release.json"):
                self.send_error(404)
                return
            super().do_GET()
        def do_HEAD(self):
            if urllib.parse.urlsplit(self.path).path not in ("/appcast.xml", "/Cellio.zip", "/release.json"):
                self.send_error(404)
                return
            super().do_HEAD()
    for name in ("appcast.xml", "Cellio.zip", "release.json"):
        if (directory / name).is_symlink():
            fail("Release server refuses symlink artifacts")
    handler = functools.partial(Handler, directory=str(directory))
    with http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler) as server:
        server.daemon_threads = True
        server.timeout = 0.5
        deadline = time.monotonic() + args.seconds
        print(f"Serving {directory} at http://127.0.0.1:{args.port} for {args.seconds}s", flush=True)
        while time.monotonic() < deadline:
            server.handle_request()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("output", help="Validate build env and print app output path")
    config = commands.add_parser("configure", help="Write validated staged Info.plist")
    config.add_argument("plist")
    publish = commands.add_parser("publish", help="Promote a verified staged app with rollback")
    publish.add_argument("--staged", required=True)
    publish.add_argument("--output", required=True)
    keys = commands.add_parser("qa-key", help="Create an explicit ephemeral file-based QA Ed25519 seed")
    keys.add_argument("--private-key-file", required=True)
    keys.add_argument("--public-key-file", required=True)
    prep = commands.add_parser("prepare", help="Archive and sign an increasing release; write appcast")
    for argument in ("app", "previous-app", "output-dir", "feed-url", "download-url", "sign-tool", "private-key-file"):
        prep.add_argument("--" + argument, required=True)
    prep.add_argument("--qa", action="store_true")
    server = commands.add_parser("serve", help="Bounded exact-loopback release server")
    server.add_argument("--directory", required=True)
    server.add_argument("--port", type=int, required=True)
    server.add_argument("--seconds", type=int, default=600)
    args = parser.parse_args()
    if args.command == "output":
        print(build_configuration()[0])
    elif args.command == "configure":
        Path(args.plist).write_bytes(plistlib.dumps(build_configuration()[1]))
    elif args.command == "publish":
        output, _ = build_configuration()
        if output != Path(args.output).resolve():
            fail("Output differs from validated build configuration")
        staged, _ = app_info(args.staged)
        with tempfile.TemporaryDirectory(prefix=".cellio-previous-", dir=output.parent) as temporary:
            backup = Path(temporary) / "Cellio.app"
            if output.exists():
                output.rename(backup)
            try:
                staged.rename(output)
            except OSError:
                if backup.exists():
                    backup.rename(output)
                raise
        print(output)
    elif args.command == "qa-key":
        run("/usr/bin/xcrun", "swift", ROOT / "scripts/release-crypto.swift", "qa-key",
            Path(args.private_key_file).expanduser().absolute(), Path(args.public_key_file).expanduser().absolute(), ROOT)
    elif args.command == "prepare":
        prepare(args)
    elif args.command == "serve":
        serve(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Release preparation failed: " + str(error), file=sys.stderr)
        sys.exit(1)
