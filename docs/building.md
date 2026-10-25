# Build Cellio

Use a Mac with **Xcode26.6 or Xcode27**, its macOS SDK and command-line tools, plus Python 3. The app targets macOS13+ and packages Apple silicon and Intel slices. The local release toolchain reports Xcode26.6 (17F113); both app slices declare minimum macOS13.0 and SDK26.5. CI separately uses Xcode27. Packaging checks the approved native Dark image layers and the exact canonical Dark ICNS shipped in the app. A discarded intermediate ICNS is not assumed to have identical serialized bytes across asset compiler/host versions.

```sh
git clone https://github.com/UnkAtreus/Cellio.git
cd Cellio
swift test
CELLIO_ADHOC_DEVELOPMENT=1 ./scripts/build-macos.sh
open dist/Cellio.app
```

`Vendor/Sparkle.xcframework`, its version receipt and license are pinned to the official2.10.0 distribution. Packaging verifies the framework hash, architecture, signatures and symlinks. `TestTools/sign_update` is the corresponding upstream release tool.

The normal build refuses an implicit ad-hoc fallback. Use the explicit development flag above, or supply your own stable code-signing identity:

```sh
CELLIO_SIGN_IDENTITY="Your Code Signing Certificate" \
CELLIO_SIGN_MODE=local \
./scripts/build-macos.sh
```

Create and retain your own signing identity; the project does not contain the maintainer’s certificate private key or keychain password. Local builds can also use the owner-only signing configuration resolved by `scripts/local-signing.py`. See [signing](signing.md).

Optional release inputs include `CELLIO_BUNDLE_VERSION`, `CELLIO_DISPLAY_VERSION`, `CELLIO_OUTPUT_APP`, and the paired `CELLIO_UPDATE_FEED_URL`/`CELLIO_UPDATE_PUBLIC_KEY`. Bundle versions must increase across updates. Public updater configuration must use a real HTTPS feed and its corresponding publisher key; never include a private key in an app or repository.

The build script embeds and signs Sparkle’s helpers inside out, then signs and verifies the app. It includes `LICENSE`, `THIRD_PARTY_NOTICES.md` and `Sparkle-LICENSE` in `Contents/Resources` before signing. Do not use `codesign --deep` to sign. Preserve framework symlinks when copying or archiving the bundle. The initial alpha.1 archive contains accepted build4; alpha.2 contains build5. Alpha.3 contains build6 with the same application source and bundled notices. To reproduce alpha.3 version metadata, add `CELLIO_BUNDLE_VERSION=6` to the build command. The app displays version1.0, build6.

Create both distribution formats from the signed app using native macOS tools:

```sh
python3 scripts/package-macos.py --app dist/Cellio.app \
  --version 1.0.0-alpha.3 --output-dir /tmp/cellio-alpha3-packages
```

The script checks the app signature, both architectures and bundled notices. It creates an app-only ZIP and a compressed, read-only DMG containing `Cellio.app` and an Applications shortcut. It preserves the app signature and framework symlinks, does not install the app, and refuses to replace existing output files. Use a fresh output directory for another attempt. The DMG is a container for the signed app, not a notarized installer. Publish corresponding source and SHA256 checksums alongside the downloads.

CI selects GitHub’s [official `xcode-27` runner](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/) for hosted build validation on macOS27. The first default macOS26 runner used Xcode26.6: core/Permissions tests passed, but packaging rejected its different generated ICNS bytes. The original intermediate-file checksum was not a portable acceptance check: the Xcode27 runner also emitted different bytes. The corrected check verifies the actual bundled canonical ICNS; native layer/image/dimension/lighting checks and all immutable input hashes remain enabled.

The architecture check reads `xcrun lipo -archs` and requires both `arm64` and `x86_64`. This preserves universal verification across the macOS27 system lipo argument-parser change; a real arm64-only test binary was rejected.
