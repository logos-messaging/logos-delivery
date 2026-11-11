//
//  LogosDeliveryNode.swift
//  LogosDeliveryExample
//
//  Swift wrapper around liblogosdelivery C API for edge mode (lightpush + filter)
//  Uses Swift actors for thread safety and UI responsiveness
//

import Foundation

// MARK: - Data Types

/// Message received from Logos Delivery network
struct LogosDeliveryMessage: Identifiable, Equatable, Sendable {
    let id: String  // messageHash from Logos Delivery - unique identifier for deduplication
    let payload: String
    let contentTopic: String
    let timestamp: Date
}

/// Logos Delivery node status
enum LogosDeliveryNodeStatus: String, Sendable {
    case stopped = "Stopped"
    case starting = "Starting..."
    case running = "Running"
    case error = "Error"
}

/// Status updates from LogosDeliveryActor to LogosDeliveryNode
enum LogosDeliveryStatusUpdate: Sendable {
    case statusChanged(LogosDeliveryNodeStatus)
    case connectionChanged(isConnected: Bool)
    case filterSubscriptionChanged(subscribed: Bool, failedAttempts: Int)
    case maintenanceChanged(active: Bool)
    case error(String)
}

/// Error with timestamp for toast queue
struct TimestampedError: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let timestamp: Date

    static func == (lhs: TimestampedError, rhs: TimestampedError) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Callback Context for C API

private final class CallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var _continuation: CheckedContinuation<(success: Bool, result: String?), Never>?
    private var _resumed = false
    var success: Bool = false
    var result: String?
    /// Set by the create callback before it resumes.
    var createdCtx: UnsafeMutablePointer<LogosDeliveryCtx>?

    var continuation: CheckedContinuation<(success: Bool, result: String?), Never>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _continuation
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _continuation = newValue
        }
    }

    /// Thread-safe resume - ensures continuation is only resumed once
    /// Returns true if this call actually resumed, false if already resumed
    @discardableResult
    func resumeOnce(returning value: (success: Bool, result: String?)) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !_resumed, let cont = _continuation else {
            return false
        }

        _resumed = true
        _continuation = nil
        cont.resume(returning: value)
        return true
    }
}

// MARK: - LogosDeliveryActor

