#!/usr/bin/env python3
"""Resolve this Mac's persistent signing identity without exposing its password."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys


def private_file(path):
    if path.is_symlink():
        raise ValueError("Signing configuration and credentials must not be symlinks")
    metadata = path.stat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o077 or metadata.st_size > 65536):
        raise ValueError("Signing files must be small, owner-only regular files")
    return path.read_bytes()


def resolve(config_path):
    # A broken symlink is a configured failure, not permission to use ad-hoc.
    if not config_path.exists() and not config_path.is_symlink():
        if config_path.parent.exists():
            raise ValueError("The local signing directory exists but its configuration is missing")
        return None
    config = json.loads(private_file(config_path))
    if config.get("version") != 1 or config.get("mode") != "local":
        raise ValueError("Unsupported local signing configuration")
    identity = config.get("identity")
    if not isinstance(identity, str) or not re.fullmatch(r"[0-9A-Fa-f]{40}", identity):
        raise ValueError("Local signing requires a certificate SHA-1 fingerprint")
    paths = []
    for field in ("keychain", "passwordFile"):
        value = config.get(field)
        if (not isinstance(value, str) or not value or "\n" in value
                or "\r" in value or "\0" in value or not Path(value).is_absolute()):
            raise ValueError("Signing paths must be absolute single-line paths")
        paths.append(Path(value))
    keychain, password_file = paths
    if keychain.is_symlink() or not keychain.is_file():
        raise ValueError("The configured signing keychain is missing or unsafe")
    password = private_file(password_file)
    if not password or b"\0" in password or len(password) > 512:
        raise ValueError("Invalid dedicated signing-keychain password file")
    listed = subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user"],
                            check=True, capture_output=True, text=True)
    if keychain.resolve() not in [Path(p).resolve() for p in shlex.split(listed.stdout)]:
        raise ValueError("The dedicated signing keychain is not in the user's search list")

    security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
    core = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    security.SecKeychainOpen.restype = ctypes.c_int32
    security.SecKeychainUnlock.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                         ctypes.c_void_p, ctypes.c_ubyte]
    security.SecKeychainUnlock.restype = ctypes.c_int32
    core.CFRelease.argtypes = [ctypes.c_void_p]
    core.CFRelease.restype = None
    reference = ctypes.c_void_p()
    result = security.SecKeychainOpen(os.fsencode(keychain), ctypes.byref(reference))
    if result:
        raise ValueError(f"Cannot open the dedicated signing keychain (OSStatus {result})")
    try:
        buffer = ctypes.create_string_buffer(password)
        result = security.SecKeychainUnlock(reference, len(password), buffer, True)
        ctypes.memset(buffer, 0, len(buffer))
        if result:
            raise ValueError(f"Cannot unlock the dedicated signing keychain (OSStatus {result})")
    finally:
        core.CFRelease(reference)
    identities = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p",
                                 "codesigning", str(keychain)],
                                check=True, capture_output=True, text=True)
    if not re.search(r"^\s*\d+\) " + re.escape(identity) + r' "[^\n]+"\s*$',
                     identities.stdout, re.MULTILINE | re.IGNORECASE):
        raise ValueError("The configured code-signing identity is not available")
    return identity, str(keychain), "local"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path,
                        default=Path.home() / ".local/share/cellio/signing/config.json")
    arguments = parser.parse_args()
    try:
        result = resolve(arguments.config)
        if result:
            print("\n".join(result))
    except (OSError, ValueError, subprocess.SubprocessError):
        # Do not include raw config contents, credential data or command output.
        print("Local signing setup is unavailable or invalid; refusing ad-hoc fallback. "
              "Check docs/signing.md.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
