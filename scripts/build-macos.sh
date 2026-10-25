#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Explicit caller signing settings take precedence. A configured local identity
# is otherwise mandatory; an unavailable identity must never become ad-hoc.
mac_adhoc_development="${CELLIO_ADHOC_DEVELOPMENT:-0}"
if [[ "$mac_adhoc_development" != 0 && "$mac_adhoc_development" != 1 ]]; then
    print -u2 "CELLIO_ADHOC_DEVELOPMENT must be 0 or 1"
    exit 1
fi
if [[ "$mac_adhoc_development" == 1 && ( -n "${CELLIO_SIGN_IDENTITY:-}" || -n "${CELLIO_SIGN_MODE:-}" || -n "${CELLIO_SIGN_KEYCHAIN:-}" ) ]]; then
    print -u2 "Explicit ad-hoc development cannot be combined with certificate signing settings"
    exit 1
fi
if [[ -n "${CELLIO_SIGN_KEYCHAIN:-}" && -z "${CELLIO_SIGN_IDENTITY:-}" ]]; then
    print -u2 "CELLIO_SIGN_KEYCHAIN requires CELLIO_SIGN_IDENTITY"
    exit 1
fi
if [[ "$mac_adhoc_development" == 0 && -z "${CELLIO_SIGN_IDENTITY:-}" && -z "${CELLIO_SIGN_MODE:-}" && -z "${CELLIO_SIGN_KEYCHAIN:-}" ]]; then
    mac_local_signing=$(python3 scripts/local-signing.py)
    if [[ -n "$mac_local_signing" ]]; then
        mac_local_fields=("${(@f)mac_local_signing}")
        if (( ${#mac_local_fields} != 3 )); then
            print -u2 "Invalid local signing resolution"
            exit 1
        fi
        export CELLIO_SIGN_IDENTITY="${mac_local_fields[1]}"
        export CELLIO_SIGN_KEYCHAIN="${mac_local_fields[2]}"
        export CELLIO_SIGN_MODE="${mac_local_fields[3]}"
    else
        print -u2 "No persistent signing identity configured. See docs/signing.md."
        print -u2 "Use CELLIO_ADHOC_DEVELOPMENT=1 only for an intentional ad-hoc test build."
        exit 1
    fi
fi
mac_output_app=$(python3 scripts/release-tool.py output)
mac_output_parent="${mac_output_app:h}"
mkdir -p "$mac_output_parent" .scratch
# zsh heredocs use TMPPREFIX rather than TMPDIR in confined local builds.
TMPPREFIX="$PWD/.scratch/zsh"
mac_build_arguments=(--disable-sandbox -c release --arch arm64 --arch x86_64)
if [[ "${CELLIO_LOCAL_UPDATE_QA:-0}" == 1 ]]; then
    mac_build_arguments+=(--scratch-path "$PWD/.build/login-updates-qa" -Xswiftc -DCELLIO_LOCAL_UPDATE_QA)
fi
mac_stage_root=$(mktemp -d "$mac_output_parent/.openbattery-build.XXXXXX")
trap 'rm -rf "$mac_stage_root"' EXIT
mac_staged_app="$mac_stage_root/Cellio.app"
mkdir -p "$mac_staged_app/Contents/MacOS"
python3 scripts/release-tool.py configure "$mac_staged_app/Contents/Info.plist"
swift build "${mac_build_arguments[@]}"
mac_binary_directory=$(swift build "${mac_build_arguments[@]}" --show-bin-path)
cp "$mac_binary_directory/cellio" "$mac_staged_app/Contents/MacOS/cellio"
# Validate the immutable first-party inputs and the native format-conversion outputs.
python3 - <<'ICON_INPUTS'
from pathlib import Path
import hashlib
expected={
 'DesignAssets/CellioDark.png':'cb41a0b328c577db31cfabb8a11e7e5da02088961a4d4b10ab43b8df7c013b58',
 'DesignAssets/CellioLight.png':'02eb2613c10a5439353546506f2b1a987ffb038c838ccb8d4e525a8e601ae810',
 'Resources/Cellio.xcassets/Cellio_Assets/Dark.imageset/image.png':'578921b5f756ba04386ad21e48202c7bee10150c7bd3ca316b8eeb69c2380f39',
 'Resources/Cellio.xcassets/Cellio_Assets/Light.imageset/image.png':'d551fa0a197241a7b466a07dca29ad44407a11db9c586dbc83c3e30452252298',
 'Resources/Cellio.icns':'c07e095e76ad3baba71f85d87a5e0873e864d26a2c9412a8ed90ba1d0b38b5a4'}
for name,digest in expected.items():
 if hashlib.sha256(Path(name).read_bytes()).hexdigest()!=digest: raise SystemExit('Icon input mismatch: '+name)
ICON_INPUTS
mkdir -p "$mac_stage_root/icons" "$mac_staged_app/Contents/Resources"
xcrun actool Resources/Cellio.xcassets --compile "$mac_stage_root/icons" --platform macosx --minimum-deployment-target 13.0 --app-icon Cellio --output-partial-info-plist "$mac_stage_root/icons/partial.plist"
/usr/bin/assetutil --info "$mac_stage_root/icons/Assets.car" > "$mac_stage_root/icons/assets.json"
python3 - "$mac_stage_root/icons/assets.json" <<'ICON_OUTPUTS'
import json,sys
items=json.load(open(sys.argv[1]))
groups={x.get('Appearance'):x for x in items if x.get('AssetType')=='IconGroup'}
approved_dark='9F72419FF8BAB65D5A1E6952EAB1997418A34A2E613D2A0282404605930EDAD1'
named_dark=[x for x in items if x.get('AssetType')=='Image' and x.get('Name')=='Cellio_Assets/Dark']
assert len(named_dark)==1 and named_dark[0]['SHA1Digest']==approved_dark
for appearance in ['NSAppearanceNameAqua','NSAppearanceNameDarkAqua']:
 layers=groups[appearance]['Layers']
 assert len(layers)==1 and layers[0]['Name']=='Cellio_Assets/Dark'
 assert layers[0]['SHA1Digest']==approved_dark
 assert layers[0]['LayerSize']=='1024,1024' and not layers[0].get('LayerHasLightingEffects',False)
assert {x.get('Name') for x in items if x.get('AssetType')=='IconImageStack'}=={'Cellio'}
ICON_OUTPUTS
# The compiled native layers above and the actual bundled fallback use approved Dark.
# actool's intermediate ICNS encoding varies with the host/toolchain and is not shipped.
cp "$mac_stage_root/icons/Assets.car" "$mac_staged_app/Contents/Resources/Assets.car"
cp Resources/Cellio.icns "$mac_staged_app/Contents/Resources/Cellio.icns"
python3 - "$mac_staged_app/Contents/Resources/Cellio.icns" <<'ICON_DEFAULT_FALLBACK'
from pathlib import Path
import hashlib,sys
expected='c07e095e76ad3baba71f85d87a5e0873e864d26a2c9412a8ed90ba1d0b38b5a4'
if hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()!=expected:
 raise SystemExit('Bundled Dark ICNS mismatch')
ICON_DEFAULT_FALLBACK
python3 scripts/package-sparkle.py embed "$mac_staged_app"
# Keep distribution notices inside the signed app, not beside it in installers.
cp LICENSE THIRD_PARTY_NOTICES.md "$mac_staged_app/Contents/Resources/"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$mac_staged_app/Contents/Info.plist")" != Cellio.icns || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$mac_staged_app/Contents/Info.plist")" != Cellio ]]; then
    print -u2 "Missing native bundle icon declarations"
    exit 1
fi
# Only runtime resources and notices ship; never artwork inputs or tool intermediates.
if [[ -n "$(find "$mac_staged_app" -type f ! -path "$mac_staged_app/Contents/MacOS/cellio" ! -path "$mac_staged_app/Contents/Info.plist" ! -path "$mac_staged_app/Contents/Resources/Cellio.icns" ! -path "$mac_staged_app/Contents/Resources/Assets.car" ! -path "$mac_staged_app/Contents/Resources/LICENSE" ! -path "$mac_staged_app/Contents/Resources/THIRD_PARTY_NOTICES.md" ! -path "$mac_staged_app/Contents/Resources/Sparkle-LICENSE" ! -path "$mac_staged_app/Contents/Frameworks/Sparkle.framework/*" -print -quit)" ]]; then
    print -u2 "Unexpected file in staged app"
    exit 1
fi
mac_architectures=" $(xcrun lipo -archs "$mac_staged_app/Contents/MacOS/cellio") "
if [[ "$mac_architectures" != *" arm64 "* || "$mac_architectures" != *" x86_64 "* ]]; then
    print -u2 "Missing arm64 or x86_64 app slice"
    exit 1
fi
plutil -lint "$mac_staged_app/Contents/Info.plist"
mac_sign_identity="${CELLIO_SIGN_IDENTITY:-}"
mac_sign_mode="${CELLIO_SIGN_MODE:-${mac_sign_identity:+local}}"
mac_sign_keychain="${CELLIO_SIGN_KEYCHAIN:-}"
if [[ -n "$mac_sign_mode" && "$mac_sign_mode" != local && "$mac_sign_mode" != developer-id ]]; then
    print -u2 "Invalid CELLIO_SIGN_MODE: use local or developer-id"
    exit 1
fi
if [[ -n "$mac_sign_mode" && -z "$mac_sign_identity" ]]; then
    print -u2 "CELLIO_SIGN_MODE requires CELLIO_SIGN_IDENTITY"
    exit 1
fi
python3 scripts/package-sparkle.py sign "$mac_staged_app"
if [[ -n "$mac_sign_identity" ]]; then
    mac_sign_arguments=(--force --sign "$mac_sign_identity" --entitlements Resources/OpenBattery.entitlements)
    if [[ -n "$mac_sign_keychain" ]]; then
        mac_sign_arguments+=(--keychain "$mac_sign_keychain")
    fi
    if [[ "$mac_sign_mode" == developer-id ]]; then
        print "Signing mode: Developer ID (hardened runtime and secure timestamp)"
        mac_sign_arguments+=(--options runtime --timestamp)
    else
        print "Signing mode: local certificate (no distribution/notarization claim)"
        mac_sign_arguments+=(--timestamp=none)
    fi
    codesign "${mac_sign_arguments[@]}" "$mac_staged_app"
else
    print "Signing mode: ad-hoc development (automatic sharing resume paused)"
    codesign --force --sign - --entitlements Resources/OpenBattery.entitlements "$mac_staged_app"
fi
codesign --verify --deep --strict --verbose=2 "$mac_staged_app"
codesign --display --verbose=4 "$mac_staged_app" 2> "$mac_stage_root/signing.txt"
if [[ -n "$mac_sign_identity" ]]; then
    # Extraction verifies a real certificate chain, including a single local
    # self-signed leaf. It never imports, trusts, or searches for an identity.
    codesign --display "--extract-certificates=$mac_stage_root/signing-cert-" "$mac_staged_app"
    python3 - "$mac_stage_root/signing.txt" "$mac_sign_mode" "$mac_stage_root/signing-cert-0" <<'SIGNING_IDENTITY'
from pathlib import Path
import sys
metadata=Path(sys.argv[1]).read_text().splitlines()
authorities=[line.removeprefix('Authority=').strip() for line in metadata if line.startswith('Authority=')]
certificate=Path(sys.argv[3])
if ('Signature=adhoc' in metadata or not authorities or not all(authorities)
    or not certificate.is_file() or certificate.stat().st_size==0):
 raise SystemExit('Supplied identity did not produce certificate-backed signing; refusing to publish')
if sys.argv[2]=='developer-id':
 teams=[line.removeprefix('TeamIdentifier=').strip() for line in metadata if line.startswith('TeamIdentifier=')]
 if (len(teams)!=1 or teams[0] in {'','not set'}
     or not any(authority.startswith('Developer ID Application:') for authority in authorities)
     or not any(line.startswith('Timestamp=') and line.removeprefix('Timestamp=').strip() for line in metadata)
     or not any(line.startswith('CodeDirectory ') and '(runtime)' in line for line in metadata)):
  raise SystemExit('Developer ID identity/runtime/timestamp validation failed; refusing to publish')
SIGNING_IDENTITY
fi
cat "$mac_stage_root/signing.txt"
python3 scripts/release-tool.py publish --staged "$mac_staged_app" --output "$mac_output_app"
