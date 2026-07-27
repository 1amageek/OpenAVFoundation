import Dispatch
@testable import OpenAVFoundation
import Synchronization
import Testing

@Suite("Capture graph smoke")
struct CaptureGraphSmokeTests {
    @Test("Registry capture delivers the identical sample and stops resources")
    func captureDeliveryAndStop() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let delegate = RecordingVideoDelegate()
        output.setSampleBufferDelegate(delegate)

        let session = AVCaptureSession()
        try session.beginConfiguration()
        #expect(session.canAddInput(input))
        try session.addInput(input)
        #expect(session.canAddOutput(output))
        try session.addOutput(output)
        try session.commitConfiguration()

        #expect(session.inputs.count == 1)
        #expect(session.outputs.count == 1)
        #expect(session.connections.count == 1)
        #expect(output.connections.count == 1)
        #expect(session.connections[0].inputPorts[0].input === input)
        #expect(session.connections[0].inputPorts[0].mediaType == .video)
        let inputPort = try #require(input.ports.first)
        #expect(input.ports.first === inputPort)
        #expect(session.connections[0].inputPorts.first === inputPort)
        #expect(!session.isRunning)
        #expect(session.runtimeState == .idle)

        try await session.startRunning()

        #expect(session.isRunning)
        let delivery = await delegate.nextDelivery()
        let deliveredSample = try #require(delivery.sampleBuffer)
        let deliveredConnection = try #require(delivery.connection)
        #expect(deliveredSample === fixture.sampleBuffer)
        #expect(deliveredConnection === session.connections[0])
        #expect(deliveredConnection.output === output)

        try await session.stopRunning()
        try await session.stopRunning()

