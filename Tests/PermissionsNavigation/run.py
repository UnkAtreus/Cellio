#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, os, shutil, subprocess, sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SCRATCH = ROOT / ".scratch" / "navigation-validation"
SOURCE = ROOT / "Sources/OpenBatteryMac/NativePermissions.swift"
ADAPTER = ROOT / "Sources/OpenBatteryMac/NativePermissionAdapters.swift"
FILES = [HERE / "Behavior.swift", HERE / "Support.swift", HERE / "run.py"]

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def digest(paths): return {p.relative_to(ROOT).as_posix(): sha(p) for p in paths}
def run(cmd, log):
    env = os.environ.copy()
    env["TMPDIR"] = str(SCRATCH / "tmp")
    p = subprocess.run(list(map(str, cmd)), cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text("$ " + " ".join(map(str, cmd)) + "\n" + p.stdout)
    return p.returncode, p.stdout

def main():
    SCRATCH.mkdir(parents=True, exist_ok=True); (SCRATCH / "tmp").mkdir(exist_ok=True)
    cache = ROOT / ".scratch/clang-cache"
    module_cache = SCRATCH / "module-cache"; module_cache.mkdir(exist_ok=True)
    frozen = digest(FILES)
    candidate_hashes = digest([SOURCE, ADAPTER])
    freeze = {"new_oracle_sha256": frozen, "candidate_source_sha256": candidate_hashes}
    (HERE / "frozen-hashes.json").write_text(json.dumps(freeze, indent=2) + "\n")
    runs = SCRATCH / "runs"
    if runs.exists(): shutil.rmtree(runs)
    runs.mkdir()
    results = []
    variants = [
        ("baseline", None),
        ("wrong-destination", "wrong-destination"),
        ("late-fallback-after-invalidation", "late-fallback"),
        ("unsupported-os-target-route", "future-route"),
    ]
    for name, mutation in variants:
        out = runs / name; out.mkdir()
        production = SOURCE.read_text()
        adapter_source = ADAPTER.read_text()
        if mutation == "wrong-destination":
            anchor = "case .bluetooth: self = fact.access == .allowed && fact.radio == .poweredOff ? .bluetoothRadio : .bluetoothPrivacy"
            broken = "case .bluetooth: self = .bluetoothPrivacy"
            assert anchor in production
            production = production.replace(anchor, broken, 1)
        elif mutation == "late-fallback":
            anchor = "guard !receivedTargetCompletion, isCurrent() else { return }"
            broken = "guard !receivedTargetCompletion else { return }"
            assert anchor in adapter_source
            adapter_source = adapter_source.replace(anchor, broken, 1)
            anchor = "guard isCurrent() else { return }\n            workspace.openApplication(application, completion: completion)"
            broken = "workspace.openApplication(application, completion: completion)"
            assert anchor in adapter_source
            adapter_source = adapter_source.replace(anchor, broken, 1)
        elif mutation == "future-route":
            anchor = "guard major == 26 || major == 27 else { openGeneric(); return }"
            broken = "guard major >= 26 else { openGeneric(); return }"
            assert anchor in adapter_source
            adapter_source = adapter_source.replace(anchor, broken, 1)
        prod = out / "NativePermissions.swift"; prod.write_text(production)
        adapter = out / "NativePermissionAdapters.swift"; adapter.write_text(adapter_source)
        binary = out / "navigation-tests"
        command = ["swiftc", "-module-cache-path", module_cache, "-parse-as-library", prod, adapter,
                   HERE / "Support.swift", HERE / "Behavior.swift", "-o", binary]
        code, output = run(command, out / "compile.log")
        if code:
            results.append({"name": name, "classification": "infrastructure", "compile_exit": code, "compile_log": str((out / "compile.log").relative_to(ROOT))})
            continue
        code, output = run([binary], out / "execution.log")
        failures = [line[6:] for line in output.splitlines() if line.startswith("FAIL: ")]
        summary = next((line for line in output.splitlines() if line.startswith("NAVIGATION_ASSERTIONS ")), None)
        if name == "baseline": classification = "semantic-pass" if code == 0 and summary and not failures else "semantic-red" if failures else "infrastructure"
        else: classification = "semantic-kill" if code == 1 and failures else "survived" if code == 0 else "infrastructure"
        results.append({"name": name, "classification": classification, "compile_exit": 0, "execution_exit": code,
                        "assertion_failures": failures, "summary": summary,
                        "mutant_source_sha256": {"NativePermissions.swift": sha(prod), "NativePermissionAdapters.swift": sha(adapter)},
                        "compile_log": str((out / "compile.log").relative_to(ROOT)), "execution_log": str((out / "execution.log").relative_to(ROOT)),
                        "command": list(map(str, command))})
    unchanged = digest(FILES) == frozen and digest([SOURCE, ADAPTER]) == candidate_hashes
    result = {"oracle_hashes_unchanged": digest(FILES) == frozen, "candidate_source_hashes_unchanged": digest([SOURCE, ADAPTER]) == candidate_hashes,
              "frozen_hashes": freeze, "cases": results}
    (HERE / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"unchanged": unchanged, "cases": [{"name": x["name"], "classification": x["classification"], "failures": x.get("assertion_failures", [])} for x in results]}, indent=2))
    return 0 if unchanged and results[0]["classification"] == "semantic-pass" and all(x["classification"] == "semantic-kill" for x in results[1:]) else 2

if __name__ == "__main__": sys.exit(main())
