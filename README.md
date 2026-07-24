# OpenAVFoundation

OpenAVFoundation is a pure-Swift implementation target for the Swift-visible
AVFoundation API on platforms where Apple's framework is unavailable.

The package is currently at the basic capture-graph Smoke stage. Its package
boundary contains:

- `OpenAVFoundation`: the Apple-compatible public API product.
- `OpenAVFoundationDriver`: a sibling package dependency containing the platform
  integration contract for independently packaged camera, microphone, replay,
  browser, and embedded drivers.

No concrete device is built into the package. A Jetson CSI camera, USB camera,
browser camera, prerecorded stream, or future sensor becomes available through a
driver implementation without changing the compatibility layer.

Explicit provider registration, multi-provider discovery, stable
driver-namespaced device identity, authorization mapping, capture input ports,
atomic one-input / one-video-output session configuration, typed lifecycle
failures, and synchronous zero-copy sample delivery are implemented.

```text
provider → device → device input → connection → video data output
                                             │
                                             └─ same CMSampleBuffer → delegate
```

Drivers remain separate packages. The compatibility layer opens the selected
Driver handle only when the session starts, applies its preferred configuration,
and shuts down stream then handle when the session stops.

Multi-output fan-out, bounded backpressure, and additional Apple output types
remain later implementation slices.

## Supported production targets

- WebAssembly, with browser drivers supplied separately
- Embedded Swift, with statically composed hardware drivers

Apple-platform builds are used for compatibility and conformance testing. Apps on
Apple platforms should import Apple's `AVFoundation` framework.

## Design

Read [DESIGN.md](DESIGN.md) before adding public API, driver contracts, or capture
backends.
Use [APPLE_API_TRACE.md](APPLE_API_TRACE.md) to distinguish the current capture
subset from the complete Apple AVFoundation framework.

## Build

```bash
xcodebuild test -scheme OpenAVFoundation -destination 'platform=macOS' \
  -maximum-test-execution-time-allowance 30
swiftly run swift build --swift-sdk swift-6.3.1-RELEASE_wasm \
  --target OpenAVFoundation
swiftly run swift build --swift-sdk swift-6.3.1-RELEASE_wasm-embedded \
  --target OpenAVFoundation
```