        #expect(!session.isRunning)
        #expect(
            fixture.events.values() == [
                "open",
                "snapshot",
                "configure",
                "stream",
                "stream.start",
                "stream.shutdown",
                "handle.shutdown"
            ]
        )
    }

    @Test("One source fans out the identical sample to multiple outputs")
    func multipleOutputFanoutPreservesSampleIdentity() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let firstOutput = AVCaptureVideoDataOutput()
        let secondOutput = AVCaptureVideoDataOutput()
        let firstDelegate = RecordingVideoDelegate()
        let secondDelegate = RecordingVideoDelegate()
        firstOutput.setSampleBufferDelegate(firstDelegate)
        secondOutput.setSampleBufferDelegate(secondDelegate)

        let session = AVCaptureSession()
        try session.beginConfiguration()
        try session.addInput(input)
        try session.addOutput(firstOutput)
        try session.addOutput(secondOutput)
        try session.commitConfiguration()

        #expect(session.outputs.count == 2)
        #expect(session.connections.count == 2)
        #expect(firstOutput.connections.count == 1)
        #expect(secondOutput.connections.count == 1)

        try await session.startRunning()
        async let firstDelivery = firstDelegate.nextDelivery()
        async let secondDelivery = secondDelegate.nextDelivery()
        let (first, second) = await (firstDelivery, secondDelivery)

        let firstSample = try #require(first.sampleBuffer)
        let secondSample = try #require(second.sampleBuffer)
        #expect(firstSample === fixture.sampleBuffer)
        #expect(secondSample === fixture.sampleBuffer)
        #expect(firstSample === secondSample)
        #expect(first.connection?.output === firstOutput)
        #expect(second.connection?.output === secondOutput)

        try await session.stopRunning()
        #expect(
            fixture.events.values() == [
                "open",
                "snapshot",
                "configure",
                "stream",
                "stream.start",
                "stream.shutdown",
                "handle.shutdown"
            ]
        )
    }

    @Test("Video output applies bounded independent backpressure")
    func boundedOutputBackpressure() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let delegate = BlockingVideoDelegate()
        output.setSampleBufferDelegate(delegate)
        output.alwaysDiscardsLateVideoFrames = false
        try output.setPendingSampleLimit(1)

        let connection = AVCaptureConnection(
            inputPorts: input.ports,
            output: output
        )
        let delivery = output.deliveryEndpoint

        let firstOperation = VideoOutputOfferOperation(
            delivery: delivery,
            sampleBuffer: fixture.sampleBuffer,
            output: output,
            connection: connection
        )
        let firstOffer = Task {
            firstOperation.offer()
        }
        #expect(delegate.waitUntilEntered())
        #expect(
            delivery.offer(
                fixture.sampleBuffer,
                output: output,
                from: connection
            ) == .accepted
        )
        #expect(
            delivery.offer(
                fixture.sampleBuffer,
                output: output,
                from: connection
            ) == .dropped
        )
        #expect(output.droppedSampleCount == 1)
        #expect(output.lastDropReason == .queueFull)
        #expect(throws: AVCaptureVideoDataOutputError.invalidPendingSampleLimit(-1)) {
            try output.setPendingSampleLimit(-1)
        }
        #expect(throws: AVCaptureVideoDataOutputError.invalidPendingSampleLimit(9)) {
            try output.setPendingSampleLimit(9)
        }

        delegate.release()
        #expect(await firstOffer.value == .accepted)
        #expect(delegate.deliveryCount() == 2)
    }

    @Test("Delivery releases each queued sample before later samples finish")
    func deliveryReleasesCompletedQueuedSamples() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let delegate = BlockingVideoDelegate()
        output.setSampleBufferDelegate(delegate)
        output.alwaysDiscardsLateVideoFrames = false
        try output.setPendingSampleLimit(1)

        let connection = AVCaptureConnection(
            inputPorts: input.ports,
            output: output
        )
        let delivery = output.deliveryEndpoint
        let firstOperation = VideoOutputOfferOperation(
            delivery: delivery,
            sampleBuffer: fixture.sampleBuffer,
            output: output,
            connection: connection
        )
        let firstOffer = Task {
            firstOperation.offer()
        }
        #expect(delegate.waitUntilEntered())

        var secondSample: CMImageSampleBuffer? = try fixture.makeSampleBuffer()
        let releasedSecondSample = WeakReference(secondSample)
        #expect(
            delivery.offer(
                try #require(secondSample),
                output: output,
                from: connection
            ) == .accepted
        )
        secondSample = nil

        delegate.releaseOne()
        #expect(delegate.waitUntilEntered())
        #expect(releasedSecondSample.value !== nil)

        var thirdSample: CMImageSampleBuffer? = try fixture.makeSampleBuffer()
        let retainedThirdSample = WeakReference(thirdSample)
        #expect(
            delivery.offer(
                try #require(thirdSample),
                output: output,
                from: connection
            ) == .accepted
        )
        thirdSample = nil

        delegate.releaseOne()
        #expect(delegate.waitUntilEntered())
        #expect(releasedSecondSample.value === nil)
        #expect(retainedThirdSample.value !== nil)

        delegate.releaseOne()
        #expect(await firstOffer.value == .accepted)
        #expect(retainedThirdSample.value === nil)
        #expect(delegate.deliveryCount() == 3)
    }

    @Test("Lowering the pending limit releases excess sample leases")
    func loweringPendingLimitReleasesExcessSamples() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let delegate = BlockingVideoDelegate()
        output.setSampleBufferDelegate(delegate)
        output.alwaysDiscardsLateVideoFrames = false
        try output.setPendingSampleLimit(3)

        let connection = AVCaptureConnection(
            inputPorts: input.ports,
            output: output
        )
        let delivery = output.deliveryEndpoint
        let firstOperation = VideoOutputOfferOperation(
            delivery: delivery,
            sampleBuffer: fixture.sampleBuffer,
            output: output,
            connection: connection
        )
        let firstOffer = Task {
            firstOperation.offer()
        }
        #expect(delegate.waitUntilEntered())

        var retained: CMImageSampleBuffer? = try fixture.makeSampleBuffer()
        var firstEvicted: CMImageSampleBuffer? = try fixture.makeSampleBuffer()
        var secondEvicted: CMImageSampleBuffer? = try fixture.makeSampleBuffer()
        let retainedReference = WeakReference(retained)
        let firstEvictedReference = WeakReference(firstEvicted)
        let secondEvictedReference = WeakReference(secondEvicted)
        #expect(delivery.offer(
            try #require(retained),
            output: output,
            from: connection
        ) == .accepted)
        #expect(delivery.offer(
            try #require(firstEvicted),
            output: output,
            from: connection
        ) == .accepted)
        #expect(delivery.offer(
            try #require(secondEvicted),
            output: output,
            from: connection
        ) == .accepted)
        retained = nil
        firstEvicted = nil
        secondEvicted = nil

        try output.setPendingSampleLimit(1)
        #expect(retainedReference.value !== nil)
        #expect(firstEvictedReference.value === nil)
        #expect(secondEvictedReference.value === nil)
        #expect(output.droppedSampleCount == 2)
        #expect(output.lastDropReason == .queueFull)

        delegate.release()
        #expect(await firstOffer.value == .accepted)
        #expect(retainedReference.value === nil)
    }

    @Test("Source-drop and sample callbacks are serialized")
    func sourceDropAndSampleCallbacksAreSerialized() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let delegate = SerializingVideoAndDropDelegate()
        output.setSampleBufferDelegate(delegate)
        let connection = AVCaptureConnection(
            inputPorts: input.ports,
            output: output
        )
        let delivery = output.deliveryEndpoint
        let sampleOperation = VideoOutputOfferOperation(
            delivery: delivery,
            sampleBuffer: fixture.sampleBuffer,
            output: output,
            connection: connection
        )
        let sampleOffer = Task {
            sampleOperation.offer()
        }
        #expect(delegate.waitUntilSampleEntered())

        let drop = CaptureStreamDropEvent(
            presentationTimeStamp: CMTime(value: 7, timescale: 30),
            cumulativeCount: 1,
            reason: .discontinuity
        )
        delivery.notifySourceDrop(
            drop,
            output: output,
            from: connection
        )
        #expect(!delegate.waitForDrop(milliseconds: 20))

        delegate.releaseSample()
        #expect(await sampleOffer.value == .accepted)
        #expect(delegate.waitForDrop(milliseconds: 2_000))
        #expect(delegate.maximumConcurrentCallbacks == 1)
        #expect(delegate.callbackOrder == ["sample", "drop"])
    }

    @Test("Source-drop metadata does not consume the pending sample limit")
    func sourceDropDoesNotConsumePendingSampleLimit() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let delegate = SerializingVideoAndDropDelegate()
        output.setSampleBufferDelegate(delegate)
        output.alwaysDiscardsLateVideoFrames = false
        try output.setPendingSampleLimit(1)
        let connection = AVCaptureConnection(
            inputPorts: input.ports,
            output: output
        )
        let delivery = output.deliveryEndpoint
        let sampleOperation = VideoOutputOfferOperation(
            delivery: delivery,
            sampleBuffer: fixture.sampleBuffer,
            output: output,
            connection: connection
        )
        let firstOffer = Task {
            sampleOperation.offer()
        }
        #expect(delegate.waitUntilSampleEntered())

        delivery.notifySourceDrop(
            CaptureStreamDropEvent(
                presentationTimeStamp: CMTime(value: 7, timescale: 30),
                cumulativeCount: 1,
                reason: .discontinuity
            ),
            output: output,
            from: connection
        )
        #expect(sampleOperation.offer() == .accepted)
        #expect(sampleOperation.offer() == .dropped)

        delegate.releaseSample()
        #expect(delegate.waitUntilSampleEntered())
        delegate.releaseSample()
        #expect(await firstOffer.value == .accepted)
        #expect(delegate.waitForDrop(milliseconds: 2_000))
        #expect(delegate.maximumConcurrentCallbacks == 1)
        #expect(delegate.callbackOrder == ["sample", "drop", "sample"])
        #expect(output.droppedSampleCount == 1)
        #expect(output.lastDropReason == .queueFull)
    }

    @Test("Reentrant sample offers respect the pending bound")
    func reentrantSampleOffersRespectPendingBound() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = false
        try output.setPendingSampleLimit(1)
        let connection = AVCaptureConnection(
            inputPorts: input.ports,
            output: output
        )
        let operation = VideoOutputOfferOperation(
            delivery: output.deliveryEndpoint,
            sampleBuffer: fixture.sampleBuffer,
            output: output,
            connection: connection
        )
        let delegate = ReentrantOfferDelegate(operation: operation)
        output.setSampleBufferDelegate(delegate)

        #expect(operation.offer() == .accepted)
        #expect(delegate.offerDispositions == [.accepted, .dropped])
        #expect(delegate.deliveryCount == 2)
        #expect(delegate.maximumConcurrentCallbacks == 1)
        #expect(output.droppedSampleCount == 1)
        #expect(output.lastDropReason == .queueFull)
    }

    @Test("Device resolves formats without opening a running stream")
    func deviceResolvesFormats() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()

        let formats = try await device.resolvedFormats()
        let format = try #require(formats.first)
        let dimensions = try #require(format.dimensions)
        let frameRateRange = try #require(
            format.videoSupportedFrameRateRanges.first
        )

        #expect(format.formatID == fixture.capabilities.preferredFormatID)
        #expect(dimensions.width == 2)
        #expect(dimensions.height == 1)
        #expect(frameRateRange.minFrameRate == 30)
        #expect(frameRateRange.maxFrameRate == 30)
        #expect(device.activeFormat == format)
        #expect(device.activeVideoFrameRate == nil)
        #expect(
            fixture.events.values() == [
                "open",
                "snapshot",
                "handle.shutdown"
            ]
        )
    }

    @Test("Selected device format and frame rate reach the driver")
    func selectedConfigurationReachesDriver() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let formats = try device.store(
            capabilities: fixture.capabilities
        )
        let format = try #require(formats.first)
        try device.select(format: format, frameRate: 30)
        #expect(
            throws: AVCaptureDeviceError.unsupportedFrameRate(
                formatID: format.formatID,
                frameRate: 60
            )
        ) {
            try device.select(format: format, frameRate: 60)
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(RecordingVideoDelegate())
        let session = AVCaptureSession()
        try session.beginConfiguration()
        try session.addInput(input)
        try session.addOutput(output)
        try session.commitConfiguration()
        try await session.startRunning()

        let configured = await fixture.handle.configuredConfiguration()
        #expect(configured?.formatID == format.formatID)
        #expect(configured?.frameRate == 30)
        #expect(device.activeFormat == format)
        #expect(device.activeVideoFrameRate == 30)

        try await session.stopRunning()
    }

    @Test("Invalid commit discards the draft and preserves the committed graph")
    func invalidCommitPreservesGraph() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let session = AVCaptureSession()

        try session.beginConfiguration()
        try session.addInput(input)
        try session.addOutput(output)
        try session.commitConfiguration()
        let committedConnection = try #require(session.connections.first)

        try session.beginConfiguration()
        try session.removeOutput(output)
        #expect(throws: AVCaptureSessionError.missingOutput) {
            try session.commitConfiguration()
        }

        #expect(session.inputs.first === input)
        #expect(session.outputs.first === output)
        #expect(session.connections.first === committedConnection)
        #expect(output.connections.first === committedConnection)
        #expect(throws: AVCaptureSessionError.configurationNotActive) {
            try session.commitConfiguration()
        }
    }

    @Test("A start failure rolls back opened resources")
    func startFailureRollsBackResources() async throws {
        let driverID = try CaptureDriverID("test.rollback")
        let failure = CaptureDriverError.backendFailure(
            driverID: driverID,
            deviceID: nil,
            operation: .configuration,
            code: 41
        )
        let fixture = try CaptureGraphFixture(
            driverID: driverID,
            configureFailure: failure
        )
        let session = try await fixture.configuredSession()

        await #expect(
            throws: AVCaptureSessionError.runtime(
                .driver(operation: .configuration, error: failure)
            )
        ) {
            try await session.startRunning()
        }

        #expect(!session.isRunning)
        #expect(
            fixture.events.values() == [
                "open",
                "snapshot",
                "configure",
                "handle.shutdown"
            ]
        )
        #expect(session.inputs.count == 1)
        #expect(session.outputs.count == 1)
        #expect(session.connections.count == 1)
    }

    @Test("Rollback failures preserve resources for stop retry")
    func rollbackFailureCanBeRetriedByStop() async throws {
        let driverID = try CaptureDriverID("test.rollback-retry")
        let startFailure = CaptureDriverError.backendFailure(
            driverID: driverID,
            deviceID: nil,
            operation: .start,
            code: 51
        )
        let shutdownFailure = CaptureDriverError.backendFailure(
            driverID: driverID,
            deviceID: nil,
            operation: .shutdown,
            code: 52
        )
        let fixture = try CaptureGraphFixture(
            driverID: driverID,
            startFailure: startFailure,
            streamShutdownFailures: [shutdownFailure]
        )
        let session = try await fixture.configuredSession()

        await #expect(
            throws: AVCaptureSessionError.startRollbackFailure(
                primary: .driver(
                    operation: .start,
                    error: startFailure
                ),
                cleanupFailures: [shutdownFailure]
            )
        ) {
            try await session.startRunning()
        }

        #expect(!session.isRunning)
        #expect(
            session.runtimeState == .cleanupRequired([shutdownFailure])
        )
        try await session.stopRunning()
        #expect(!session.isRunning)
        #expect(session.runtimeState == .idle)
        #expect(
            fixture.events.values() == [
                "open",
                "snapshot",
                "configure",
                "stream",
                "stream.start",
                "stream.shutdown",
                "handle.shutdown",
                "stream.shutdown"
            ]
        )
    }

    @Test("A failed start with successful cleanup returns runtime state to idle")
    func failedStartCleanupClearsRuntimeFailure() async throws {
        let driverID = try CaptureDriverID("test.start-event-cleanup")
        let terminalFailure = CaptureDriverError.backendFailure(
            driverID: driverID,
            deviceID: nil,
            operation: .streaming,
            code: 61
        )
        let startFailure = CaptureDriverError.backendFailure(
            driverID: driverID,
            deviceID: nil,
            operation: .start,
            code: 62
        )
        let fixture = try CaptureGraphFixture(
            driverID: driverID,
            startFailure: startFailure,
            startEvent: .failed(terminalFailure),
            eventCapabilities: [.terminalFailures]
        )
        let session = try await fixture.configuredSession()
        let recorder = SessionRuntimeEventRecorder()
        session.setRuntimeEventSink(recorder)

        await #expect(
            throws: AVCaptureSessionError.runtime(
                .driver(operation: .start, error: startFailure)
            )
        ) {
            try await session.startRunning()
        }
        #expect(session.runtimeState == .idle)
        #expect(!session.isRunning)
        #expect(
            recorder.events == [
                .failed(
                    .driver(
                        operation: .streaming,
                        error: terminalFailure
                    )
                )
            ]
        )
        #expect(fixture.streamEvents.offer(.resumed) == .stop)
        #expect(recorder.events.count == 1)
    }

    @Test("Session destruction releases graph ownership")
    func sessionDestructionReleasesOwnership() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()

        var firstSession: AVCaptureSession? = AVCaptureSession()
        try firstSession?.beginConfiguration()
        try firstSession?.addInput(input)
        try firstSession?.addOutput(output)
        try firstSession?.commitConfiguration()
        #expect(output.connections.count == 1)

        firstSession = nil

        #expect(output.connections.isEmpty)
        let secondSession = AVCaptureSession()
        try secondSession.beginConfiguration()
        #expect(secondSession.canAddInput(input))
        try secondSession.addInput(input)
        #expect(secondSession.canAddOutput(output))
        try secondSession.addOutput(output)
        try secondSession.commitConfiguration()
        #expect(secondSession.connections.count == 1)
    }

    @Test("Concurrent graph commits preserve exclusive ownership")
    func concurrentGraphCommitsPreserveExclusiveOwnership() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        var operations: [GraphCommitOperation] = []

        for _ in 0..<16 {
            let session = AVCaptureSession()
            try session.beginConfiguration()
            try session.addInput(input)
            try session.addOutput(output)
            operations.append(GraphCommitOperation(session: session))
        }

        let results = await withTaskGroup(
            of: AVCaptureSessionError?.self,
            returning: [AVCaptureSessionError?].self
        ) { group in
            for operation in operations {
                group.addTask {
                    operation.commit()
                }
            }
            var values: [AVCaptureSessionError?] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(results.filter { $0 == nil }.count == 1)
        #expect(
            results.compactMap { $0 }.allSatisfy {
                $0 == .inputOwnedByAnotherSession
            }
        )
    }

    @Test("Concurrent starts have one ordered winner")
    func concurrentStartsHaveOneOrderedWinner() async throws {
        let fixture = try CaptureGraphFixture()
        let session = try await fixture.configuredSession()
        let operation = SessionStartOperation(session: session)

        let results = await withTaskGroup(
            of: AVCaptureSessionError?.self,
            returning: [AVCaptureSessionError?].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    await operation.start()
                }
            }
            var values: [AVCaptureSessionError?] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(results.filter { $0 == nil }.count == 1)
        #expect(
            results.compactMap { $0 }.allSatisfy {
                $0 == .sessionBusy
            }
        )
        try await session.stopRunning()
    }

    @Test("Delegate reentry does not execute under the delivery lock")
    func delegateReentryDoesNotExecuteUnderDeliveryLock() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let delegate = ReentrantVideoDelegate()
        output.setSampleBufferDelegate(delegate)
        let connection = AVCaptureConnection(
            inputPorts: input.ports,
            output: output
        )

        #expect(
            output.deliveryEndpoint.offer(
                fixture.sampleBuffer,
                output: output,
                from: connection
            ) == .accepted
        )
        #expect(delegate.didReenterSuccessfully())
        #expect(output.sampleBufferDelegate == nil)
    }

    @Test("Stable ports do not retain their input")
    func stablePortsDoNotRetainInput() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        weak var releasedInput: AVCaptureDeviceInput?
        var retainedPort: AVCaptureInput.Port?

        do {
            let input = try AVCaptureDeviceInput(device: device)
            releasedInput = input
            retainedPort = input.ports.first
            #expect(input.ports.first === retainedPort)
        }

        #expect(releasedInput === nil)
        #expect(retainedPort !== nil)
    }

    @Test("Runtime events update typed session state outside session locks")
    func runtimeEventsUpdateSessionState() async throws {
        let fixture = try CaptureGraphFixture(
            eventCapabilities: [
                .interruptions,
                .sourceDrops,
                .systemPressure,
                .terminalFailures
            ]
        )
        let session = try await fixture.configuredSession()
        let recorder = SessionRuntimeEventRecorder()
        session.setRuntimeEventSink(recorder)

        try await session.startRunning()
        #expect(session.runtimeState == .running)

        #expect(
            fixture.streamEvents.offer(
                .interrupted(.deviceInUseByAnotherClient)
            ) == .continueStreaming
        )
        #expect(
            session.runtimeState ==
                .interrupted(.deviceInUseByAnotherClient)
        )
        #expect(session.isRunning)

        let pressure = CaptureSystemPressure(
            level: .serious,
            factors: [.systemTemperature]
        )
        #expect(
            fixture.streamEvents.offer(.pressure(pressure)) ==
                .continueStreaming
        )
        #expect(session.systemPressure == pressure)

        let drop = CaptureStreamDropEvent(
            presentationTimeStamp: .zero,
            cumulativeCount: 1,
            reason: .outOfBuffers
        )
        #expect(
            fixture.streamEvents.offer(.dropped(drop)) ==
                .continueStreaming
        )
        #expect(session.lastSourceDrop == drop)

        #expect(
            fixture.streamEvents.offer(.resumed) == .continueStreaming
        )
        #expect(session.runtimeState == .running)

        let failure = CaptureDriverError.deviceDisconnected(
            fixture.descriptor.deviceID
        )
        #expect(
            fixture.streamEvents.offer(.failed(failure)) == .stop
        )
        #expect(
            session.runtimeState == .failed(
                .driver(operation: .streaming, error: failure)
            )
        )
        #expect(!session.isRunning)
        #expect(recorder.events.count == 5)
        #expect(fixture.streamEvents.offer(.resumed) == .stop)
        #expect(
            fixture.streamEvents.offer(
                .interrupted(.deviceUnavailableInBackground)
            ) == .stop
        )
        #expect(fixture.streamEvents.offer(.pressure(.init(level: .fair))) == .stop)
        #expect(fixture.streamEvents.offer(.dropped(drop)) == .stop)
        #expect(
            session.runtimeState == .failed(
                .driver(operation: .streaming, error: failure)
            )
        )
        #expect(recorder.events.count == 5)

        try await session.stopRunning()
        #expect(session.runtimeState == .idle)
    }

    @Test("A runtime sink stop request exposes cleanup-required state")
    func runtimeSinkStopRequiresCleanup() async throws {
        let fixture = try CaptureGraphFixture(
            eventCapabilities: [.systemPressure]
        )
        let session = try await fixture.configuredSession()
        let recorder = SessionRuntimeEventRecorder(disposition: .stop)
        session.setRuntimeEventSink(recorder)
        try await session.startRunning()

        let pressure = CaptureSystemPressure(level: .serious)
        #expect(fixture.streamEvents.offer(.pressure(pressure)) == .stop)
        #expect(session.runtimeState == .cleanupRequired([]))
        #expect(!session.isRunning)
        #expect(fixture.streamEvents.offer(.pressure(pressure)) == .stop)
        let lateFailure = CaptureDriverError.deviceDisconnected(
            fixture.descriptor.deviceID
        )
        #expect(
            fixture.streamEvents.offer(.failed(lateFailure)) == .stop
        )
        #expect(session.runtimeState == .cleanupRequired([]))
        #expect(recorder.events == [.pressure(pressure)])

        try await session.stopRunning()
        #expect(session.runtimeState == .idle)
    }

    @Test("Undeclared stream events become visible typed failures")
    func undeclaredStreamEventsBecomeTypedFailures() async throws {
        let fixture = try CaptureGraphFixture(
            eventCapabilities: [.interruptions]
        )
        let session = try await fixture.configuredSession()
        let recorder = SessionRuntimeEventRecorder()
        session.setRuntimeEventSink(recorder)
        try await session.startRunning()

        let pressure = CaptureSystemPressure(level: .serious)
        let event = CaptureStreamEvent.pressure(pressure)
        let failure =
            AVCaptureSessionRuntimeFailure.undeclaredStreamEvent(event)
        #expect(fixture.streamEvents.offer(event) == .stop)
        #expect(session.runtimeState == .failed(failure))
        #expect(!session.isRunning)
        #expect(recorder.events == [.failed(failure)])

        try await session.stopRunning()
        #expect(session.runtimeState == .idle)
    }

    @Test("Connection configuration reaches the stream request")
    func connectionConfigurationReachesStreamRequest() async throws {
        let capabilities = try CaptureVideoConnectionCapabilities(
            supportedRotationAngles: [.clockwise90],
            supportedStabilizationModes: [.standard],
            supportedMirroringModes: [.automatic]
        )
        let fixture = try CaptureGraphFixture(
            videoConnectionCapabilities: capabilities
        )
        let session = try await fixture.configuredSession()
        let requested = CaptureVideoConnectionConfiguration(
            rotationAngle: .clockwise90,
            stabilizationMode: .standard,
            mirroringMode: .automatic
        )
        let connection = session.connections[0]
        #expect(connection.automaticallyAdjustsVideoMirroring)
        #expect(connection.preferredVideoStabilizationMode == .off)
        #expect(connection.isVideoRotationAngleSupported(90))
        #expect(!connection.isVideoRotationAngleSupported(45))
        #expect(throws: AVCaptureConnectionError.invalidVideoRotationAngle(45)) {
            try connection.setVideoRotationAngle(45)
        }
        try connection.setVideoRotationAngle(90)
        #expect(connection.videoRotationAngle == 90)
        connection.preferredVideoStabilizationMode = .standard
        connection.automaticallyAdjustsVideoMirroring = false
        #expect(!connection.automaticallyAdjustsVideoMirroring)
        connection.isVideoMirrored = true
        #expect(connection.isVideoMirrored)
        connection.automaticallyAdjustsVideoMirroring = true
        #expect(connection.automaticallyAdjustsVideoMirroring)
        #expect(!connection.isVideoMirrored)
        #expect(connection.videoConnectionConfiguration == requested)

        try await session.startRunning()
        #expect(!connection.isVideoRotationAngleSupported(180))
        #expect(
            throws:
                AVCaptureConnectionError.unsupportedVideoRotationAngle(180)
        ) {
            try connection.setVideoRotationAngle(180)
        }
        #expect(connection.videoRotationAngle == 90)
        #expect(
            await fixture.handle.requestedStream()?
                .videoConnectionConfiguration == requested
        )
        try await session.stopRunning()
    }

    @Test("Source drops fan out in graph order without a sample buffer")
    func sourceDropFanoutPreservesConnectionsAndAllowsReentry() async throws {
        let fixture = try CaptureGraphFixture(
            eventCapabilities: [.sourceDrops]
        )
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let firstOutput = AVCaptureVideoDataOutput()
        let secondOutput = AVCaptureVideoDataOutput()
        let firstDelegate = ReentrantDropDelegate()
        let secondDelegate = RecordingDropDelegate()
        firstOutput.setSampleBufferDelegate(firstDelegate)
        secondOutput.setSampleBufferDelegate(secondDelegate)
        let session = AVCaptureSession()
        try session.beginConfiguration()
        try session.addInput(input)
        try session.addOutput(firstOutput)
        try session.addOutput(secondOutput)
        try session.commitConfiguration()
        try await session.startRunning()

        let drop = CaptureStreamDropEvent(
            presentationTimeStamp: CMTime(value: 3, timescale: 30),
            cumulativeCount: 4,
            reason: .discontinuity
        )
        #expect(
            fixture.streamEvents.offer(.dropped(drop)) ==
                .continueStreaming
        )
        #expect(firstDelegate.didReenterSuccessfully())
        #expect(firstOutput.sampleBufferDelegate == nil)
        #expect(secondDelegate.event == drop)
        #expect(secondDelegate.connection === session.connections[1])

        try await session.stopRunning()
    }

    @Test("Device controls stage atomically and preserve other settings")
    func deviceControlsStageAtomically() async throws {
        let controlCapabilities = try CaptureDeviceControlCapabilities(
            focus: CaptureFocusCapabilities(
                supportedModes: [.locked, .continuousAutoFocus],
                lensPositionRange: CaptureScalarRange(
                    minimum: 0,
                    maximum: 1
                )
            ),
            exposure: CaptureExposureCapabilities(
                supportedModes: [.continuousAutoExposure, .custom],
                durationRange: CaptureExposureDurationRange(
                    minimum: CMTime(value: 1, timescale: 1_000),
                    maximum: CMTime(value: 1, timescale: 10)
                ),
                isoRange: CaptureScalarRange(
                    minimum: 50,
                    maximum: 800
                )
            ),
            whiteBalance: CaptureWhiteBalanceCapabilities(
                supportedModes: [.locked, .continuousAutoWhiteBalance],
                gainRange: CaptureScalarRange(
                    minimum: 1,
                    maximum: 4
                )
            ),
            zoom: CaptureZoomCapabilities(
                factorRange: CaptureScalarRange(
                    minimum: 1,
                    maximum: 4
                )
            )
        )
        let fixture = try CaptureGraphFixture(
            controlCapabilities: controlCapabilities
        )
        let device = try await fixture.discoveredDevice()
        _ = try await device.resolvedFormats()
        let focusOperation = DeviceControlOperation(operation: {
            () throws(AVCaptureDeviceError) in
            try device.setFocus(mode: .locked, lensPosition: 0.25)
        })
        let exposureOperation = DeviceControlOperation(operation: {
            () throws(AVCaptureDeviceError) in
            try device.setExposure(
                mode: .custom,
                duration: CMTime(value: 1, timescale: 100),
                iso: 200
            )
        })

        let failures = await withTaskGroup(
            of: AVCaptureDeviceError?.self,
            returning: [AVCaptureDeviceError?].self
        ) { group in
            group.addTask { focusOperation.run() }
            group.addTask { exposureOperation.run() }
            var failures: [AVCaptureDeviceError?] = []
            for await failure in group {
                failures.append(failure)
            }
            return failures
        }
        #expect(failures.allSatisfy { $0 == nil })

        let gains = try CaptureWhiteBalanceGains(
            red: 2,
            green: 1,
            blue: 2
        )
        try device.setWhiteBalance(mode: .locked, gains: gains)
        try device.setVideoZoomFactor(2)
        #expect(device.activeControls.focus?.lensPosition == 0.25)
        #expect(device.activeControls.exposure?.iso == 200)
        #expect(device.activeControls.whiteBalance?.gains == gains)
        #expect(device.activeControls.zoom?.factor == 2)

        let configuration = try device.configuration(
            for: fixture.capabilities
        )
        #expect(configuration.controls == device.activeControls)
    }

    @Test("Device controls reject foreign, stale, and unsupported selections")
    func deviceControlsRejectInvalidSelections() async throws {
        let firstFixture = try CaptureGraphFixture(
            driverID: CaptureDriverID("test.controls.first")
        )
        let secondFixture = try CaptureGraphFixture(
            driverID: CaptureDriverID("test.controls.second")
        )
        let firstDevice = try await firstFixture.discoveredDevice()
        let secondDevice = try await secondFixture.discoveredDevice()
        _ = try await firstDevice.resolvedFormats()
        _ = try await secondDevice.resolvedFormats()
        let firstControls = try firstDevice.controlConfiguration(.none)

        #expect(
            throws: AVCaptureDeviceError.foreignControls(
                expectedDeviceID: secondFixture.descriptor.deviceID,
                actualDeviceID: firstFixture.descriptor.deviceID
            )
        ) {
            try secondDevice.select(controls: firstControls)
        }

        let stale = AVCaptureDevice.ControlConfiguration(
            deviceID: firstFixture.descriptor.deviceID,
            capabilityRevision:
                firstFixture.capabilities.revision &+ 1,
            controls: .none
        )
        #expect(
            throws: AVCaptureDeviceError.staleControls(
                deviceID: firstFixture.descriptor.deviceID,
                expectedRevision: firstFixture.capabilities.revision,
                actualRevision: stale.capabilityRevision
            )
        ) {
            try firstDevice.select(controls: stale)
        }

        #expect(
            throws: AVCaptureDeviceError.unsupportedControls(
                .unsupportedControl(
                    deviceID: firstFixture.descriptor.deviceID,
                    controlID: .zoom
                )
            )
        ) {
            try firstDevice.setVideoZoomFactor(2)
        }
    }
}