/// Actor that isolates all Logos Delivery operations from the main thread
/// All C API calls and mutable state are contained here
actor LogosDeliveryActor {

    // MARK: - State

    private var ctx: UnsafeMutablePointer<LogosDeliveryCtx>?
    private var seenMessageHashes: Set<String> = []
    private var isSubscribed: Bool = false
    private var isSubscribing: Bool = false
    private var hasPeers: Bool = false
    private var maintenanceTask: Task<Void, Never>?
    private var eventProcessingTask: Task<Void, Never>?

    // Stream continuations for communicating with UI
    private var messageContinuation: AsyncStream<LogosDeliveryMessage>.Continuation?
    private var statusContinuation: AsyncStream<LogosDeliveryStatusUpdate>.Continuation?

    // Event stream from C callbacks
    private var eventContinuation: AsyncStream<String>.Continuation?

    // Configuration
    let defaultPubsubTopic = "/waku/2/rs/1/0"
    let defaultContentTopic = "/logos-delivery-ios-example/1/chat/proto"
    private let staticPeer = "/dns4/node-01.do-ams3.waku.sandbox.status.im/tcp/30303/p2p/16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ"

    // Subscription maintenance settings
    private let maxFailedSubscribes = 3
    private let retryWaitSeconds: UInt64 = 2_000_000_000        // 2 seconds in nanoseconds
    private let maintenanceIntervalSeconds: UInt64 = 30_000_000_000  // 30 seconds in nanoseconds
    private let maxSeenHashes = 1000

    // MARK: - Static callback storage (for C callbacks)

    // We need a way for C callbacks to reach the actor
    // Using a simple static reference (safe because we only have one instance)
    private static var sharedEventContinuation: AsyncStream<String>.Continuation?

    // FFICallback: the event-listener registry shape.
    private static let eventCallback: FFICallback = { ret, msg, len, userData in
        guard ret == RET_OK, let msg = msg else { return }
        let str = String(cString: msg)
        LogosDeliveryActor.sharedEventContinuation?.yield(str)
    }

    // LogosDelivery*ReplyFn: `reply` points at the reply text, or is nil on
    // failure, which `errMsg` then describes.
    private static let syncReplyCallback:
        @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = {
            ret, reply, errMsg, userData in
            guard let userData = userData else { return }
            let context = Unmanaged<CallbackContext>.fromOpaque(userData).takeRetainedValue()
            let success = (ret == RET_OK)
            let text = reply?.pointee ?? errMsg
            context.resumeOnce(returning: (success, text.map { String(cString: $0) }))
        }

    // LogosDeliveryCreateFn: hands over the context, or the failure text.
    private static let createCallback:
        @convention(c) (Int32, UnsafeMutablePointer<LogosDeliveryCtx>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = {
            ret, newCtx, errMsg, userData in
            guard let userData = userData else { return }
            let context = Unmanaged<CallbackContext>.fromOpaque(userData).takeRetainedValue()
            context.createdCtx = newCtx
            context.resumeOnce(returning: (ret == RET_OK, errMsg.map { String(cString: $0) }))
        }

    // MARK: - Stream Setup

    func setMessageContinuation(_ continuation: AsyncStream<LogosDeliveryMessage>.Continuation?) {
        self.messageContinuation = continuation
    }

    func setStatusContinuation(_ continuation: AsyncStream<LogosDeliveryStatusUpdate>.Continuation?) {
        self.statusContinuation = continuation
    }

    // MARK: - Public API

    var isRunning: Bool {
        ctx != nil
    }

    var hasConnectedPeers: Bool {
        hasPeers
    }

    func start() async {
        guard ctx == nil else {
            print("[LogosDeliveryActor] Already started")
            return
        }

        statusContinuation?.yield(.statusChanged(.starting))

        // Create event stream for C callbacks
        let eventStream = AsyncStream<String> { continuation in
            self.eventContinuation = continuation
            LogosDeliveryActor.sharedEventContinuation = continuation
        }

        // Start event processing task
        eventProcessingTask = Task { [weak self] in
            for await eventJson in eventStream {
                await self?.handleEvent(eventJson)
            }
        }

        // Initialize the node
        let success = await initializeNode()

        if success {
            statusContinuation?.yield(.statusChanged(.running))

            // Connect to peer
            let connected = await connectToPeer()
            if connected {
                hasPeers = true
                statusContinuation?.yield(.connectionChanged(isConnected: true))

                // Start maintenance loop
                startMaintenanceLoop()
            } else {
                statusContinuation?.yield(.error("Failed to connect to service peer"))
            }
        }
    }

    func stop() async {
        guard let context = ctx else { return }

        // Stop maintenance loop
        maintenanceTask?.cancel()
        maintenanceTask = nil

        // Stop event processing
        eventProcessingTask?.cancel()
        eventProcessingTask = nil

        // Close event stream
        eventContinuation?.finish()
        eventContinuation = nil
        LogosDeliveryActor.sharedEventContinuation = nil

        statusContinuation?.yield(.statusChanged(.stopped))
        statusContinuation?.yield(.connectionChanged(isConnected: false))
        statusContinuation?.yield(.filterSubscriptionChanged(subscribed: false, failedAttempts: 0))
        statusContinuation?.yield(.maintenanceChanged(active: false))

        // Reset state
        let ctxToStop = context
        ctx = nil
        isSubscribed = false
        isSubscribing = false
        hasPeers = false
        seenMessageHashes.removeAll()

        // Unsubscribe and stop in background (fire and forget)
        Task.detached {
            // Unsubscribe
            _ = await self.callLogosDeliverySync { logosdelivery_ctx_waku_filter_unsubscribe_all(ctxToStop, LogosDeliveryActor.syncReplyCallback, $0) }
            print("[LogosDeliveryActor] Unsubscribed from filter")

            // Stop
            _ = await self.callLogosDeliverySync { logosdelivery_ctx_stop_node(ctxToStop, LogosDeliveryActor.syncReplyCallback, $0) }
            print("[LogosDeliveryActor] Node stopped")

            // Destroy
            logosdelivery_ctx_destroy(ctxToStop)
            print("[LogosDeliveryActor] Node destroyed")
        }
    }

    func publish(message: String, contentTopic: String? = nil) async {
        guard let context = ctx else {
            print("[LogosDeliveryActor] Node not started")
            return
        }

        guard hasPeers else {
            print("[LogosDeliveryActor] No peers connected yet")
            statusContinuation?.yield(.error("No peers connected yet. Please wait..."))
            return
        }

        let topic = contentTopic ?? defaultContentTopic
        guard let payloadData = message.data(using: .utf8) else { return }
        let payloadBase64 = payloadData.base64EncodedString()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let jsonMessage = """
        {"payload":"\(payloadBase64)","contentTopic":"\(topic)","timestamp":\(timestamp)}
        """

        let result = await callLogosDeliverySync { userData in
            _ = self.defaultPubsubTopic.withCString { topicPtr in
                jsonMessage.withCString { msgPtr in
                    logosdelivery_ctx_waku_lightpush_publish(
                        context, topicPtr, msgPtr, LogosDeliveryActor.syncReplyCallback, userData)
                }
            }
        }

        if result.success {
            print("[LogosDeliveryActor] Published message")
        } else {
            print("[LogosDeliveryActor] Publish error: \(result.result ?? "unknown")")
            statusContinuation?.yield(.error("Failed to send message"))
        }
    }

    func resubscribe() async {
        print("[LogosDeliveryActor] Force resubscribe requested")
        isSubscribed = false
        isSubscribing = false
        statusContinuation?.yield(.filterSubscriptionChanged(subscribed: false, failedAttempts: 0))
        _ = await subscribe()
    }

    // MARK: - Private Methods

    private func initializeNode() async -> Bool {
        let config = """
        {
            "mode": "Edge",
            "messagingOverrides": {
                "tcp-port": 60000,
                "cluster-id": 1,
                "log-level": "DEBUG",
                "entry-node": [
                    "enr:-QESuEB4Dchgjn7gfAvwB00CxTA-nGiyk-aALI-H4dYSZD3rUk7bZHmP8d2U6xDiQ2vZffpo45Jp7zKNdnwDUx6g4o6XAYJpZIJ2NIJpcIRA4VDAim11bHRpYWRkcnO4XAArNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwAtNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQOvD3S3jUNICsrOILlmhENiWAMmMVlAl6-Q8wRB7hidY4N0Y3CCdl-DdWRwgiMohXdha3UyDw",
                    "enr:-QEkuEBIkb8q8_mrorHndoXH9t5N6ZfD-jehQCrYeoJDPHqT0l0wyaONa2-piRQsi3oVKAzDShDVeoQhy0uwN1xbZfPZAYJpZIJ2NIJpcIQiQlleim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQKnGt-GSgqPSf3IAPM7bFgTlpczpMZZLF3geeoNNsxzSoN0Y3CCdl-DdWRwgiMohXdha3UyDw"
                ],
                "discv5-udp-port": 9999
            }
        }
        """

        // Create node: the context arrives in the create callback.
        let callbackCtx = CallbackContext()
        let created = await withCheckedContinuation { (continuation: CheckedContinuation<(success: Bool, result: String?), Never>) in
            callbackCtx.continuation = continuation
            let userDataPtr = Unmanaged.passRetained(callbackCtx).toOpaque()
            // A failed call has already reported through the callback.
            _ = config.withCString { configPtr in
                logosdelivery_ctx_create(configPtr, LogosDeliveryActor.createCallback, userDataPtr)
            }
            // The callback releases userDataPtr: a late reply must still find it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                callbackCtx.resumeOnce(returning: (false, "Timeout"))
            }
        }
        let createResult = (ctx: callbackCtx.createdCtx, success: created.success, result: created.result)

        guard createResult.ctx != nil else {
            statusContinuation?.yield(.statusChanged(.error))
            statusContinuation?.yield(.error("Failed to create node: \(createResult.result ?? "unknown")"))
            return false
        }

        ctx = createResult.ctx

        // Register per-event listeners
        let eventNames = [
            "onMessageSent", "onMessageError", "onMessagePropagated",
            "onMessageReceived", "onConnectionStatusChange", "onTopicHealthChange",
            "onConnectionChange", "onReceivedMessage", "onChannelMessageReceived",
            "onChannelMessageSent", "onChannelMessageError",
        ]
        for name in eventNames {
            _ = logosdelivery_add_event_listener(createResult.ctx!.pointee.ptr, name, LogosDeliveryActor.eventCallback, nil)
        }

        // Start node
        let startResult = await callLogosDeliverySync { userData in
            _ = logosdelivery_ctx_start_node(self.ctx, LogosDeliveryActor.syncReplyCallback, userData)
        }

        guard startResult.success else {
            statusContinuation?.yield(.statusChanged(.error))
            statusContinuation?.yield(.error("Failed to start node: \(startResult.result ?? "unknown")"))
            ctx = nil
            return false
        }

        print("[LogosDeliveryActor] Node started")
        return true
    }

    private func connectToPeer() async -> Bool {
        guard let context = ctx else { return false }

        print("[LogosDeliveryActor] Connecting to static peer...")

        let result = await callLogosDeliverySync { userData in
            _ = self.staticPeer.withCString { peerPtr in
                logosdelivery_ctx_waku_connect(
                    context, peerPtr, 10000, LogosDeliveryActor.syncReplyCallback, userData)
            }
        }

        if result.success {
            print("[LogosDeliveryActor] Connected to peer successfully")
            return true
        } else {
            print("[LogosDeliveryActor] Failed to connect: \(result.result ?? "unknown")")
            return false
        }
    }

    private func subscribe(contentTopic: String? = nil) async -> Bool {
        guard let context = ctx else { return false }
        guard !isSubscribed && !isSubscribing else { return isSubscribed }

        isSubscribing = true
        let topic = contentTopic ?? defaultContentTopic

        let result = await callLogosDeliverySync { userData in
            _ = self.defaultPubsubTopic.withCString { topicPtr in
                topic.withCString { contentPtr in
                    logosdelivery_ctx_waku_filter_subscribe(
                        context, topicPtr, contentPtr, LogosDeliveryActor.syncReplyCallback, userData)
                }
            }
        }

        isSubscribing = false

        if result.success {
            print("[LogosDeliveryActor] Subscribe request successful to \(topic)")
            isSubscribed = true
            statusContinuation?.yield(.filterSubscriptionChanged(subscribed: true, failedAttempts: 0))
            return true
        } else {
            print("[LogosDeliveryActor] Subscribe error: \(result.result ?? "unknown")")
            isSubscribed = false
            return false
        }
    }

    private func pingFilterPeer() async -> Bool {
        guard let context = ctx else { return false }

        let result = await callLogosDeliverySync { userData in
            _ = self.staticPeer.withCString { peerPtr in
                logosdelivery_ctx_waku_ping_peer(
                    context, peerPtr, 10000, LogosDeliveryActor.syncReplyCallback, userData)
            }
        }

        return result.success
    }

    // MARK: - Subscription Maintenance

    private func startMaintenanceLoop() {
        guard maintenanceTask == nil else {
            print("[LogosDeliveryActor] Maintenance loop already running")
            return
        }

        statusContinuation?.yield(.maintenanceChanged(active: true))
        print("[LogosDeliveryActor] Starting subscription maintenance loop")

        maintenanceTask = Task { [weak self] in
            guard let self = self else { return }

            var failedSubscribes = 0
            var isFirstPingOnConnection = true

            while !Task.isCancelled {
                guard await self.isRunning else { break }

                print("[LogosDeliveryActor] Maintaining subscription...")

                let pingSuccess = await self.pingFilterPeer()
                let currentlySubscribed = await self.isSubscribed

                if pingSuccess && currentlySubscribed {
                    print("[LogosDeliveryActor] Subscription is live, waiting 30s")
                    try? await Task.sleep(nanoseconds: self.maintenanceIntervalSeconds)
                    continue
                }

                if !isFirstPingOnConnection && !pingSuccess {
                    print("[LogosDeliveryActor] Ping failed - subscription may be lost")
                    await self.statusContinuation?.yield(.filterSubscriptionChanged(subscribed: false, failedAttempts: failedSubscribes))
                }
                isFirstPingOnConnection = false

                print("[LogosDeliveryActor] No active subscription found. Sending subscribe request...")

                await self.resetSubscriptionState()
                let subscribeSuccess = await self.subscribe()

                if subscribeSuccess {
                    print("[LogosDeliveryActor] Subscribe request successful")
                    failedSubscribes = 0
                    try? await Task.sleep(nanoseconds: self.maintenanceIntervalSeconds)
                    continue
                }

                failedSubscribes += 1
                await self.statusContinuation?.yield(.filterSubscriptionChanged(subscribed: false, failedAttempts: failedSubscribes))
                print("[LogosDeliveryActor] Subscribe request failed. Attempt \(failedSubscribes)/\(self.maxFailedSubscribes)")

                if failedSubscribes < self.maxFailedSubscribes {
                    print("[LogosDeliveryActor] Retrying in 2s...")
                    try? await Task.sleep(nanoseconds: self.retryWaitSeconds)
                } else {
                    print("[LogosDeliveryActor] Max subscribe failures reached")
                    await self.statusContinuation?.yield(.error("Filter subscription failed after \(self.maxFailedSubscribes) attempts"))
                    failedSubscribes = 0
                    try? await Task.sleep(nanoseconds: self.maintenanceIntervalSeconds)
                }
            }

            print("[LogosDeliveryActor] Subscription maintenance loop stopped")
            await self.statusContinuation?.yield(.maintenanceChanged(active: false))
        }
    }

    private func resetSubscriptionState() {
        isSubscribed = false
        isSubscribing = false
    }

    // MARK: - Event Handling

    private func handleEvent(_ eventJson: String) {
        guard let data = eventJson.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["eventType"] as? String else {
            return
        }

        if eventType == "connection_change" {
            handleConnectionChange(json)
        } else if eventType == "message" {
            handleMessage(json)
        }
    }

    private func handleConnectionChange(_ json: [String: Any]) {
        guard let peerEvent = json["peerEvent"] as? String else { return }

        if peerEvent == "Joined" || peerEvent == "Identified" {
            hasPeers = true
            statusContinuation?.yield(.connectionChanged(isConnected: true))
        } else if peerEvent == "Left" {
            statusContinuation?.yield(.filterSubscriptionChanged(subscribed: false, failedAttempts: 0))
        }
    }

    private func handleMessage(_ json: [String: Any]) {
        guard let messageHash = json["messageHash"] as? String,
              let logosDeliveryMessage = json["logosDeliveryMessage"] as? [String: Any],
              let payloadBase64 = logosDeliveryMessage["payload"] as? String,
              let contentTopic = logosDeliveryMessage["contentTopic"] as? String,
              let payloadData = Data(base64Encoded: payloadBase64),
              let payloadString = String(data: payloadData, encoding: .utf8) else {
            return
        }

        // Deduplicate
        guard !seenMessageHashes.contains(messageHash) else {
            return
        }

        seenMessageHashes.insert(messageHash)

        // Limit memory usage
        if seenMessageHashes.count > maxSeenHashes {
            seenMessageHashes.removeAll()
        }

        let message = LogosDeliveryMessage(
            id: messageHash,
            payload: payloadString,
            contentTopic: contentTopic,
            timestamp: Date()
        )

        messageContinuation?.yield(message)
    }

    // MARK: - Helper for synchronous C calls

    private func callLogosDeliverySync(_ work: @escaping (UnsafeMutableRawPointer) -> Void) async -> (success: Bool, result: String?) {
        await withCheckedContinuation { continuation in
            let context = CallbackContext()
            context.continuation = continuation
            let userDataPtr = Unmanaged.passRetained(context).toOpaque()

            work(userDataPtr)

            // Set a timeout to avoid hanging forever
            // The callback releases userDataPtr: a late reply must still find it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                // Try to resume with timeout - will be ignored if callback already resumed
                let didTimeout = context.resumeOnce(returning: (false, "Timeout"))
                if didTimeout {
                    print("[LogosDeliveryActor] Call timed out")
                }
            }
        }
    }
}

