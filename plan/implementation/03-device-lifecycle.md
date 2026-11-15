# Story 03 implementation plan — device binding and protected coding-model lifecycle

Status: Queued. Story 01 accepted; story 02 9 of 10 acceptance criteria verified (displayed editor and Tiiny device coordination deferred per the work item).

Parent: [03 — Device binding and protected coding-model lifecycle](../work-items/03-device-lifecycle.md)

## Execution contract

Use the shared job manager from story 02 for device lease coordination, long-running work, and state persistence. Do not introduce another queue or compete with the existing FIFO for model operations. The existing manager (`tiiny_ai_manager_source.h`) already acquires the job manager's device lease for refresh/check/apply and uses `OS.execute_with_pipe` with bounded timeout for CLI operations. Story 03 extends this interface; it does not replace it.

Coding model protection means the manager never deliberately evicts the configured coding model for another job, even when space is scarce. On startup or reconnect, the coding model is restored first. Disconnects, authentication failures, and capacity failures leave a clear, recoverable state without reporting readiness.

## Backlog review and boundary

Story 01 is accepted. Story 02 is near-accepted (9 of 10 criteria verified; displayed editor and Tiiny device coordination deferred). Story 03 extends the established manager and job lease interfaces with device binding, coding-model protection, and explicit error-state recovery. Story 04's Models settings UI depends on story 03's validation and persistence gates.

The existing manager already:
- Uses `_acquire_device`/`_release_device` on the job manager for refresh/check/apply.
- Runs CLI operations (`download`, `load`, `unload`) through `_run_cli` with bounded timeout and `ProgressReader`.
- Verifies each operation from device state after `_run_cli` returns (e.g., `observed.loaded.has(action.id)` for loads).
- Persists the applied configuration in `_tiiny_ai/applied_configuration` and restores it at startup.
- Rejects incompatible role/model pairs in `Planner.check`.

Story 03 does not rewrite the manager; it closes the gaps:
1. **Device binding:** verify that management and inference reach the intended device (not a stale or wrong target).
2. **Download/load completion from device state:** confirm progress through device-reported state, not CLI exit alone.
3. **Coding model protection on startup/reconnect:** restore the coding model first; never evict it for another job.
4. **Error-state handling:** disconnect, auth failure, and capacity failure must leave recoverable, non-ready state.

## Slice A — device binding and discovery

Extend the manager's connection path to verify that every operation targets the intended device, and expose the binding identity through the snapshot.

### Implementation

1. **Connection identity verification:** The existing `_connection()` already derives `identity` as `address|key`.sha256_text(). Extend this into a stable `connection_identity` property on the snapshot. Verify that every snapshot, check, and apply operation uses the same identity. This is the existing `fresh.get("connection") != approved.connection` recheck in `apply_config` — make this the explicit binding gate for all device operations.

2. **CLI device-address pinning:** The existing `_run_cli` already pins the CLI to the device whose plan was checked (`--device-address <device>`). Verify this works for management operations (download, load, unload) and that inference requests (via the OpenAI-compatible API URL) resolve to the same device address.

3. **Address binding smoke test:** Add a headless fixture that configures two loopback addresses, one with valid credentials and one without. Verify that management and inference operations only reach the configured device. The fixture sets `tiiny_ai/advanced/device_address`, runs a fake CLI that logs its `--device-address` argument, and asserts it matches the intended target. No real device operations run.

4. **Address migration validation:** Validate that device addresses are hostnames/IPs only (no URL schemes or paths). Existing validation already rejects `/` and ` ` in the address, IPv6 bracket wrapping, and the `tiiny_ai/advanced/device_address`/`_tiiny_ai/config.json` priority. No code changes needed here; record the existing behavior.

### Gate

- Fake manager fixture: `_connection` returns matching `identity` for both management and inference; CLI operations are invoked with the correct `--device-address`; the `connection_identity` in the snapshot is stable across refresh/check/apply.
- No test contacts a real device.

### Deliverables

- Updated `fake_model_manager.gd` with connection identity verification.
- Headless test fixture that exercises address binding.

## Slice B — coding model validation and persistence

Verify and persist the selected coding model, rejecting incompatible capabilities before changing device state.

### Implementation

1. **Capability validation gate:** The existing `Planner.suitable` already checks `ROLE_TYPES` against `model.type` and enforces `Tool Use` support for the coding model. This is the correct gate. Add an explicit pre-check in the Apply path that validates the coding model has `Tool Use` support before issuing any `load` action. This is already partially covered by `Planner.check` error generation, but should be called out as a distinct gate before device state changes.