private final class GraphCommitOperation: Sendable {
    private let session: AVCaptureSession

    init(session: AVCaptureSession) {
        self.session = session
    }

    func commit() -> AVCaptureSessionError? {
        do {
            try session.commitConfiguration()
            return nil
        } catch {
            return error
        }
    }
}

private final class SessionStartOperation: Sendable {
    private let session: AVCaptureSession

    init(session: AVCaptureSession) {
        self.session = session
    }

    func start() async -> AVCaptureSessionError? {
        do {
            try await session.startRunning()
            return nil
        } catch {
            return error
        }
    }
}

private final class DeviceControlOperation: Sendable {
    private let operation:
        @Sendable () throws(AVCaptureDeviceError) -> Void

    init(
        operation:
            @escaping @Sendable () throws(AVCaptureDeviceError) -> Void
    ) {
        self.operation = operation
    }

    func run() -> AVCaptureDeviceError? {
        do {
            try operation()
            return nil
        } catch {
            return error
        }
    }
}

private final class VideoOutputOfferOperation: Sendable {
    private let delivery: VideoOutputDelivery
    private let sampleBuffer: any CMSampleBuffer
    private let output: CaptureOutputReference
    private let connection: AVCaptureConnection

    init(
        delivery: VideoOutputDelivery,
        sampleBuffer: any CMSampleBuffer,
        output: AVCaptureVideoDataOutput,
        connection: AVCaptureConnection
    ) {
        self.delivery = delivery
        self.sampleBuffer = sampleBuffer
        self.output = CaptureOutputReference(value: output)
        self.connection = connection
    }

