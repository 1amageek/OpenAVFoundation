import Synchronization

public final class AVCaptureDevice: Hashable, Sendable {
    private struct ConfigurationState: Sendable {
        var capabilities: CaptureDeviceCapabilities?
        var selectedFormatID: CaptureDeviceFormatID?
        var selectedFrameRate: Double?
        var selectedControls = CaptureDeviceControls.none
    }

    private enum ControlUpdate: Sendable {
        case focus(CaptureFocusConfiguration)
        case exposure(CaptureExposureConfiguration)
        case whiteBalance(CaptureWhiteBalanceConfiguration)
        case zoom(CaptureZoomConfiguration)
    }

    let descriptor: CaptureDeviceDescriptor
    let captureDeviceID: CaptureDeviceID
    let handleOpener: CaptureDeviceHandleOpener
    private let configurationState = Mutex(ConfigurationState())

    init(
        descriptor: CaptureDeviceDescriptor,
        handleOpener: CaptureDeviceHandleOpener
    ) {
        captureDeviceID = descriptor.deviceID
        self.descriptor = descriptor
        self.handleOpener = handleOpener
    }

    public static func == (lhs: AVCaptureDevice, rhs: AVCaptureDevice) -> Bool {
        lhs.captureDeviceID == rhs.captureDeviceID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(captureDeviceID)
    }

    public var uniqueID: String {
        let driverNamespace = captureDeviceID.driverID.rawValue
        return "\(driverNamespace.utf8.count)#\(driverNamespace)\(captureDeviceID.localID)"
    }

    public var modelID: String {
        descriptor.modelID
    }

    public var localizedName: String {
        descriptor.localizedName
    }

    public var manufacturer: String {
        descriptor.manufacturer
    }

    public var deviceType: DeviceType {
        DeviceType(rawValue: descriptor.deviceTypeID.rawValue)
    }

    public var position: Position {
        Position(descriptor.position)
    }

    public var isConnected: Bool {
        descriptor.isConnected
    }

    public var isSuspended: Bool {
        descriptor.isSuspended
    }

    public func hasMediaType(_ mediaType: AVMediaType) -> Bool {
        descriptor.mediaTypes.contains {
            $0.rawValue == mediaType.captureRawValue
        }
    }

    public var activeFormat: Format? {
        withConfigurationState { state in
            guard let capabilities = state.capabilities else {
                return nil
            }
            let formatID =
                state.selectedFormatID ?? capabilities.preferredFormatID
            guard let descriptor = capabilities.formats.first(
                where: { $0.formatID == formatID }
            ) else {
                return nil
            }
            return Format(
                deviceID: captureDeviceID,
                capabilityRevision: capabilities.revision,
                descriptor: descriptor
            )
        }
    }

    public var activeVideoFrameRate: Double? {
        withConfigurationState { state in state.selectedFrameRate }
    }

    public var activeControls: CaptureDeviceControls {
        withConfigurationState { state in state.selectedControls }
    }

    public func cachedResolvedFormats()
        throws(AVCaptureDeviceError) -> [Format]
    {
        try withThrowingConfigurationState {
            state throws(AVCaptureDeviceError) in
            guard let capabilities = state.capabilities else {
                throw .capabilitiesNotResolved(captureDeviceID)
            }
            return Self.formats(from: capabilities)
        }
    }

    public func select(
        format: Format,
        frameRate: Double? = nil
    ) throws(AVCaptureDeviceError) {
        try withThrowingConfigurationState {
            state throws(AVCaptureDeviceError) in
            guard format.deviceID == captureDeviceID else {
                throw .foreignFormat(
                    expectedDeviceID: captureDeviceID,
                    actualDeviceID: format.deviceID
                )
            }
            guard let capabilities = state.capabilities else {
                throw .capabilitiesNotResolved(captureDeviceID)
            }
            guard format.capabilityRevision == capabilities.revision else {
                throw .staleFormat(
                    deviceID: captureDeviceID,
                    expectedRevision: capabilities.revision,
                    actualRevision: format.capabilityRevision
                )
            }
            guard let descriptor = capabilities.formats.first(
                where: { $0.formatID == format.formatID }
            ) else {
                throw .formatUnavailable(format.formatID)
            }
            if let frameRate,
               !descriptor.frameRateRanges.contains(where: {
                   $0.minimum <= frameRate && frameRate <= $0.maximum
               }) {
                throw .unsupportedFrameRate(
                    formatID: descriptor.formatID,
                    frameRate: frameRate
                )
            }
            state.selectedFormatID = descriptor.formatID
            state.selectedFrameRate = frameRate
        }
    }

    public func controlConfiguration(
        _ controls: CaptureDeviceControls
    ) throws(AVCaptureDeviceError) -> ControlConfiguration {
        try withThrowingConfigurationState {
            state throws(AVCaptureDeviceError) in
            guard let capabilities = state.capabilities else {
                throw .capabilitiesNotResolved(captureDeviceID)
            }
            try Self.validate(
                controls,
                state: state,
                capabilities: capabilities,
                deviceID: captureDeviceID
            )
            return ControlConfiguration(
                deviceID: captureDeviceID,
                capabilityRevision: capabilities.revision,
                controls: controls
            )
        }
    }