2. **Persisted coding model verification:** On startup, after restoring the applied configuration, verify the persisted coding model is still in the catalog and compatible. If the catalog has changed (e.g., model deprecated), reject silently by keeping the previous warm state and recording a log message rather than unloading a running model. The existing `_initialize_draft_from_snapshot` already maps existing selections; add a compatibility recheck.

3. **Fake-manager verification:** Create a fake manager variant that reports a catalog with only one model (e.g., a text-to-image model). Verify that the coding model picker shows no options, the settings persist the empty/default state without device mutation, and no false readiness occurs. This exercises the validation gate with a controlled fixture.

### Gate

- `Planner.suitable` rejects incompatible role/model pairs in tests.
- Fake catalog with no compatible coding model produces errors, no device mutation, and clear "Choose a scripting model" message.
- Applied configuration with a now-incompatible model survives restore without unloading; logs a warning.

### Deliverables

- Fake-manager catalog fixture with incompatible-only models.
- Startup validation recheck in the manager.

## Slice C — confirm downloads and loads from device state

Confirm downloads and load completion from device state rather than process exit alone.

### Implementation

1. **Download completion verification (already partially in place):** The existing `apply_config` verifies downloads by checking `observed.models[id].installed` after `_run_cli` returns. This is correct. However, the `ProgressReader` and `_poll_download_progress` already track per-model progress during the CLI run. Add an explicit pre-condition: if download progress stalls at the same percentage for more than 60 seconds, record a warning and consider the operation incomplete even if the CLI exit code is 0. The existing `_run_cli` already blocks on process completion; add a timeout guard.

2. **Load completion verification (already in place):** The existing `apply_config` verifies loads by checking `observed.loaded.has(action.id)`. This is correct. Add a verification that the loaded model's NPU allocation matches the expected value from the snapshot (not just presence/absence). This guards against partial loads.

3. **Progress stall detection:** Add a timeout to `_run_cli` for download operations. The existing code already uses a hard timeout on the `timeout` command (`3600s`). Replace this with a role-specific timeout: downloads get a longer timeout with a progress-stall guard, loads get a shorter timeout. The stall guard checks that `ProgressReader` output has advanced at least 1% since the last poll; if stalled, record a warning in the operation log.

4. **Fake-manager fixture for download/load verification:** Create a fixture that simulates a download that exits 0 but leaves the model's `installed` flag false, and a load that exits 0 but leaves the model out of `loaded`. Verify that the manager rejects both and stops. Also simulate a load that exits 0 but the model is only partially loaded (NPU allocation mismatch). Verify the manager detects this from device state.

5. **Interrupted download/load recovery:** When a download or load is interrupted (device disconnect, timeout), the operation record should capture the last known progress. On restart, the manager should present the interrupted state for an explicit decision — retry or skip — without attempting to resume or re-download blindly. The existing `check_recovery` mechanism for jobs applies here too.

### Gate

- Fake-manager fixture: download exits 0 but `installed` is false → rejected. Load exits 0 but `loaded` is absent → rejected. Load exits 0 but NPU allocation is inconsistent → rejected.
- Interrupted download leaves a recorded progress state; restart requires explicit user decision.
- No test contacts a real device.

### Deliverables

- Fake-manager fixture with partial/fake completion.
- Progress stall detection in `_run_cli`.
- Interrupted operation recovery in the Apply path.

## Slice D — coding model protection on startup and reconnect

When a connection is available, restore the coding model first and never deliberately evict it for another job.

### Implementation

1. **Startup recovery with coding model priority:** When the editor starts and a saved configuration exists, the manager should first verify the coding model is loaded. If not, it should issue only the minimal `load` action for the coding model before anything else. This is the existing `is_ready()` check — but it should also drive an automatic recovery path for interrupted Apply operations.

2. **Never evict the coding model:** The existing `Planner.check` already includes a "protected switch" path: if the active coding model is loaded and the new coding model cannot coexist during the transition, it errors and no model is unloaded. This is correct. Make this the default behavior: only unload non-coding models to free space, and only if the coding model will not be affected.

3. **Specialized job scheduling protection:** When a job (e.g., image-to-3D generation) needs NPU space and the warm set would require unloading the coding model, the system should: (a) check whether a compatible specialized model can run alongside the warm set; (b) if not, defer the job or reject with a clear message; (c) never deliberately evict the coding model. This belongs in the job manager's worker dispatch, not the model settings. For story 03, add the gate to the job manager's `acquire_device`: if acquiring would conflict with a loaded coding model, deny the lease with a clear error rather than unloading anything.