    func offer() -> CaptureSampleDisposition {
        guard let videoOutput = output.value as? AVCaptureVideoDataOutput else {
            preconditionFailure(
                "VideoOutputOfferOperation must retain an AVCaptureVideoDataOutput"
            )
        }
        return delivery.offer(
            sampleBuffer,
            output: videoOutput,
            from: connection
        )
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private final class SessionRuntimeEventRecorder:
    AVCaptureSessionRuntimeEventSink,
    Sendable
{
    private let disposition: AVCaptureSessionRuntimeEventDisposition
    private let storage = Mutex<[AVCaptureSessionRuntimeEvent]>([])

    init(
        disposition: AVCaptureSessionRuntimeEventDisposition =
            .continueMonitoring
    ) {
        self.disposition = disposition
    }

    var events: [AVCaptureSessionRuntimeEvent] {
        storage.withLock { events in events }
    }

    func offer(
        _ event: AVCaptureSessionRuntimeEvent
    ) -> AVCaptureSessionRuntimeEventDisposition {
        storage.withLock { events in events.append(event) }
        return disposition
    }
}

private final class CaptureStreamEventEmitter: Sendable {
    private struct State: Sendable {
        var sink: (any CaptureStreamEventSink)?
    }

    let capabilities: CaptureStreamEventCapabilities
    private let state = Mutex(State())

    init(capabilities: CaptureStreamEventCapabilities) {
        self.capabilities = capabilities
    }

    func setSink(_ sink: (any CaptureStreamEventSink)?) {
        state.withLock { state in state.sink = sink }
    }

    func clear() {
        setSink(nil)
    }

    func offer(
        _ event: CaptureStreamEvent
    ) -> CaptureStreamEventDisposition {
        let sink = state.withLock { state in state.sink }
        return sink?.offer(event) ?? .stop
    }
}

private struct CaptureGraphFixture: Sendable {
    let driverID: CaptureDriverID
    let descriptor: CaptureDeviceDescriptor
    let capabilities: CaptureDeviceCapabilities
    let sampleBuffer: any CMSampleBuffer
    let provider: CaptureGraphProvider
    let events: CaptureEventLog
    let handle: CaptureGraphHandle
    let streamEvents: CaptureStreamEventEmitter

    init(
        driverID: CaptureDriverID? = nil,
        configureFailure: CaptureDriverError? = nil,
        startFailure: CaptureDriverError? = nil,
        streamShutdownFailures: [CaptureDriverError] = [],
        startEvent: CaptureStreamEvent? = nil,
        eventCapabilities: CaptureStreamEventCapabilities = [],
        controlCapabilities: CaptureDeviceControlCapabilities = .none,
        videoConnectionCapabilities:
            CaptureVideoConnectionCapabilities? = nil
    ) throws {
        let resolvedDriverID: CaptureDriverID
        if let driverID {
            resolvedDriverID = driverID
        } else {
            resolvedDriverID = try CaptureDriverID("test.capture")
        }
        let deviceID = try CaptureDeviceID(
            driverID: resolvedDriverID,
            localID: "camera"
        )
        let deviceTypeID = try CaptureDeviceTypeID(
            AVCaptureDevice.DeviceType.external.rawValue
        )
        let descriptor = try CaptureDeviceDescriptor(
            deviceID: deviceID,
            deviceTypeID: deviceTypeID,
            localizedName: "Capture Camera",
            manufacturer: "Fixture",
            modelID: "capture-camera",
            position: .external,
            mediaTypes: [.video],
            capabilityRevision: 1
        )
        let format = CaptureDeviceFormatDescriptor(
            formatID: try CaptureDeviceFormatID("preferred"),
            mediaType: .video,
            mediaSubtype: CaptureMediaSubtype(rawValue: 0),
            dimensions: try CaptureDimensions(width: 2, height: 1),
            frameRateRanges: [
                try CaptureFrameRateRange(minimum: 30, maximum: 30)
            ]
        )
        let streamID = try CaptureStreamID("main")
        let streamDescriptor = try CaptureStreamDescriptor(
            streamID: streamID,
            mediaType: .video,
            formatIDs: [format.formatID],
            eventCapabilities: eventCapabilities,
            videoConnectionCapabilities: videoConnectionCapabilities
        )
        let capabilities = try CaptureDeviceCapabilities(
            deviceID: deviceID,
            revision: descriptor.capabilityRevision,
            formats: [format],
            preferredFormatID: format.formatID,
            controls: controlCapabilities,
            streams: [streamDescriptor],
            supportedStreamCombinations: [
                try CaptureStreamCombination(streamIDs: [streamID])
            ]
        )
        let snapshot = try CaptureDeviceSnapshot(
            descriptor: descriptor,
            capabilities: capabilities
        )
        let imageDimensions = try CVPixelDimensions(width: 2, height: 1)
        let imageBuffer = try CVPackedPixelBuffer(
            dimensions: imageDimensions,
            pixelFormat: .bgra32,
            bytesPerPixel: 4,
            bytesPerRow: 8
        )
        let formatDescription = CMImmutableVideoFormatDescription(
            dimensions: imageDimensions,
            pixelFormat: .bgra32
        )
        let sampleBuffer = try CMImageSampleBuffer(
            imageBuffer: imageBuffer,
            formatDescription: formatDescription,
            timing: [
                CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: 30),
                    presentationTimeStamp: .zero,
                    decodeTimeStamp: .invalid
                )
            ]
        )
        let events = CaptureEventLog()
        let streamEvents = CaptureStreamEventEmitter(
            capabilities: eventCapabilities
        )
        let handle = CaptureGraphHandle(
            snapshot: snapshot,
            sampleBuffer: sampleBuffer,
            events: events,
            streamEvents: streamEvents,
            configureFailure: configureFailure,
            startFailure: startFailure,
            startEvent: startEvent,
            streamShutdownFailures: streamShutdownFailures
        )

        self.driverID = resolvedDriverID
        self.descriptor = descriptor
        self.capabilities = capabilities
        self.sampleBuffer = sampleBuffer
        self.events = events
        self.handle = handle
        self.streamEvents = streamEvents
        self.provider = CaptureGraphProvider(
            driverID: resolvedDriverID,
            descriptor: descriptor,
            handle: handle,
            events: events
        )
    }

