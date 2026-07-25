# OpenAVFoundation

OpenAVFoundation is a pure-Swift implementation target for the Swift-visible
AVFoundation API on platforms where Apple's framework is unavailable.

The package has completed the basic capture-graph Smoke stage. Its package
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
failure-atomic one-input / multiple-video-output session configuration, explicit device
format and frame-rate selection, typed lifecycle failures, and bounded
zero-copy sample delivery are implemented.

```text
provider → device → device input → source stream
                                      ├─ connection → video output A
                                      └─ connection → video output B
                                              same CMSampleBuffer lease
```

Drivers remain separate packages. The compatibility layer opens the selected
Driver handle only when the session starts, applies its preferred configuration,
and shuts down stream then handle when the session stops.

Additional Apple output types remain later implementation slices.

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
  -maximum-test-execution-time-allowance 60 \
  SWIFT_EXEC="$HOME/Library/Developer/Toolchains/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a.xctoolchain/usr/bin/swiftc"
"$HOME/Library/Developer/Toolchains/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a.xctoolchain/usr/bin/swift" build \
  --swift-sdks-path "$HOME/Library/org.swift.swiftpm/swift-sdks" \
  --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a_wasm \
  --target OpenAVFoundation
"$HOME/Library/Developer/Toolchains/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a.xctoolchain/usr/bin/swift" build \
  --swift-sdks-path "$HOME/Library/org.swift.swiftpm/swift-sdks" \
  --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a_wasm-embedded \
  --target OpenAVFoundation
```
