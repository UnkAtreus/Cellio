# Third-party components

## Sparkle 2.10.0

Cellio bundles the unmodified, pinned official Sparkle framework and `sign_update` tool for application updating. The framework is re-signed during application packaging. Upstream source and release: https://github.com/sparkle-project/Sparkle/tree/2.10.0 and https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0.

Archive SHA256: `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`.

Sparkle and its bundled components have their own MIT, BSD and other permissive notices, reproduced in [Vendor/Sparkle-LICENSE](Vendor/Sparkle-LICENSE). Those notices govern the third-party files; Cellio’s GPL does not replace them. The application also includes the Sparkle license in its resources.

## Apple system frameworks and symbols

Cellio uses the macOS SDK and runtime system frameworks. Device symbols come from the operating system’s SF Symbols API; Apple SDK/framework source is not included in this repository. Apple, AirPods and other product names belong to their owners. Cellio is an independent project and does not imply vendor endorsement.
