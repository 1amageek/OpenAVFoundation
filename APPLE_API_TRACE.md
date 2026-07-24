# Apple AVFoundation API Trace

## Baseline

- Review date: 2026-07-24
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
| Capture setup | Device discovery, one input/output session graph | Partial |
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
| Device configuration | `AVCaptureDevice.h` | Driver-preferred format at session start | Partial | Public lock/configure facade and controls |
| `AVCaptureInput` and ports | `AVCaptureInput.h` | Device input and stable video ports | Partial | Audio and specialized ports |
| `AVCaptureOutput` and connections | `AVCaptureOutputBase.h` | One video output and automatic connection | Partial | Explicit connection editing and multiple outputs |
| `AVCaptureSession` | `AVCaptureSession.h` | Atomic idle graph transaction and ordered lifecycle | Partial | Runtime reconfiguration, presets, interruptions |
| `AVCaptureVideoDataOutput` | `AVCaptureVideoDataOutput.h` | Synchronous zero-copy sample delivery | Partial | Settings surface, drop callback, bounded queue policy |
| Output synchronization | `AVCaptureDataOutputSynchronizer.h` | No declaration | Planned | Correlated multi-output delivery |
| Audio/metadata/depth/photo outputs | Corresponding capture headers | No declaration | Planned | Separate behavior slices |
| Preview | `AVCaptureVideoPreviewLayer.h` | No shared declaration | Adapter | Platform presentation packages |

## Completion rule

Every partial callable branch carries `INCOMPLETE_IMPLEMENTATION` when it rejects
behavior that belongs to the intended capture contract. Completely absent API
families remain tracked here until a declaration is introduced.