    public func select(
        controls: ControlConfiguration
    ) throws(AVCaptureDeviceError) {
        try withThrowingConfigurationState {
            state throws(AVCaptureDeviceError) in
            guard controls.deviceID == captureDeviceID else {
                throw .foreignControls(
                    expectedDeviceID: captureDeviceID,
                    actualDeviceID: controls.deviceID
                )
            }
            guard let capabilities = state.capabilities else {
                throw .capabilitiesNotResolved(captureDeviceID)
            }
            guard controls.capabilityRevision == capabilities.revision else {
                throw .staleControls(
                    deviceID: captureDeviceID,
                    expectedRevision: capabilities.revision,
                    actualRevision: controls.capabilityRevision
                )
            }
            try Self.validate(
                controls.controls,
                state: state,
                capabilities: capabilities,
                deviceID: captureDeviceID
            )
            state.selectedControls = controls.controls
        }
    }

    public func select(
        controls: CaptureDeviceControls
    ) throws(AVCaptureDeviceError) {
        try select(controls: controlConfiguration(controls))
    }

    public func setFocus(
        mode: CaptureFocusMode,
        lensPosition: Double? = nil,
        pointOfInterest: CaptureNormalizedPoint? = nil
    ) throws(AVCaptureDeviceError) {
        let focus: CaptureFocusConfiguration
        do {
            focus = try CaptureFocusConfiguration(
                mode: mode,
                lensPosition: lensPosition,
                pointOfInterest: pointOfInterest
            )
        } catch {
            throw .invalidControlContract(error)
        }
        try updateControls(.focus(focus))
    }

    public func setExposure(
        mode: CaptureExposureMode,
        duration: CMTime? = nil,
        iso: Double? = nil,
        pointOfInterest: CaptureNormalizedPoint? = nil
    ) throws(AVCaptureDeviceError) {
        let exposure: CaptureExposureConfiguration
        do {
            exposure = try CaptureExposureConfiguration(
                mode: mode,
                duration: duration,
                iso: iso,
                pointOfInterest: pointOfInterest
            )
        } catch {
            throw .invalidControlContract(error)
        }
        try updateControls(.exposure(exposure))
    }

    public func setWhiteBalance(
        mode: CaptureWhiteBalanceMode,
        gains: CaptureWhiteBalanceGains? = nil
    ) throws(AVCaptureDeviceError) {
        let whiteBalance: CaptureWhiteBalanceConfiguration
        do {
            whiteBalance = try CaptureWhiteBalanceConfiguration(
                mode: mode,
                gains: gains
            )
        } catch {
            throw .invalidControlContract(error)
        }
        try updateControls(.whiteBalance(whiteBalance))
    }

    public func setVideoZoomFactor(
        _ factor: Double
    ) throws(AVCaptureDeviceError) {
        let zoom: CaptureZoomConfiguration
        do {
            zoom = try CaptureZoomConfiguration(factor: factor)
        } catch {
            throw .invalidControlContract(error)
        }
        try updateControls(.zoom(zoom))
    }

    func configuration(
        for capabilities: CaptureDeviceCapabilities
    ) throws(AVCaptureSessionRuntimeFailure) -> CaptureDeviceConfiguration {
        do {
            try Self.validate(
                capabilities,
                deviceID: captureDeviceID,
                descriptorRevision: descriptor.capabilityRevision
            )
        } catch {
            throw .deviceConfiguration(error)
        }

        let selection: (
            formatID: CaptureDeviceFormatID?,
            frameRate: Double?,
            controls: CaptureDeviceControls
        )
        do {
            selection = try withThrowingConfigurationState {
                state throws(AVCaptureDeviceError) in
                state.capabilities = capabilities
                guard let selectedFormatID = state.selectedFormatID else {
                    return (nil, nil, state.selectedControls)
                }
                guard capabilities.formats.contains(
                    where: { $0.formatID == selectedFormatID }
                ) else {
                    throw .formatUnavailable(selectedFormatID)
                }
                return (
                    selectedFormatID,
                    state.selectedFrameRate,
                    state.selectedControls
                )
            }
        } catch {
            throw .deviceConfiguration(error)
        }

        let configuration: CaptureDeviceConfiguration
        do {
            configuration = try CaptureDeviceConfiguration(
                deviceID: captureDeviceID,
                capabilityRevision: capabilities.revision,
                formatID:
                    selection.formatID ?? capabilities.preferredFormatID,
                frameRate: selection.frameRate,
                controls: selection.controls
            )
        } catch {
            throw .contract(error)
        }
        do {
            return try capabilities.validatedConfiguration(configuration)
        } catch {
            throw .driver(operation: .configuration, error: error)
        }
    }

