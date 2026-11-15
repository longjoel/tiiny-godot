# Story 03 — verification in progress

This is progress evidence, not acceptance. Story 02 remains incomplete and is a dependency. The current implementation and Linux editor build have not been accepted for real mutating device operations.

| Parent criterion | Evidence so far | Remaining proof |
| --- | --- | --- |
| Bind management and inference to the intended device | The two-endpoint loopback fixture checks real HTTP requests to one fake endpoint, rejects a second endpoint, and verifies the fake CLI's explicit address. The device accepted a real read-only inventory request. See [sanitized loopback report](03-two-device.json) and [live report](03-live-readonly.json). | Real coding-model inference and a real model-management operation on the same device remain unverified. |
| Validate and persist coding model | Fake-device Apply rejects incompatible capabilities before mutation and records a verified selection; the built-in FIFO fixture checks persistence. | Hardware validation of a deliberate model configuration remains open. |
| Confirm download and load from device state | Fake-device fixtures reject zero-exit commands without the corresponding installed/loaded state and reject mismatched NPU allocation. The FIFO stores and verifies model-operation checkpoints. | Real download/load completion and reported progress have not been exercised. |
| Restore and protect coding model | Fake-device fixtures cover periodic startup/reconnect checks, missing-model download/load, no-eviction capacity rejection, stale requests, and preflight for chat, resource and Apply jobs. | Real startup/reconnect restoration remains unverified. The current device has no compatible coding model warm and the planned warm set fails the configured NPU reserve check; no existing model was unloaded. |
| Recoverable failure without false readiness | Fake-device checks cover auth/disconnect/capacity, partial results, cancellation, read-only observation and explicit acknowledgement. Process-kill tests cover cross-project markers for model operations and inference, plus a malformed marker. | Selected hardware fault injection and final UI review remain open. An observation does not prove a remote process stopped; uncertain work cannot be blindly retried. |

The live read-only check on November 15, 2026 reached the Tiiny and rejected the proposed warm set (109 NPU units plus 5 reserved against 100 available), without Apply. The attempted live inference check found only an image model warm, sent no inference request, and confirmed the warm set was unchanged. No real model was downloaded, loaded, or unloaded in this verification.

The current scope does not establish DEV-01's on-demand specialized-model swapping and restoration after that specialized work; the scheduling capability remains assigned to story 10. This is an open scenario boundary, not a claim that it was tested.
