# OpenAVFoundation implementation rules

Read `DESIGN.md` completely before changing this package.

- Preserve Apple's capture graph: device discovery creates devices; device inputs
  expose ports; connections map ports to outputs; sessions own graph
  configuration and runtime coordination.
- The compatibility target must not depend on a concrete camera, vendor SDK,
  browser API, operating system, inference engine, or Manas.
- Hardware and platform integrations implement `OpenAVFoundationDriver` in
  separate packages. Do not add a default fake driver or silently fall back to a
  replay source.
- Device identity is stable and driver-namespaced. Discovery is capability-based,
  not model-name branching.
- One opened source stream may feed multiple outputs. The session owns fan-out,
  timing correlation, buffer leases, and per-output backpressure.
- Configuration changes are atomic. Runtime and driver failures remain typed
  failures and must not be reported as successful capture.
- Keep shared targets free of Foundation, Objective-C, Dispatch, JavaScriptKit,
  Darwin, Glibc, camera SDKs, and GPU SDKs.
- Do not add an Apple-named declaration until its signature has been checked with
  `remark` and its behavior has a conformance test plan.
- Tests use Swift Testing. Run focused `xcodebuild test` commands with a timeout,
  plus WASM and Embedded builds for shared-source changes.
