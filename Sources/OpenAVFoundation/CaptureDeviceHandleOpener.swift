#if hasFeature(Embedded)
struct CaptureDeviceHandleOpener: Sendable {
    let open:
        @Sendable (CaptureDeviceID)
            throws(CaptureDriverError) -> any CaptureDeviceHandle
}
#else
struct CaptureDeviceHandleOpener: Sendable {
    let open:
        @Sendable (CaptureDeviceID)
            async throws(CaptureDriverError) -> any CaptureDeviceHandle
}
#endif