// MARK: - LogosDeliveryNode (MainActor UI Wrapper)

/// Main-thread UI wrapper that consumes updates from LogosDeliveryActor via AsyncStreams
@MainActor
class LogosDeliveryNode: ObservableObject {

    // MARK: - Published Properties (UI State)

    @Published var status: LogosDeliveryNodeStatus = .stopped
    @Published var receivedMessages: [LogosDeliveryMessage] = []
    @Published var errorQueue: [TimestampedError] = []
    @Published var isConnected: Bool = false
    @Published var filterSubscribed: Bool = false
    @Published var subscriptionMaintenanceActive: Bool = false
    @Published var failedSubscribeAttempts: Int = 0

    // Topics (read-only access to actor's config)
    var defaultPubsubTopic: String { "/waku/2/rs/1/0" }
    var defaultContentTopic: String { "/logos-delivery-ios-example/1/chat/proto" }

    // MARK: - Private Properties

    private let actor = LogosDeliveryActor()
    private var messageTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {}

    deinit {
        messageTask?.cancel()
        statusTask?.cancel()
    }

    // MARK: - Public API

    func start() {
        guard status == .stopped || status == .error else {
            print("[LogosDeliveryNode] Already started or starting")
            return
        }

        // Create message stream
        let messageStream = AsyncStream<LogosDeliveryMessage> { continuation in
            Task {
                await self.actor.setMessageContinuation(continuation)
            }
        }

        // Create status stream
        let statusStream = AsyncStream<LogosDeliveryStatusUpdate> { continuation in
            Task {
                await self.actor.setStatusContinuation(continuation)
            }
        }

        // Start consuming messages
        messageTask = Task { @MainActor in
            for await message in messageStream {
                self.receivedMessages.insert(message, at: 0)
                if self.receivedMessages.count > 100 {
                    self.receivedMessages.removeLast()
                }
            }
        }

        // Start consuming status updates
        statusTask = Task { @MainActor in
            for await update in statusStream {
                self.handleStatusUpdate(update)
            }
        }

        // Start the actor
        Task {
            await actor.start()
        }
    }