    func discoveredDevice() async throws -> AVCaptureDevice {
        let registry = AVCaptureDeviceRegistry()
        try registry.register(provider)
        let discovery = try await registry.discoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        return try #require(discovery.devices.first)
    }

    func configuredSession() async throws -> AVCaptureSession {
        let device = try await discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let session = AVCaptureSession()
        try session.beginConfiguration()
        try session.addInput(input)
        try session.addOutput(output)
        try session.commitConfiguration()
        return session
    }

    func makeSampleBuffer() throws -> CMImageSampleBuffer {
        let dimensions = try CVPixelDimensions(width: 2, height: 1)
        let imageBuffer = try CVPackedPixelBuffer(
            dimensions: dimensions,
            pixelFormat: .bgra32,
            bytesPerPixel: 4,
            bytesPerRow: 8
        )
        return try CMImageSampleBuffer(
            imageBuffer: imageBuffer,
            formatDescription: CMImmutableVideoFormatDescription(
                dimensions: dimensions,
                pixelFormat: .bgra32
            ),
            timing: [
                CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: 30),
                    presentationTimeStamp: .zero,
                    decodeTimeStamp: .invalid
                )
            ]
        )
    }
}

private struct CaptureGraphProvider: CaptureDeviceProvider {
    let driverID: CaptureDriverID
    let descriptor: CaptureDeviceDescriptor
    let handle: CaptureGraphHandle
    let events: CaptureEventLog