    func store(
        capabilities: CaptureDeviceCapabilities
    ) throws(AVCaptureDeviceError) -> [Format] {
        try Self.validate(
            capabilities,
            deviceID: captureDeviceID,
            descriptorRevision: descriptor.capabilityRevision
        )
        return withConfigurationState { state in
            state.capabilities = capabilities
            return Self.formats(from: capabilities)
        }
    }

    private static func formats(
        from capabilities: CaptureDeviceCapabilities
    ) -> [Format] {
        capabilities.formats.map { descriptor in
            Format(
                deviceID: capabilities.deviceID,
                capabilityRevision: capabilities.revision,
                descriptor: descriptor
            )
        }
    }

    private static func validate(
        _ capabilities: CaptureDeviceCapabilities,
        deviceID: CaptureDeviceID,
        descriptorRevision: UInt64
    ) throws(AVCaptureDeviceError) {
        guard capabilities.deviceID == deviceID else {
            throw .capabilityDeviceMismatch(
                expected: deviceID,
                actual: capabilities.deviceID
            )
        }
        guard capabilities.revision == descriptorRevision else {
            throw .capabilityRevisionMismatch(
                deviceID: deviceID,
                expected: descriptorRevision,
                actual: capabilities.revision
            )
        }
    }

    private static func validate(
        _ controls: CaptureDeviceControls,
        state: ConfigurationState,
        capabilities: CaptureDeviceCapabilities,
        deviceID: CaptureDeviceID
    ) throws(AVCaptureDeviceError) {
        let configuration: CaptureDeviceConfiguration
        do {
            configuration = try CaptureDeviceConfiguration(
                deviceID: deviceID,
                capabilityRevision: capabilities.revision,
                formatID:
                    state.selectedFormatID ?? capabilities.preferredFormatID,
                frameRate: state.selectedFrameRate,
                controls: controls
            )
        } catch {
            throw .invalidControlContract(error)
        }
        do {
            _ = try capabilities.validatedConfiguration(configuration)
        } catch {
            throw .unsupportedControls(error)
        }
    }

    private func updateControls(
        _ update: ControlUpdate
    ) throws(AVCaptureDeviceError) {
        let result: Result<Void, AVCaptureDeviceError> =
            configurationState.withLock { state in
            guard let capabilities = state.capabilities else {
                return .failure(.capabilitiesNotResolved(captureDeviceID))
            }
            let controls: CaptureDeviceControls
            let current = state.selectedControls
            switch update {
            case let .focus(focus):
                do throws(CaptureContractError) {
                    controls = try CaptureDeviceControls(
                        focus: focus,
                        exposure: current.exposure,
                        whiteBalance: current.whiteBalance,
                        zoom: current.zoom,
                        deviceSpecific: current.deviceSpecific
                    )
                } catch {
                    return .failure(.invalidControlContract(error))
                }
            case let .exposure(exposure):
                do throws(CaptureContractError) {
                    controls = try CaptureDeviceControls(
                        focus: current.focus,
                        exposure: exposure,
                        whiteBalance: current.whiteBalance,
                        zoom: current.zoom,
                        deviceSpecific: current.deviceSpecific
                    )
                } catch {
                    return .failure(.invalidControlContract(error))
                }
            case let .whiteBalance(whiteBalance):
                do throws(CaptureContractError) {
                    controls = try CaptureDeviceControls(
                        focus: current.focus,
                        exposure: current.exposure,
                        whiteBalance: whiteBalance,
                        zoom: current.zoom,
                        deviceSpecific: current.deviceSpecific
                    )
                } catch {
                    return .failure(.invalidControlContract(error))
                }
            case let .zoom(zoom):
                do throws(CaptureContractError) {
                    controls = try CaptureDeviceControls(
                        focus: current.focus,
                        exposure: current.exposure,
                        whiteBalance: current.whiteBalance,
                        zoom: zoom,
                        deviceSpecific: current.deviceSpecific
                    )
                } catch {
                    return .failure(.invalidControlContract(error))
                }
            }
            do throws(AVCaptureDeviceError) {
                try Self.validate(
                    controls,
                    state: state,
                    capabilities: capabilities,
                    deviceID: captureDeviceID
                )
            } catch {
                return .failure(error)
            }
            state.selectedControls = controls
            return .success(())
        }
        switch result {
        case .success:
            return
        case let .failure(error):
            throw error
        }
    }

    private func withConfigurationState<Result>(
        _ body: (inout ConfigurationState) -> Result
    ) -> Result {
        configurationState.withLock { state in
            body(&state)
        }
    }

    private func withThrowingConfigurationState<Result>(
        _ body:
            (inout ConfigurationState)
                throws(AVCaptureDeviceError) -> Result
    ) throws(AVCaptureDeviceError) -> Result {
        try configurationState.withLock {
            state throws(AVCaptureDeviceError) in
            try body(&state)
        }
    }
}
