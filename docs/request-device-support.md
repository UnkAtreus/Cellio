# Request support for your device

You can ask without programming knowledge or even installing Cellio.

1. Check [existing issues](https://github.com/UnkAtreus/Cellio/issues) for the same model and connection mode.
2. Open [Request device support](https://github.com/UnkAtreus/Cellio/issues/new?template=device-support.yml).
3. Fill in three required fields: **device model**, **connection mode**, and **what you observe**. Unknown / Not tested is fine.

Optional details: macOS/Cellio/firmware version, receiver model, whether macOS or the vendor app shows a battery value, a product/manual link, or a cropped screenshot. Use one issue per model and requested connection mode; link related modes.

GitHub issues are public. Remove personal names, serial numbers, Bluetooth addresses, credentials and unrelated device information. Do not attach whole system reports or packet captures. Terminal commands and diagnostic dumps are not required.

If a maintainer needs more information, they will ask for a small device-specific check and explain what it collects. Inspect any copied orange/red-dot diagnostic text before posting only the relevant redacted excerpt. The CLI snapshot does not reproduce every live Bluetooth reader/grouping path, so an empty snapshot is not proof of unsupported hardware.

A request starts an investigation, not a promise of support. Maintainers distinguish a missing reader from permission, discovery, transport, identity or stale-data problems. They may invite optional testing of a candidate build. They will ask separately before retaining your report as compatibility evidence or reusing an attachment as a regression fixture; an unanswered request is not consent.

Developers can start with [CONTRIBUTING.md](../CONTRIBUTING.md). There is no installable plugin SDK yet; small capability/profile additions and reviewed reader changes can be contributed through pull requests.
