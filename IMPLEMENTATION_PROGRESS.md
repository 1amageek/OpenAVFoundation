# OpenAVFoundation Implementation Progress

## Apple API trace

- [x] Framework-level AVFoundation families are inventoried
- [x] The capture-first subset is separated from full framework compatibility
- [x] One-input/multiple-output graph behavior has no incomplete callable branch

## Smoke definition

The second smoke is complete when an application can explicitly register a
provider, discover a device, build a one-device-input / one-video-output graph,
receive the driver's exact `CMSampleBuffer` object through the video delegate,
and stop both stream and handle. Invalid configuration and partial start failures
must roll back without corrupting the committed graph. Production code must not
install a fake, replay, or concrete camera provider.

```text
Explicit provider registration
             │
             ▼
 AVCaptureDeviceRegistry boundary
       Mutex (all targets)
       │             │
       │             └── authorization mapping
       ▼
provider snapshot ── nonisolated provider discovery
       │
       ▼
framework filtering and contract validation
       │
       ▼
stable AVCaptureDevice identity cache
             │
             ▼
 AVCaptureDeviceInput → Port
             │
             ▼
 failure-atomic AVCaptureSession graph
             │
             ▼
 open → snapshot → preferred configuration
             │
             ▼
 configure → stream → synchronous delegate offer
             │
             ▼
 stream shutdown → handle shutdown
```

## Required implementation

- [x] Apple API inventory reviewed with `remark`
- [x] `AVMediaType`
- [x] `AVAuthorizationStatus`
- [x] `AVCaptureDevice` identity and descriptor facade
- [x] `AVCaptureDevice.DeviceType`
- [x] `AVCaptureDevice.Position`
- [x] immutable discovery-session result
- [x] explicit thread-safe provider registry
- [x] discovery across multiple registered providers
- [x] framework-side discovery filtering
- [x] driver-namespaced stable object identity
- [x] authorization status mapping
- [x] authorization request mapping
- [x] typed duplicate-provider failure
- [x] typed unknown-provider failure
- [x] typed provider-operation failure
- [x] registry limited to descriptors and provider references
- [x] Embedded synchronized registry using synchronous `Sendable` driver contract
- [x] same-object zero-copy `CMSampleBuffer` routing
- [x] copy-count verification for sample routing
- [x] device configuration facade
- [x] revision-bound focus, exposure, white-balance, and zoom control staging
- [x] `AVCaptureInput` and `AVCaptureInput.Port`
- [x] Stable port reference identity without a Native/WASM retain cycle
- [x] `AVCaptureDeviceInput.init(device:)`
- [x] `AVCaptureOutput` and `AVCaptureConnection`
- [x] `AVCaptureVideoDataOutput` portable delegate
- [x] failure-atomic session configuration transaction
- [x] one-input / multiple-output graph validation
- [x] preferred driver configuration at start
- [x] stream and handle lifecycle
- [x] partial-start rollback with retained cleanup ownership
- [x] `CMSampleBuffer` delivery
- [x] multi-output sample fan-out and backpressure
- [x] typed interruption, resume, pressure, source-drop, and terminal-failure session events
- [x] undeclared stream events fail visibly instead of silently stopping
- [x] stream-request video orientation, stabilization, and mirroring policy
- [x] metadata-only source-drop fan-out to video delegates without a fake sample buffer

## Progress

| Slice | Status | Evidence |
|---|---|---|
| Device facade | Implemented | Behavioral discovery tests |
| Provider registry | Implemented | Duplicate and unknown-provider tests |
| Discovery | Implemented | Two-provider identity and filtering tests |
| Authorization | Implemented | Status and request transition test |
| Embedded value facade | Implemented | Embedded WASM target build |
| Embedded provider registry | Implemented | Synchronous `Sendable` driver contract and Mutex state |
| Capture graph | Implemented | Failure-atomic commit, rollback, and exclusive concurrent ownership tests |
| Single video output | Implemented | Same `CMSampleBuffer` reference reaches delegate |
| Lifecycle | Implemented | Ordered start, rollback, stop, and retry tests |
| Device configuration | Implemented | Explicit capability resolution, format selection, and frame-rate validation |
| Device controls | Implemented | Atomic control staging plus foreign, stale, unsupported, and partial-update preservation tests |
| Multi-output fan-out | Implemented | Same-object graph-ordered routing with independent bounded queue/drop state |
| Backpressure | Implemented | Configurable bounded pending count and observable typed drop reason |
| Shared-state parity | Implemented | Native/WASM/Embedded registry, graph, lifecycle, device, and delivery matrix use the same Mutex storage contract |
| Reentry and contention | Implemented | Provider reentry, delegate reentry, concurrent commit, and concurrent start behavior tests |
| Discovery duplicate validation | Implemented | Ordered bounded metadata scan on all targets; no regular-WASM `Set.insert` dependency |
| Registry metadata storage | Implemented | Ordered provider/device entry arrays on all targets; regular WASM callable discovery path |
| Low-level ownership boundary | Implemented | Two immutable strong endpoint wrappers, shared connection/delivery output wrapper, documented Port weak/unowned lifetime |
| Runtime event bridge | Implemented | Driver events map into typed session state and an injected sink outside locks |
| Video connection policy | Implemented | Per-connection configuration is validated and reaches `CaptureStreamRequest` |