    func authorizationStatus(
        for mediaType: CaptureMediaTypeID
    ) async -> CaptureAuthorizationStatus {
        mediaType == .video ? .authorized : .denied
    }

    func requestAccess(
        for mediaType: CaptureMediaTypeID
    ) async throws(CaptureDriverError) -> CaptureAuthorizationStatus {
        mediaType == .video ? .authorized : .denied
    }

    func devices(
        matching request: CaptureDiscoveryRequest
    ) async throws(CaptureDriverError) -> [CaptureDeviceDescriptor] {
        [descriptor]
    }

    func deviceHandle(
        for deviceID: CaptureDeviceID
    ) async throws(CaptureDriverError) -> any CaptureDeviceHandle {
        guard deviceID == descriptor.deviceID else {
            throw .deviceNotFound(deviceID)
        }
        events.append("open")
        return handle
    }
}

private actor CaptureGraphHandle: CaptureDeviceHandle {
    private let snapshotValue: CaptureDeviceSnapshot
    private let sampleBuffer: any CMSampleBuffer
    private let events: CaptureEventLog
    private let streamEvents: CaptureStreamEventEmitter
    private let configureFailure: CaptureDriverError?
    private let startFailure: CaptureDriverError?
    private let startEvent: CaptureStreamEvent?
    private let streamShutdownFailures: [CaptureDriverError]
    private var configured: CaptureDeviceConfiguration?
    private var streamRequest: CaptureStreamRequest?
    private var isShutdown = false

    init(
        snapshot: CaptureDeviceSnapshot,
        sampleBuffer: any CMSampleBuffer,
        events: CaptureEventLog,
        streamEvents: CaptureStreamEventEmitter,
        configureFailure: CaptureDriverError?,
        startFailure: CaptureDriverError?,
        startEvent: CaptureStreamEvent?,
        streamShutdownFailures: [CaptureDriverError]
    ) {
        snapshotValue = snapshot
        self.sampleBuffer = sampleBuffer
        self.events = events
        self.streamEvents = streamEvents
        self.configureFailure = configureFailure
        self.startFailure = startFailure
        self.startEvent = startEvent
        self.streamShutdownFailures = streamShutdownFailures
    }

    func snapshot() throws(CaptureDriverError) -> CaptureDeviceSnapshot {
        events.append("snapshot")
        guard !isShutdown else {
            throw .deviceDisconnected(snapshotValue.descriptor.deviceID)
        }
        return snapshotValue
    }

    func configure(
        _ configuration: CaptureDeviceConfiguration
    ) throws(CaptureDriverError) -> CaptureDeviceSnapshot {
        events.append("configure")
        if let configureFailure {
            throw configureFailure
        }
        guard configuration.deviceID == snapshotValue.descriptor.deviceID else {
            throw .deviceNotFound(configuration.deviceID)
        }
        configured = configuration
        return snapshotValue
    }

    func stream(
        for request: CaptureStreamRequest,
        sink: any CaptureSampleSink
    ) throws(CaptureDriverError) -> any CaptureStream {
        events.append("stream")
        guard configured == request.configuration else {
            throw .unsupportedConfiguration(request.configuration.deviceID)
        }
        _ = try snapshotValue.capabilities.validatedStreamRequest(request)
        streamRequest = request
        return CaptureGraphStream(
            deviceID: snapshotValue.descriptor.deviceID,
            sampleBuffer: sampleBuffer,
            sink: sink,
            events: events,
            streamEvents: streamEvents,
            startFailure: startFailure,
            startEvent: startEvent,
            shutdownFailures: streamShutdownFailures
        )
    }

    func shutdown() {
        events.append("handle.shutdown")
        isShutdown = true
    }

    func configuredConfiguration() -> CaptureDeviceConfiguration? {
        configured
    }

    func requestedStream() -> CaptureStreamRequest? {
        streamRequest
    }
}

