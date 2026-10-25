# Build Cellio

Use a Mac with **Xcode27**, its macOS SDK and command-line tools, plus Python 3. The app targets macOS13+ and packages Apple silicon and Intel slices. The release uses Xcode27. Packaging checks the approved native Dark image layers and the exact canonical Dark ICNS shipped in the app. A discarded intermediate ICNS is not assumed to have identical serialized bytes across asset compiler/host versions.

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

The release script embeds and signs Sparkle’s helpers inside out, then signs and verifies the app. Do not use `codesign --deep` to sign. Preserve framework symlinks when copying or archiving the bundle. The initial preview archive contains the exact accepted build4; its corresponding source is the release tag.

CI selects GitHub’s [official `xcode-27` runner](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/) to match this requirement. The first default macOS26 runner used Xcode26.6: core/Permissions tests passed, but packaging rejected its different generated ICNS bytes. The original intermediate-file checksum was not a portable acceptance check: the Xcode27 runner also emitted different bytes. The corrected check verifies the actual bundled canonical ICNS; native layer/image/dimension/lighting checks and all immutable input hashes remain enabled.