4. **Reconnect recovery:** When the device becomes available after a disconnect, the manager should re-verify the coding model's loaded state from device inventory (not from process state). If the coding model is no longer loaded, restore it before any other operation. This is a `refresh_device` + `is_ready` check that drives automatic recovery.

5. **Fake-manager fixture for coding model protection:** Create a fixture that reports a warm set including the coding model, then simulates a request to load a specialized model. Verify that: (a) the coding model is not evicted; (b) the specialized model either loads if space permits, or the request is rejected with a clear capacity message; (c) the coding model's loaded state is reported correctly throughout.

### Gate

- Startup recovery restores the coding model before any other operation.
- Fake-manager fixture: coding model never evicted; specialized model loads only if space permits; capacity failure is a clear rejection.
- Job manager `acquire_device` denies lease when it would conflict with a loaded coding model.
- Reconnect recovery re-verifies coding model from device inventory, not process state.

### Deliverables

- Startup recovery path for coding model loading.
- Job manager `acquire_device` gate for coding model conflict.
- Reconnect recovery with device-inventory verification.
- Fake-manager fixture for coding model protection.

## Slice E — error-state handling for disconnect, auth failure, and capacity

Disconnect, authentication failure, and capacity failure leave a clear recoverable state without reporting readiness.

### Implementation

1. **Disconnect handling:** When the device becomes unavailable (network disconnect, service down), the manager should: (a) set `connected = false` and clear the `snapshot`; (b) report a clear status message; (c) disable Apply and readiness; (d) keep the existing configuration in the draft (not the applied configuration) so that reconnect can resume; (e) never report readiness while disconnected. The existing `refresh_device` already handles disconnect with `connected = false` and a clear message. Verify this is consistent across all paths (refresh, check, apply, idle).

2. **Authentication failure handling:** When the SDK returns an authentication error (e.g., expired token, invalid key), the manager should: (a) not treat it as a capacity error; (b) report an explicit authentication failure; (c) not attempt to retry with different parameters (no credential auto-rotation); (d) leave the device in a recoverable state where the user can correct credentials and re-verify. The existing code already distinguishes connection errors from capacity errors in the HTTP layer. Make the auth-failure message explicit in the UI.

3. **Capacity failure handling:** When the device reports insufficient NPU or SSD capacity, the manager should: (a) not attempt partial operations; (b) report the specific resource shortfall (e.g., "Keep-loaded models need X NPU units plus Y reserved; only Z exist"); (c) not unload any model to resolve the shortfall; (d) allow the user to adjust warm set or reserves and retry. The existing `Planner.check` already generates specific capacity errors. Verify the UI surfaces them accurately.

4. **Error state recovery:** When an error is resolved (device reconnects, credentials are corrected, capacity is freed), the manager should allow the user to refresh and proceed normally. No automatic recovery should happen — the user explicitly controls the transition.

5. **Fake-manager fixtures for each error type:** Create fixtures that simulate each error type:
   - **Disconnect:** `_fetch_snapshot` returns `{"error": "Connection refused"}`. Verify `connected = false`, no device mutation, Apply disabled.
   - **Auth failure:** `_fetch_snapshot` returns `{"error": "Invalid credentials"}`. Verify `connected = false`, no device mutation, Apply disabled, explicit auth-failure message.
   - **Capacity failure:** `_fetch_snapshot` returns a valid snapshot with `npu_total = 0`. Verify `connected = false`, no device mutation, Apply disabled, explicit capacity-failure message.

6. **UI state consistency:** Ensure that the Models panel, the chat dock, and the Output all report consistent states. When the device is unavailable, chat should not attempt inference; the panel should not show "Ready" or enable Apply. The existing `is_ready()` and `is_model_loaded()` checks already guard against this; verify they are consistent across all UI paths.

### Gate

- Three fake-manager fixtures (disconnect, auth failure, capacity failure) each produce: `connected = false`, no device mutation, Apply disabled, explicit error message.
- Error state recovery requires an explicit refresh — no automatic state transition.
- UI consistency: no path reports readiness or enables Apply while in an error state.

### Deliverables

- Fake-manager fixtures for each error type.
- Auth-failure UI handling.
- Error state recovery tests.

## Slice F — acceptance testing against DEV-01 and DEV-02

Verify the concrete acceptance scenarios from `plan/ACCEPTANCE_SCENARIOS.md`.

### DEV-01: Coding model never evicted, eligible models swapped, restoration after failure