private actor CaptureGraphStream: CaptureStream {
    nonisolated let deviceID: CaptureDeviceID
    nonisolated var eventCapabilities: CaptureStreamEventCapabilities {
        streamEvents.capabilities
    }

    private let sampleBuffer: any CMSampleBuffer
    private let sink: any CaptureSampleSink
    private let events: CaptureEventLog
    nonisolated private let streamEvents: CaptureStreamEventEmitter
    private let startFailure: CaptureDriverError?
    private let startEvent: CaptureStreamEvent?
    private var shutdownFailures: [CaptureDriverError]
    private var isShutdown = false

    init(
        deviceID: CaptureDeviceID,
        sampleBuffer: any CMSampleBuffer,
        sink: any CaptureSampleSink,
        events: CaptureEventLog,
        streamEvents: CaptureStreamEventEmitter,
        startFailure: CaptureDriverError?,
        startEvent: CaptureStreamEvent?,
        shutdownFailures: [CaptureDriverError]
    ) {
        self.deviceID = deviceID
        self.sampleBuffer = sampleBuffer
        self.sink = sink
        self.events = events
        self.streamEvents = streamEvents
        self.startFailure = startFailure
        self.startEvent = startEvent
        self.shutdownFailures = shutdownFailures
    }

    func start() throws(CaptureDriverError) {
        events.append("stream.start")
        if let startEvent {
            _ = streamEvents.offer(startEvent)
        }
        if let startFailure {
            throw startFailure
        }
        guard !isShutdown else {
            throw .deviceDisconnected(deviceID)
        }
        _ = sink.offer(sampleBuffer)
    }

    func shutdown() throws(CaptureDriverError) {
        events.append("stream.shutdown")
        if !shutdownFailures.isEmpty {
            throw shutdownFailures.removeFirst()
        }
        isShutdown = true
        streamEvents.clear()
    }

    nonisolated func setEventSink(
        _ sink: (any CaptureStreamEventSink)?
    ) throws(CaptureDriverError) {
        streamEvents.setSink(sink)
    }
}

