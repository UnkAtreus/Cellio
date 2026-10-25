#!/usr/bin/env python3
"""Run the unchanged independent controller/adapter assertions without local QA receipts."""
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = ROOT / '.scratch/permissions-supplement'
OUT.mkdir(parents=True, exist_ok=True)
binary = OUT / 'supplement-tests'
subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(ROOT / '.scratch/navigation-validation/module-cache'),
                '-parse-as-library', str(ROOT / 'Sources/OpenBatteryMac/NativePermissions.swift'),
                str(ROOT / 'Sources/OpenBatteryMac/NativePermissionAdapters.swift'),
                str(HERE / 'SupplementSupport.swift'), str(HERE / 'SupplementBehavior.swift'),
                '-o', str(binary)], check=True)
subprocess.run([str(binary)], check=True)
ui = (ROOT / 'Sources/OpenBatteryMac/PermissionsSettings.swift').read_text()
assert '.onDisappear { mounted = false; permissions.invalidateSettingsOpening();' in ui
print('Permissions disappearance invalidates the opening transaction.')
