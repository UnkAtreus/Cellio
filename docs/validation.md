# Validation scope

The published `swift test` target uses `Tests/PortableCoreTests`: portable, hardware-independent regression tests for parsing, quantities, freshness, device identity, preferences, hidden devices, alerts, retries and Bluetooth state handling. The initial test-publication restructure did not alter the app/core implementation or executable.

```sh
swift test
python3 Tests/PermissionsNavigation/run.py
python3 Tests/PermissionsNavigation/run-supplement.py
```

The Permissions runners preserve the independently written43-assertion navigation corpus and22 supplemental assertions. The first also compiles and runs three intentionally broken production variants and requires semantic failures: incorrect Bluetooth destination, late fallback after invalidation, and routing future OS versions as accepted. Compilation errors are not mutation kills. The exported runners use repository-relative paths and local ignored scratch outputs.

Before publication, running the old complete local target produced170 tests with54 assertion failures. Most failed in historical native campaign wrappers that deliberately bind old source manifests, old private receipt/capture layouts or retired UI contracts; one portable Bluetooth assertion expected an obsolete status phrase. These are recorded failures, not a claim that the old target was green. Twelve external campaign wrapper files and their private audit history remain archived locally. They are not published as runnable current regressions. The obsolete string assertion in the public copy now checks the semantic undetermined-authorization/no-pending-consent/no-Bluetooth-operation behavior, preserving the consent boundary rather than pinning incidental wording.

Release build4 also has separately recorded native acceptance:16 real Settings destinations across host macOS26.7.1 and guest27.0.1, with production view/controller/adapter and injected permission facts, plus four labeled workspace-failure feedback cases and actual main-shell keyboard Back/focus checks. The delivered host retained actual Bluetooth, Input Monitoring and Notifications Allowed across signed build3→4. Native captures and hardware reports contain private machine data and are not included here. These observations do not certify all devices, OS versions, VoiceOver or every lifecycle state.

Before the initial publication, a clean export of the public index passed155 portable tests with zero failures and the official universal development build. The public Permissions runners passed43+22 assertions and all three separately compiled runnable mutation kills.

GitHub Actions runs the published tests and a universal development build. Its actual run result is available on the repository’s Actions page; local checks and hosted checks are separate evidence.

## Alpha.2 — build 5

The alpha.2 code passes **164 portable tests**, including **18 focused menu bar tests**, and the hosted universal development build. The successful code run is [GitHub Actions40198471335](https://github.com/UnkAtreus/Cellio/actions/runs/40198471335); the release commit adds only documentation and image changes to that tested code.

Independent spacing tests reject three separately compiled, runnable broken production variants: restoring the generic icon tail, ignoring selected spacing, and losing spacing during persistence. Their assertion-failure counts were31,7 and26. The last core change was a comment only, verified directly against those mutation inputs; the final full suite was rerun without claiming a new mutation run.

The native spacing probe checks132 image-render combinations, measured percentage/gauge and state-marker spans, component labels, and optical separator geometry at1×/2× scales. Native keyboard input, slider endpoints and Reset were exercised in an isolated fixture using production controls. Dark/Light captures were reviewed. The real signed build5 shows the owner's two pinned readings, preserves their order and preferences, opens its native menu from the pinned status button, and retains Bluetooth, Input Monitoring and Notifications Allowed across build4→5 with the same signing requirement. The owner accepted the final spacing.

The exact signed executable also passes strict signature verification and a real snapshot JSON smoke check on macOS27.0.1. This is not a claim of complete guest GUI or hardware coverage. The earlier build4 Settings-destination observations above remain historical evidence. Physical devices, all assistive-technology configurations and every display/notch arrangement are not covered by synthetic tests.

## Alpha.3 — build 6

This release changes packaging and bundled notices; application source and UI are unchanged from alpha.2. The local universal build passes strict signature verification using the same persistent certificate and designated requirement as build 5. `LICENSE`, `THIRD_PARTY_NOTICES.md` and `Sparkle-LICENSE` are sealed inside `Cellio.app/Contents/Resources` before signing. This checks signature continuity; permission migration was not retested for this packaging change.

The ZIP contains only `Cellio.app`. The compressed read-only DMG shows the app and an Applications shortcut. ZIP extraction, mounting the DMG and copying its app into a temporary Applications directory preserve all 164 app entries, file contents, permissions and framework symlinks; each restored app passes strict signature verification. The bundled legal texts match the repository copies. Negative checks reject existing archive output, a previously signed app without the bundled notices and an invalid release path. Modifying the bundled GPL license invalidates the app signature.

The local portable suite passes 164 tests with zero failures. A separate macOS 27.0.1 guest also mounts the DMG, verifies the Applications shortcut and copies the app into a temporary Applications directory. The copied app passes strict signature verification and retains the exact build 6 executable hash. The alpha.2 native UI observations remain the evidence for the unchanged interface.

Hosted checks: [GitHub Actions 40218932148](https://github.com/UnkAtreus/Cellio/actions/runs/40218932148), covering the portable suite, Permissions regressions and mutation checks, universal development build, and both archive formats. The release tag adds documentation to that packaging code.
