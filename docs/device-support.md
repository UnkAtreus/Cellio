# Device compatibility

Status at the first public preview,2026-10-25. These are bounded observations and protocol candidates, not a claim that every product or connection from a brand works. Firmware, sleep/wake, charging and reconnect behavior can vary.

| Device or family | Connection / available path | Evidence and limits |
| --- | --- | --- |
| AirPods Pro | macOS accessory reports | Separate Left/Right/Case values have been displayed. Cached/disconnected reports can be retained; unknown measurement age does not become a fresh sample. Exact generation was not recorded. |
| Logitech MX Master4 | Logi Bolt receiver; Bluetooth | Real battery observations on the owned mouse. HID++ capability/identity handling supports linking transports where unit identity is established. More firmware/lifecycle coverage is needed. USB charging is not a wired data mode. |
| Logitech PRO X2 LIGHTSPEED | LIGHTSPEED receiver; Bluetooth accessory data | Real readings observed on both paths; Bluetooth cache readings have unknown sensor age.3.5mm analog has no battery-reporting channel, and USB-C charging is not an audio/data claim. |
| Fantech MAXFIT8 / MK921 | Bluetooth; wired USB/2.4GHz discovery | Bluetooth battery work and mode-specific discovery have been investigated on owned hardware. USB/receiver presence does not guarantee battery reporting; those battery paths remain incomplete/unverified. |
| SKYLOONG GK108S | USB/Bluetooth investigation | Device discovery was investigated; dependable battery support has not been established. A USB connection alone did not expose a usable battery value. |
| Other standard Bluetooth accessories | Battery Service180F / Battery Level2A19 | Capability-based reader for already-connected accessories. A matching service is a candidate path, not hardware certification for every model. |
| Other Logitech HID++ peripherals | Supported battery capabilities | Capability-based parsing and transactions; HID++ branding does not prove discovery, battery support or cross-transport identity. Model/firmware/mode reports are needed. |
| Keychron and other keyboard brands | Model/firmware-dependent | No claim of comprehensive hardware support. Stock/custom firmware and Bluetooth/USB/receiver paths must be verified separately. |
| Apple Watch | Companion work deferred | Not offered as a ready setup in this preview. |

A valid0% differs from unavailable, coarse, stale or retained data. The app keeps these distinctions. Lack of a reading in one collector does not prove the device is permanently unsupported.

[Request a device](request-device-support.md) without writing code. A useful report identifies the exact model and one connection mode, Cellio/macOS versions if known, and what Cellio and macOS/vendor software show. A charging cable, product name, model ID or receiver slot is not proof of a unique physical device.
