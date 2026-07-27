# Apple AVFoundation API Trace

## Baseline

- Review date: 2026-07-25
- SDK: macOS 27.0 from the active Xcode beta
- Documentation: Apple Developer Documentation read with `remark`
- Local evidence: `AVFoundation.framework/Headers`, the SDK symbol graph,
  package source, and behavior tests

AVFoundation is much larger than capture. The current package implements a
capture-first subset and does not claim asset, playback, editing, or audio-engine
compatibility.

## Framework-level trace

| Apple area | Open implementation | Status |
|---|---|---|
| Capture setup | Device discovery, one input/multiple-output session graph | Partial |
| Audio and video sample capture | Video data output only | Partial |
| Photo capture | No declaration | Planned |
| Depth, metadata, and synchronized outputs | No declaration | Planned |
| Media assets | No declaration | Planned |
| Media reading and writing | No declaration | Planned |
| Playback and sample-buffer rendering | No declaration | Planned |
| Editing and composition | No declaration | Planned |
| Audio engine, playback, and recording | No declaration | Planned |

## Capture-family trace

| Apple family | Header evidence | Open implementation | Status | Remaining behavior |
|---|---|---|---|---|
| `AVMediaType` and authorization | `AVMediaFormat.h`, `AVCaptureDevice.h` | Typed media values and provider authorization mapping | Partial | Broader media families |
| `AVCaptureDevice` discovery | `AVCaptureDevice.h` | Explicit provider registry, filtering, stable identity | Partial | Synchronous snapshot observation and hot-plug |
| Device configuration | `AVCaptureDevice.h` | Explicit capability resolution plus revision-bound format, frame-rate, focus, exposure, white-balance, and zoom staging | Partial | Configuration locking parity, subject-area monitoring, smooth autofocus, torch, and specialized controls |
| `AVCaptureInput` and ports | `AVCaptureInput.h` | Device input and stable video ports | Partial | Audio and specialized ports |
| `AVCaptureOutput` and connections | `AVCaptureOutputBase.h` plus `remark` connection-property review | Multiple video outputs, automatic connections, rotation-angle validation, and staged stabilization/mirroring | Partial | Broader capability properties, explicit connection editing, and additional output types |
| `AVCaptureSession` | `AVCaptureSession.h` | Failure-atomic graph lifecycle plus typed interruption, pressure, source-drop, and terminal-failure state | Partial | Runtime graph reconfiguration and presets |
| `AVCaptureVideoDataOutput` | `AVCaptureVideoDataOutput.h` | Bounded zero-copy delivery and portable metadata-only source-drop callback | Partial | Video settings surface; Apple's dropped callback carries a platform sample buffer instead |
| Output synchronization | `AVCaptureDataOutputSynchronizer.h` | No declaration | Planned | Correlated multi-output delivery |
| Audio/metadata/depth/photo outputs | Corresponding capture headers | No declaration | Planned | Separate behavior slices |
| Preview | `AVCaptureVideoPreviewLayer.h` | No shared declaration | Adapter | Platform presentation packages |

## Completion rule

Every partial callable branch carries `INCOMPLETE_IMPLEMENTATION` when it rejects
behavior that belongs to the intended capture contract. Completely absent API
families remain tracked here until a declaration is introduced.
