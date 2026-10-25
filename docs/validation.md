# Validation scope

The published `swift test` target uses `Tests/PortableCoreTests`: portable, hardware-independent regression tests for parsing, quantities, freshness, device identity, preferences, hidden devices, alerts, retries and Bluetooth state handling. The app/core source and executable are unchanged by this test-publication layout.

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
