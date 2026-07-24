#if hasFeature(Embedded)
struct CaptureDeviceHandleOpener {
    let open:
        (CaptureDeviceID)
            throws(CaptureDriverError) -> any CaptureDeviceHandle
}
#else
struct CaptureDeviceHandleOpener: Sendable {
    let open:
        @Sendable (CaptureDeviceID)
            async throws(CaptureDriverError) -> any CaptureDeviceHandle
}
#endif