1. **Simulated scheduler test:** Using the fake manager and the existing `Planner.check`, simulate a warm set with the coding model and one additional warm model. Request a specialized job that requires NPU space. Verify:
   - The coding model is never unloaded.
   - If the specialized model can load alongside the warm set, it loads; the warm set is restored afterward.
   - If the specialized model cannot load (insufficient NPU), the request is rejected with a clear capacity message; the coding model remains loaded.

2. **Restore on failure:** When a load operation fails mid-way (simulated by a fake manager that returns exit 0 for the first load but exit 1 for the second), verify:
   - Earlier completed operations are preserved.
   - The coding model remains loaded.
   - The system reports which operations completed and which failed.
   - Reconnect and refresh show a correct state.

### DEV-02: Disconnect, auth failure, capacity failure leave recoverable state

1. **Disconnect during download:** Simulate a download starting, then a disconnect mid-operation (fake manager returns error on the second `_fetch_snapshot`). Verify:
   - The download is stopped; no partial download is left on disk.
   - The system reports an interrupted download.
   - Reconnect and refresh show the model as not fully downloaded.
   - No false readiness.

2. **Auth failure during load:** Simulate a load starting, then an auth failure on the next snapshot check. Verify:
   - The load is stopped; no partial load is left on the device.
   - The system reports an auth failure.
   - Reconnect and refresh show the model as not loaded.
   - No false readiness.

3. **Capacity failure during download:** Simulate a download starting, then a capacity failure on the next snapshot check. Verify:
   - The download is stopped; no partial download is left.
   - The system reports a capacity failure.
   - Reconnect and refresh show the model as not fully downloaded.
   - No false readiness.

### Gate

- DEV-01: coding model never evicted; eligible models swapped; restoration after failure.
- DEV-02: disconnect/auth/capacity failures leave recoverable state; no false readiness.
- Both scenarios tested with fake manager fixtures; no real device operations.

## Implementation notes

- **Reuse existing interfaces:** The existing `_run_cli`, `_fetch_snapshot`, `is_model_loaded`, `is_ready`, `_acquire_device`, `_release_device`, `Planner.check`, and `Planner.suitable` are the target interfaces. Do not introduce parallel paths.
- **Fake manager extension:** Follow the existing pattern in `fake_model_manager.gd` — extend `"res://manager.gd"` and override `_get_json`, `_fetch_snapshot`, and `_run_cli` to control fixture state. Add new fixture-specific methods as needed (e.g., `_set_connection_failure`, `_set_capacity_failure`).
- **Test fixtures:** Each slice's fixtures should be self-contained, use a disposable test project, and not contact a real device. Reuse the existing `check_model_configuration.py` infrastructure for headless tests.
- **No new editor tabs:** Configuration remains under `Editor Settings > Tiiny AI: Models and Advanced`. Do not introduce standalone tabs.
- **ProgressReader:** Reuse the existing `ProgressReader` class for CLI output filtering. Extend its stall detection if needed.

## Acceptance evidence matrix

| Parent criterion | Evidence required | Target implementation |
| --- | --- | --- |
| Device binding and verification | Fake-manager fixture with two addresses; CLI `--device-address` argument logged; snapshot `connection_identity` stable across operations | Slice A |
| Coding model validation and persistence | Fake catalog with incompatible models → error, no mutation; applied config with incompatible model survives restore without eviction | Slice B |
| Download/load completion from device state | Fake manager: exit 0 but `installed=false` → rejected; exit 0 but `loaded` absent → rejected; NPU allocation mismatch → rejected; interrupted download leaves recorded progress | Slice C |
| Coding model protection on startup/reconnect | Fake-manager fixture: warm set + specialized job request; coding model never evicted; capacity rejection clear; startup recovery loads coding model first; reconnect re-verifies from device inventory | Slice D |
| Error-state handling | Fake-manager fixtures: disconnect, auth failure, capacity failure each produce `connected=false`, no mutation, Apply disabled, explicit message; recovery requires explicit refresh; UI consistency | Slice E |
| DEV-01 scenario | Simulated scheduler + fake manager; coding model never evicted; eligible models swapped; restoration after failure | Slice F |
| DEV-02 scenario | Simulated disconnect/auth/capacity during download/load; no partial state left; no false readiness; recoverable on reconnect | Slice F |

## Handoff

Record checks against every parent acceptance criterion, exact binary/configuration, fixture states, and remaining blockers. Story 03 gates story 04 (Models settings). Story 10 (on-demand specialized-model scheduling) extends story 03's job manager protection gate with full scheduler logic.
