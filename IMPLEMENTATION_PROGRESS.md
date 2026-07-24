# OpenAVFoundation Implementation Progress

## Apple API trace

- [x] Framework-level AVFoundation families are inventoried
- [x] The capture-first subset is separated from full framework compatibility
- [x] Callable one-input/one-output graph behavior has a source marker

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
  actor (Native/WASM)
 owner-isolated (Embedded)
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
 atomic AVCaptureSession graph
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
- [x] Embedded owner-isolated registry using synchronous driver contract
- [x] same-object zero-copy `CMSampleBuffer` routing
- [ ] copy-count verification for sample routing
- [ ] device configuration facade
- [x] `AVCaptureInput` and `AVCaptureInput.Port`
- [x] Stable port reference identity without a Native/WASM retain cycle
- [x] `AVCaptureDeviceInput.init(device:)`
- [x] `AVCaptureOutput` and `AVCaptureConnection`
- [x] `AVCaptureVideoDataOutput` portable delegate
- [x] atomic session configuration transaction
- [x] one-input / one-output graph validation
- [x] preferred driver configuration at start
- [x] stream and handle lifecycle
- [x] partial-start rollback with retained cleanup ownership
- [x] `CMSampleBuffer` delivery
- [ ] multi-output sample fan-out and backpressure

## Progress

| Slice | Status | Evidence |
|---|---|---|
| Device facade | Implemented | Behavioral discovery tests |
| Provider registry | Implemented | Duplicate and unknown-provider tests |
| Discovery | Implemented | Two-provider identity and filtering tests |
| Authorization | Implemented | Status and request transition test |
| Embedded value facade | Implemented | Embedded WASM target build |
| Embedded provider registry | Implemented | Synchronous owner-isolated driver contract |
| Capture graph | Implemented | Atomic commit and rollback behavior tests |
| Single video output | Implemented | Same `CMSampleBuffer` reference reaches delegate |
| Lifecycle | Implemented | Ordered start, rollback, stop, and retry tests |
| Multi-output fan-out | Not started | Requires a later bounded-delivery slice |

## Test evidence

Verification commands and results are recorded here after execution.

| Target | Command | Result |
|---|---|---|
| macOS behavior smoke | `xcodebuild test ... -only-testing:OpenAVFoundationTests SWIFT_EXEC=.../swift-latest.xctoolchain/usr/bin/swiftc` | Passed on 2026-07-25: 16 tests with Swift 6.4 snapshot |
| WASM shared build | `swift build --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a_wasm --target OpenAVFoundation` | Passed on 2026-07-25: capture lifecycle included |
| Embedded WASM shared build | `swift build --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a_wasm-embedded --target OpenAVFoundation` | Passed on 2026-07-25: synchronous capture lifecycle included |

## Deliberately absent

- No automatic provider registration.
- No default fake or replay fallback.
- No concrete camera, operating-system, browser, or vendor integration.
- No registry-owned media bytes or payload conversion.
- The sample path never materializes payloads as an `Array`, `Data`, or byte
  collection.
- No multi-output fan-out, queue emulation, or implicit buffering is claimed.

## Embedded registry

Embedded Swift uses the synchronous owner-isolated
`CaptureDeviceProvider` contract. The registry retains only statically supplied
provider boxes, descriptor values, and device identities. It performs no
implicit provider loading and owns no media payload bytes.

## Capture lifecycle

Native/WASM resource operations run through an internal lifecycle actor.
Embedded uses the same state transitions synchronously under owner isolation.
Graph mutation uses short in-memory critical sections only; no Driver I/O occurs
while a graph mutex is held. The video output offers the Driver's existing
`CMSampleBuffer` object directly to its delegate and does not retain, decode, or
materialize payload bytes.