private final class RecordingVideoDelegate:
    AVCaptureVideoDataOutputSampleBufferDelegate,
    Sendable
{
    private struct Delivery: Sendable {
        var sampleBuffer: (any CMSampleBuffer)?
        var connection: AVCaptureConnection?
    }

    private struct State {
        var delivery = Delivery()
        var waiters: [CheckedContinuation<Delivery, Never>] = []
    }

    private let state = Mutex(State())

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let waiters = state.withLock { state in
            state.delivery.sampleBuffer = sampleBuffer
            state.delivery.connection = connection
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: true)
            return waiters
        }
        let delivery = Delivery(
            sampleBuffer: sampleBuffer,
            connection: connection
        )
        for waiter in waiters {
            waiter.resume(returning: delivery)
        }
    }

    func delivery() -> (
        sampleBuffer: (any CMSampleBuffer)?,
        connection: AVCaptureConnection?
    ) {
        state.withLock { state in
            (
                state.delivery.sampleBuffer,
                state.delivery.connection
            )
        }
    }

    func nextDelivery() async -> (
        sampleBuffer: (any CMSampleBuffer)?,
        connection: AVCaptureConnection?
    ) {
        let delivery = await withCheckedContinuation { continuation in
            var current: Delivery?
            state.withLock { state in
                if state.delivery.sampleBuffer == nil {
                    state.waiters.append(continuation)
                } else {
                    current = state.delivery
                }
            }
            if let current {
                continuation.resume(returning: current)
            }
        }
        return (delivery.sampleBuffer, delivery.connection)
    }
}

private final class BlockingVideoDelegate:
    AVCaptureVideoDataOutputSampleBufferDelegate,
    Sendable
{
    private let entered = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let count = Mutex(0)

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        count.withLock { count in count += 1 }
        entered.signal()
        releaseGate.wait()
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }

    func release() {
        releaseGate.signal()
        releaseGate.signal()
    }

    func releaseOne() {
        releaseGate.signal()
    }

    func deliveryCount() -> Int {
        count.withLock { count in count }
    }
}

private final class SerializingVideoAndDropDelegate:
    AVCaptureVideoDataOutputSampleBufferDelegate,
    Sendable
{
    private struct State: Sendable {
        var activeCallbacks = 0
        var maximumConcurrentCallbacks = 0
        var callbackOrder: [String] = []
    }

    private let sampleEntered = DispatchSemaphore(value: 0)
    private let sampleRelease = DispatchSemaphore(value: 0)
    private let dropDelivered = DispatchSemaphore(value: 0)
    private let state = Mutex(State())

    var maximumConcurrentCallbacks: Int {
        state.withLock { state in state.maximumConcurrentCallbacks }
    }

    var callbackOrder: [String] {
        state.withLock { state in state.callbackOrder }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        begin("sample")
        sampleEntered.signal()
        _ = sampleRelease.wait(timeout: .now() + 2)
        end()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop event: CaptureStreamDropEvent,
        from connection: AVCaptureConnection
    ) {
        begin("drop")
        end()
        dropDelivered.signal()
    }

    func waitUntilSampleEntered() -> Bool {
        sampleEntered.wait(timeout: .now() + 2) == .success
    }

    func releaseSample() {
        sampleRelease.signal()
    }

    func waitForDrop(milliseconds: Int) -> Bool {
        dropDelivered.wait(
            timeout: .now() + .milliseconds(milliseconds)
        ) == .success
    }

    private func begin(_ name: String) {
        state.withLock { state in
            state.activeCallbacks += 1
            state.maximumConcurrentCallbacks = max(
                state.maximumConcurrentCallbacks,
                state.activeCallbacks
            )
            state.callbackOrder.append(name)
        }
    }

    private func end() {
        state.withLock { state in
            state.activeCallbacks -= 1
        }
    }
}

private final class ReentrantVideoDelegate:
    AVCaptureVideoDataOutputSampleBufferDelegate,
    Sendable
{
    private let succeeded = Mutex(false)

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let videoOutput = output as? AVCaptureVideoDataOutput else {
            return
        }
        do {
            try videoOutput.setPendingSampleLimit(2)
            videoOutput.setSampleBufferDelegate(nil)
            succeeded.withLock { succeeded in
                succeeded = true
            }
        } catch {
            succeeded.withLock { succeeded in
                succeeded = false
            }
        }
    }

    func didReenterSuccessfully() -> Bool {
        succeeded.withLock { succeeded in succeeded }
    }
}

private final class ReentrantOfferDelegate:
    AVCaptureVideoDataOutputSampleBufferDelegate,
    Sendable
{
    private struct State: Sendable {
        var activeCallbacks = 0
        var maximumConcurrentCallbacks = 0
        var deliveryCount = 0
        var offerDispositions: [CaptureSampleDisposition] = []
    }

    private let operation: VideoOutputOfferOperation
    private let state = Mutex(State())

    init(operation: VideoOutputOfferOperation) {
        self.operation = operation
    }

    var offerDispositions: [CaptureSampleDisposition] {
        state.withLock { state in state.offerDispositions }
    }

    var deliveryCount: Int {
        state.withLock { state in state.deliveryCount }
    }

    var maximumConcurrentCallbacks: Int {
        state.withLock { state in state.maximumConcurrentCallbacks }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let shouldReenter = state.withLock { state in
            state.activeCallbacks += 1
            state.maximumConcurrentCallbacks = max(
                state.maximumConcurrentCallbacks,
                state.activeCallbacks
            )
            state.deliveryCount += 1
            return state.deliveryCount == 1
        }
        if shouldReenter {
            let first = operation.offer()
            let second = operation.offer()
            state.withLock { state in
                state.offerDispositions = [first, second]
            }
        }
        state.withLock { state in
            state.activeCallbacks -= 1
        }
    }
}

private final class ReentrantDropDelegate:
    AVCaptureVideoDataOutputSampleBufferDelegate,
    Sendable
{
    private let succeeded = Mutex(false)

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {}

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop event: CaptureStreamDropEvent,
        from connection: AVCaptureConnection
    ) {
        guard let output = output as? AVCaptureVideoDataOutput else {
            return
        }
        output.setSampleBufferDelegate(nil)
        succeeded.withLock { value in value = true }
    }

    func didReenterSuccessfully() -> Bool {
        succeeded.withLock { value in value }
    }
}

private final class RecordingDropDelegate:
    AVCaptureVideoDataOutputSampleBufferDelegate,
    Sendable
{
    private struct State: Sendable {
        var event: CaptureStreamDropEvent?
        var connection: AVCaptureConnection?
    }

    private let state = Mutex(State())

    var event: CaptureStreamDropEvent? {
        state.withLock { state in state.event }
    }

    var connection: AVCaptureConnection? {
        state.withLock { state in state.connection }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {}

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop event: CaptureStreamDropEvent,
        from connection: AVCaptureConnection
    ) {
        state.withLock { state in
            state.event = event
            state.connection = connection
        }
    }
}

private final class CaptureEventLog: Sendable {
    private let events = Mutex<[String]>([])

    func append(_ event: String) {
        events.withLock { events in
            events.append(event)
        }
    }

    func values() -> [String] {
        events.withLock { events in events }
    }
}
