# Signing and updates

The first public preview is signed with a persistent self-signed certificate. It is not Developer ID signed or notarized. First launch on another Mac may be blocked by Gatekeeper. If you trust the release, use [Apple’s documented Privacy & Security → Open Anyway flow](https://support.apple.com/en-us/102445). Do not disable system security globally.

For repeat local builds, retain the same certificate/private key and bundle identity. The maintainer observed Bluetooth, Input Monitoring and Notifications remaining Allowed across signed build2→3 and3→4 on the test Mac. This is a measured local result, not a guarantee across every machine, OS policy or future identity change. An intentional ad-hoc build has no stable certificate identity and can require renewed access.

The checked-in build code contains no private signing key. Normal builds require an explicitly supplied certificate or a private owner-only local configuration; they fail rather than silently switching to ad-hoc signing. `CELLIO_ADHOC_DEVELOPMENT=1` opts into an intentional development build. See [building](building.md).

Sparkle is integrated, but the initial preview has no configured public appcast or publisher key. Download updates from [Releases](https://github.com/UnkAtreus/Cellio/releases). Creating the GitHub repository does not enable automatic updating for an already-built app. Public feed setup and a signed update/relaunch check are the next release infrastructure task.

A future Developer ID/notarization migration must preserve user settings and explicitly test permission/keychain continuity. Do not rotate the self-signed identity casually, embed private keys, or ask users to install a broad trusted root certificate.
