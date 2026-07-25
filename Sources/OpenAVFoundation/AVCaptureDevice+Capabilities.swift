#if hasFeature(Embedded)
extension AVCaptureDevice {
    public func resolvedFormats()
        throws(AVCaptureDeviceError) -> [Format]
    {
        let handle: any CaptureDeviceHandle
        do {
            handle = try handleOpener.open(captureDeviceID)
        } catch {
            throw .providerFailure(
                driverID: captureDeviceID.driverID,
                error: error
            )
        }

        let snapshot: CaptureDeviceSnapshot
        do {
            snapshot = try handle.snapshot()
        } catch {
            let primary = error
            do {
                try handle.shutdown()
            } catch {
                throw .capabilityCleanupFailure(
                    primary: primary,
                    cleanup: error
                )
            }
            throw .providerFailure(
                driverID: captureDeviceID.driverID,
                error: primary
            )
        }

        do {
            try handle.shutdown()
        } catch {
            throw .providerFailure(
                driverID: captureDeviceID.driverID,
                error: error
            )
        }
        return try store(capabilities: snapshot.capabilities)
    }
}
#else
extension AVCaptureDevice {
    public func resolvedFormats()
        async throws(AVCaptureDeviceError) -> [Format]
    {
        let handle: any CaptureDeviceHandle
        do {
            handle = try await handleOpener.open(captureDeviceID)
        } catch {
            throw .providerFailure(
                driverID: captureDeviceID.driverID,
                error: error
            )
        }

        let snapshot: CaptureDeviceSnapshot
        do {
            snapshot = try await handle.snapshot()
        } catch {
            let primary = error
            do {
                try await handle.shutdown()
            } catch {
                throw .capabilityCleanupFailure(
                    primary: primary,
                    cleanup: error
                )
            }
            throw .providerFailure(
                driverID: captureDeviceID.driverID,
                error: primary
            )
        }

        do {
            try await handle.shutdown()
        } catch {
            throw .providerFailure(
                driverID: captureDeviceID.driverID,
                error: error
            )
        }
        return try store(capabilities: snapshot.capabilities)
    }
}
#endif