    func stop() {
        messageTask?.cancel()
        messageTask = nil
        statusTask?.cancel()
        statusTask = nil

        Task {
            await actor.stop()
        }

        // Immediate UI update
        status = .stopped
        isConnected = false
        filterSubscribed = false
        subscriptionMaintenanceActive = false
        failedSubscribeAttempts = 0
    }

    func publish(message: String, contentTopic: String? = nil) {
        Task {
            await actor.publish(message: message, contentTopic: contentTopic)
        }
    }

    func resubscribe() {
        Task {
            await actor.resubscribe()
        }
    }

    func dismissError(_ error: TimestampedError) {
        errorQueue.removeAll { $0.id == error.id }
    }

    func dismissAllErrors() {
        errorQueue.removeAll()
    }

    // MARK: - Private Methods

    private func handleStatusUpdate(_ update: LogosDeliveryStatusUpdate) {
        switch update {
        case .statusChanged(let newStatus):
            status = newStatus

        case .connectionChanged(let connected):
            isConnected = connected

        case .filterSubscriptionChanged(let subscribed, let attempts):
            filterSubscribed = subscribed
            failedSubscribeAttempts = attempts

        case .maintenanceChanged(let active):
            subscriptionMaintenanceActive = active

        case .error(let message):
            let error = TimestampedError(message: message, timestamp: Date())
            errorQueue.append(error)

            // Schedule auto-dismiss after 10 seconds
            let errorId = error.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self.errorQueue.removeAll { $0.id == errorId }
            }
        }
    }
}
