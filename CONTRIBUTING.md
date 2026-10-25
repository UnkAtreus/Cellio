# Contributing to Cellio

Device reports, reproducible bugs, documentation and code are welcome. Start with an issue for a new reader or a substantial interaction change.

## Add a device

Use [Request device support](https://github.com/UnkAtreus/Cellio/issues/new?template=device-support.yml). Share the exact model, one connection mode, and what appears in Cellio or macOS. Unknown details are fine. Never attach a whole system report, raw Bluetooth addresses, serial numbers, pairing information or unrelated diagnostics.

For engineering work, establish discovery, transport, battery access and identity separately. A model name or USB product ID does not establish physical identity or battery support. Record each tested connection mode independently. Charging-only USB and analog audio must not be labeled wired data support.

Reuse an existing capability-based reader when it actually matches the device. A new protocol needs documentation and bounded read-only transactions. Avoid guessed commands, exclusive device access, firmware changes or requiring vendor apps to quit. Keep unknown, retained, coarse and genuinely reported percentages distinct.

Link different transports only with sufficiently strong device identity. Do not merge two physical units by model/name or reuse a receiver/slot identity for a replacement peripheral. Preserve an explicit unlink path.

Use synthetic regression fixtures. Ask separately before reusing an owner’s report or attachments as retained compatibility evidence or test data. Attribute community reports as community reports; automated fixtures are not hardware testing.

## UX/UI ownership

A dedicated UX/UI expert defines the changed interaction before implementation and reviews the actual native result. Follow [the UX checklist](docs/ux-ui.md), including light/dark appearance, compact windows, keyboard focus and missing-data states. Passing core tests does not establish native usability.

## Implementation boundaries

Cellio uses clean-room separation when studying another application: an observer records behaviors and evidence, a reviewer approves supported rules, and a fresh builder works from that approved specification and Cellio-owned code. Do not supply reference binaries, source, assets, captures or observer history to the builder. Original first-party Cellio artwork is an approved input.

Keep assertions independent of the implementation. Where a change warrants mutation validation, compile and run three intentionally broken production variants against the frozen tests; compilation failures do not count as successful mutation detection. A fresh reviewer assesses the exact delivered candidate and states remaining limits honestly.

Use the model roles in the README as development workflow choices. A different role/model is acceptable only when explicitly recorded; do not claim an unrun review or hardware check.

## Checks

Run `swift test` and the relevant focused native checks. The macOS app builds with `CELLIO_ADHOC_DEVELOPMENT=1 ./scripts/build-macos.sh` for intentional local testing. Do not commit signing material, local preferences, captured device data, compiled test outputs or private QA histories.

Keep the build universal, preserve native framework symlinks, and retain third-party licenses. Changes to signing identity or updater configuration need an explicit migration plan. See [building](docs/building.md) and [signing](docs/signing.md).

Contributions to original Cellio code are under GPL-2.0-only. Preserve third-party notices.