## Test evidence

Verification commands and results are recorded here after execution.
The cross-target runs use
`swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a`
(`Swift 9517428e7f4b63e`, `LLVM 3704913b9103f85`) with the matching
`_wasm` and `_wasm-embedded` SDK identifiers and their
`wasm32-unknown-wasip1` target.

| Target | Command | Result |
|---|---|---|
| macOS behavior smoke | `xcodebuild test -scheme OpenAVFoundation -destination 'platform=macOS' -maximum-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO` | Passed on 2026-07-25: 33 tests |
| macOS Thread Sanitizer | Same command with `-enableThreadSanitizer YES` | Passed on 2026-07-25: 33 tests |
| WASM shared build | Exact snapshot `swift build --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a_wasm --target OpenAVFoundation` | Passed on 2026-07-25 |
| Embedded WASM shared build | Exact snapshot `swift build --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a_wasm-embedded --target OpenAVFoundation` | Passed on 2026-07-25 |
| WASM callable runtime | External fixture: register, discover, resolve formats, stage zoom, build graph, receive pressure event and the identical sample object, stop, and destroy resources | Passed on 2026-07-25 with the final remote dependency revisions |
| Embedded WASM callable runtime | Same external fixture with the matching Embedded SDK and explicit Unicode data-table link | Passed on 2026-07-25 with the final remote dependency revisions |
| Published dependency resolution | `swift package update` followed by fresh external runtime builds | Resolves Driver `d4b8a8c`, CoreMedia `07bd447`, and CoreVideo `6861652`; `Package.swift` contains URL dependencies only |

The earlier regular-WASM `CVBufferAttachments` initialization and destruction
trap was reduced to OpenCoreVideo, fixed there, and then verified through the
complete capture fixture on both WASM modes. Compile/link results remain separate
from these callable runtime results because they do not prove the specialized
`Mutex` initialization, event, delivery, and destruction paths.

## Deliberately absent

- No automatic provider registration.
- No default fake or replay fallback.
- No concrete camera, operating-system, browser, or vendor integration.
- No observation-output declaration or implicit Manas/inference integration.
- No registry-owned media bytes or payload conversion.
- The sample path never materializes payloads as an `Array`, `Data`, or byte
  collection.
- No unbounded output queue or implicit media-byte copy is permitted.

## Embedded registry

Embedded Swift uses the synchronous `Sendable`
`CaptureDeviceProvider` contract. The registry protects statically supplied
provider boxes, descriptor values, and device identities with `Mutex`, and
performs provider I/O only after releasing that lock. It performs no implicit
provider loading and owns no media payload bytes.

## Capture lifecycle

Native/WASM and Embedded resource operations reserve the same Mutex-protected
phase/resource lifecycle state before their asynchronous or synchronous Driver
calls. Graph mutation uses a two-phase reservation so input/output ownership and
connection locks are never acquired while graph state is locked. No Driver I/O
occurs while a graph or lifecycle mutex is held. A single source
stream routes the Driver's existing `CMSampleBuffer` object to every connected
video output. All targets use the same synchronous delivery contract and invoke
external delegates without holding framework locks. Each output owns independent
bounded queue/drop state, while route traversal remains graph ordered rather
than cross-output parallel. Dequeue clears its circular storage slot before
delegate invocation, retaining only the active sample plus the configured number
of pending sample leases. No target decodes or materializes payload bytes.
