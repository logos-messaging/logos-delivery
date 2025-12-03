//
//  WakuNode.swift
//  WakuExample
//
//  Swift wrapper around libwaku C API for edge mode (lightpush + filter)
//  Uses Swift actors for thread safety and UI responsiveness
//

import Foundation

// MARK: - Data Types

/// Message received from Waku network
struct WakuMessage: Identifiable, Equatable, Sendable {
    let id: String  // messageHash from Waku - unique identifier for deduplication
    let payload: String
    let contentTopic: String
    let timestamp: Date
}

/// Waku node status
enum WakuNodeStatus: String, Sendable {
    case stopped = "Stopped"
    case starting = "Starting..."
    case running = "Running"
    case error = "Error"
}

/// Status updates from WakuActor to WakuNode
enum WakuStatusUpdate: Sendable {
    case statusChanged(WakuNodeStatus)
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

// MARK: - WakuActor

/// Actor that isolates all Waku operations from the main thread
/// All C API calls and mutable state are contained here
actor WakuActor {

    // MARK: - State

    private var ctx: UnsafeMutableRawPointer?
    private var seenMessageHashes: Set<String> = []
    private var isSubscribed: Bool = false
    private var isSubscribing: Bool = false
    private var hasPeers: Bool = false
    private var maintenanceTask: Task<Void, Never>?
    private var eventProcessingTask: Task<Void, Never>?

    // Stream continuations for communicating with UI
    private var messageContinuation: AsyncStream<WakuMessage>.Continuation?
    private var statusContinuation: AsyncStream<WakuStatusUpdate>.Continuation?

    // Event stream from C callbacks
    private var eventContinuation: AsyncStream<String>.Continuation?

    // Configuration
    let defaultPubsubTopic = "/waku/2/rs/1/0"
    let defaultContentTopic = "/waku-ios-example/1/chat/proto"
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

    private static let eventCallback: WakuCallBack = { ret, msg, len, userData in
        guard ret == RET_OK, let msg = msg else { return }
        let str = String(cString: msg)
        WakuActor.sharedEventContinuation?.yield(str)
    }

    private static let syncCallback: WakuCallBack = { ret, msg, len, userData in
        guard let userData = userData else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(userData).takeUnretainedValue()
        let success = (ret == RET_OK)
        var resultStr: String? = nil
        if let msg = msg {
            resultStr = String(cString: msg)
        }
        context.resumeOnce(returning: (success, resultStr))
    }

    // MARK: - Stream Setup

    func setMessageContinuation(_ continuation: AsyncStream<WakuMessage>.Continuation?) {
        self.messageContinuation = continuation
    }

    func setStatusContinuation(_ continuation: AsyncStream<WakuStatusUpdate>.Continuation?) {
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
            print("[WakuActor] Already started")
            return
        }

        statusContinuation?.yield(.statusChanged(.starting))

        // Create event stream for C callbacks
        let eventStream = AsyncStream<String> { continuation in
            self.eventContinuation = continuation
            WakuActor.sharedEventContinuation = continuation
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
        WakuActor.sharedEventContinuation = nil

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
            _ = await self.callWakuSync { waku_filter_unsubscribe_all(ctxToStop, WakuActor.syncCallback, $0) }
            print("[WakuActor] Unsubscribed from filter")

            // Stop
            _ = await self.callWakuSync { waku_stop(ctxToStop, WakuActor.syncCallback, $0) }
            print("[WakuActor] Node stopped")

            // Destroy
            _ = await self.callWakuSync { waku_destroy(ctxToStop, WakuActor.syncCallback, $0) }
            print("[WakuActor] Node destroyed")
        }
    }

    func publish(message: String, contentTopic: String? = nil) async {
        guard let context = ctx else {
            print("[WakuActor] Node not started")
            return
        }

        guard hasPeers else {
            print("[WakuActor] No peers connected yet")
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

        let result = await callWakuSync { userData in
            waku_lightpush_publish(
                context,
                self.defaultPubsubTopic,
                jsonMessage,
                WakuActor.syncCallback,
                userData
            )
        }

        if result.success {
            print("[WakuActor] Published message")
        } else {
            print("[WakuActor] Publish error: \(result.result ?? "unknown")")
            statusContinuation?.yield(.error("Failed to send message"))
        }
    }

    func resubscribe() async {
        print("[WakuActor] Force resubscribe requested")
        isSubscribed = false
        isSubscribing = false
        statusContinuation?.yield(.filterSubscriptionChanged(subscribed: false, failedAttempts: 0))
        _ = await subscribe()
    }

    // MARK: - Private Methods

    private func initializeNode() async -> Bool {
        let config = """
        {
            "tcpPort": 60000,
            "clusterId": 1,
            "shards": [0],
            "relay": false,
            "lightpush": true,
            "filter": true,
            "logLevel": "DEBUG",
            "discv5Discovery": true,
            "discv5BootstrapNodes": [
                "enr:-QESuEB4Dchgjn7gfAvwB00CxTA-nGiyk-aALI-H4dYSZD3rUk7bZHmP8d2U6xDiQ2vZffpo45Jp7zKNdnwDUx6g4o6XAYJpZIJ2NIJpcIRA4VDAim11bHRpYWRkcnO4XAArNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwAtNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQOvD3S3jUNICsrOILlmhENiWAMmMVlAl6-Q8wRB7hidY4N0Y3CCdl-DdWRwgiMohXdha3UyDw",
                "enr:-QEkuEBIkb8q8_mrorHndoXH9t5N6ZfD-jehQCrYeoJDPHqT0l0wyaONa2-piRQsi3oVKAzDShDVeoQhy0uwN1xbZfPZAYJpZIJ2NIJpcIQiQlleim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQKnGt-GSgqPSf3IAPM7bFgTlpczpMZZLF3geeoNNsxzSoN0Y3CCdl-DdWRwgiMohXdha3UyDw"
            ],
            "discv5UdpPort": 9999,
            "dnsDiscovery": true,
            "dnsDiscoveryUrl": "enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im",
            "dnsDiscoveryNameServers": ["8.8.8.8", "1.0.0.1"]
        }
        """

        // Create node - waku_new is special, it returns the context directly
        let createResult = await withCheckedContinuation { (continuation: CheckedContinuation<(ctx: UnsafeMutableRawPointer?, success: Bool, result: String?), Never>) in
            let callbackCtx = CallbackContext()
            let userDataPtr = Unmanaged.passRetained(callbackCtx).toOpaque()

            // Set up a simple callback for waku_new
            let newCtx = waku_new(config, { ret, msg, len, userData in
                guard let userData = userData else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(userData).takeUnretainedValue()
                context.success = (ret == RET_OK)
                if let msg = msg {
                    context.result = String(cString: msg)
                }
            }, userDataPtr)

            // Small delay to ensure callback completes
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                Unmanaged<CallbackContext>.fromOpaque(userDataPtr).release()
                continuation.resume(returning: (newCtx, callbackCtx.success, callbackCtx.result))
            }
        }

        guard createResult.ctx != nil else {
            statusContinuation?.yield(.statusChanged(.error))
            statusContinuation?.yield(.error("Failed to create node: \(createResult.result ?? "unknown")"))
            return false
        }

        ctx = createResult.ctx

        // Set event callback
        waku_set_event_callback(ctx, WakuActor.eventCallback, nil)

        // Start node
        let startResult = await callWakuSync { userData in
            waku_start(self.ctx, WakuActor.syncCallback, userData)
        }

        guard startResult.success else {
            statusContinuation?.yield(.statusChanged(.error))
            statusContinuation?.yield(.error("Failed to start node: \(startResult.result ?? "unknown")"))
            ctx = nil
            return false
        }

        print("[WakuActor] Node started")
        return true
    }

    private func connectToPeer() async -> Bool {
        guard let context = ctx else { return false }

        print("[WakuActor] Connecting to static peer...")

        let result = await callWakuSync { userData in
            waku_connect(context, self.staticPeer, 10000, WakuActor.syncCallback, userData)
        }

        if result.success {
            print("[WakuActor] Connected to peer successfully")
            return true
        } else {
            print("[WakuActor] Failed to connect: \(result.result ?? "unknown")")
            return false
        }
    }

    private func subscribe(contentTopic: String? = nil) async -> Bool {
        guard let context = ctx else { return false }
        guard !isSubscribed && !isSubscribing else { return isSubscribed }

        isSubscribing = true
        let topic = contentTopic ?? defaultContentTopic

        let result = await callWakuSync { userData in
            waku_filter_subscribe(
                context,
                self.defaultPubsubTopic,
                topic,
                WakuActor.syncCallback,
                userData
            )
        }

        isSubscribing = false

        if result.success {
            print("[WakuActor] Subscribe request successful to \(topic)")
            isSubscribed = true
            statusContinuation?.yield(.filterSubscriptionChanged(subscribed: true, failedAttempts: 0))
            return true
        } else {
            print("[WakuActor] Subscribe error: \(result.result ?? "unknown")")
            isSubscribed = false
            return false
        }
    }

    private func pingFilterPeer() async -> Bool {
        guard let context = ctx else { return false }

        let result = await callWakuSync { userData in
            waku_ping_peer(
                context,
                self.staticPeer,
                10000,
                WakuActor.syncCallback,
                userData
            )
        }

        return result.success
    }

    // MARK: - Subscription Maintenance

    private func startMaintenanceLoop() {
        guard maintenanceTask == nil else {
            print("[WakuActor] Maintenance loop already running")
            return
        }

        statusContinuation?.yield(.maintenanceChanged(active: true))
        print("[WakuActor] Starting subscription maintenance loop")

        maintenanceTask = Task { [weak self] in
            guard let self = self else { return }

            var failedSubscribes = 0
            var isFirstPingOnConnection = true

            while !Task.isCancelled {
                guard await self.isRunning else { break }

                print("[WakuActor] Maintaining subscription...")

                let pingSuccess = await self.pingFilterPeer()
                let currentlySubscribed = await self.isSubscribed

                if pingSuccess && currentlySubscribed {
                    print("[WakuActor] Subscription is live, waiting 30s")
                    try? await Task.sleep(nanoseconds: self.maintenanceIntervalSeconds)
                    continue
                }

                if !isFirstPingOnConnection && !pingSuccess {
                    print("[WakuActor] Ping failed - subscription may be lost")
                    await self.statusContinuation?.yield(.filterSubscriptionChanged(subscribed: false, failedAttempts: failedSubscribes))
                }
                isFirstPingOnConnection = false

                print("[WakuActor] No active subscription found. Sending subscribe request...")

                await self.resetSubscriptionState()
                let subscribeSuccess = await self.subscribe()

                if subscribeSuccess {
                    print("[WakuActor] Subscribe request successful")
                    failedSubscribes = 0
                    try? await Task.sleep(nanoseconds: self.maintenanceIntervalSeconds)
                    continue
                }

                failedSubscribes += 1
                await self.statusContinuation?.yield(.filterSubscriptionChanged(subscribed: false, failedAttempts: failedSubscribes))
                print("[WakuActor] Subscribe request failed. Attempt \(failedSubscribes)/\(self.maxFailedSubscribes)")

                if failedSubscribes < self.maxFailedSubscribes {
                    print("[WakuActor] Retrying in 2s...")
                    try? await Task.sleep(nanoseconds: self.retryWaitSeconds)
                } else {
                    print("[WakuActor] Max subscribe failures reached")
                    await self.statusContinuation?.yield(.error("Filter subscription failed after \(self.maxFailedSubscribes) attempts"))
                    failedSubscribes = 0
                    try? await Task.sleep(nanoseconds: self.maintenanceIntervalSeconds)
                }
            }

            print("[WakuActor] Subscription maintenance loop stopped")
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
              let wakuMessage = json["wakuMessage"] as? [String: Any],
              let payloadBase64 = wakuMessage["payload"] as? String,
              let contentTopic = wakuMessage["contentTopic"] as? String,
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

        let message = WakuMessage(
            id: messageHash,
            payload: payloadString,
            contentTopic: contentTopic,
            timestamp: Date()
        )

        messageContinuation?.yield(message)
    }

    // MARK: - Helper for synchronous C calls

    private func callWakuSync(_ work: @escaping (UnsafeMutableRawPointer) -> Void) async -> (success: Bool, result: String?) {
        await withCheckedContinuation { continuation in
            let context = CallbackContext()
            context.continuation = continuation
            let userDataPtr = Unmanaged.passRetained(context).toOpaque()

            work(userDataPtr)

            // Set a timeout to avoid hanging forever
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                // Try to resume with timeout - will be ignored if callback already resumed
                let didTimeout = context.resumeOnce(returning: (false, "Timeout"))
                if didTimeout {
                    print("[WakuActor] Call timed out")
                }
                Unmanaged<CallbackContext>.fromOpaque(userDataPtr).release()
            }
        }
    }
}

// MARK: - WakuNode (MainActor UI Wrapper)

/// Main-thread UI wrapper that consumes updates from WakuActor via AsyncStreams
@MainActor
class WakuNode: ObservableObject {

    // MARK: - Published Properties (UI State)

    @Published var status: WakuNodeStatus = .stopped
    @Published var receivedMessages: [WakuMessage] = []
    @Published var errorQueue: [TimestampedError] = []
    @Published var isConnected: Bool = false
    @Published var filterSubscribed: Bool = false
    @Published var subscriptionMaintenanceActive: Bool = false
    @Published var failedSubscribeAttempts: Int = 0

    // Topics (read-only access to actor's config)
    var defaultPubsubTopic: String { "/waku/2/rs/1/0" }
    var defaultContentTopic: String { "/waku-ios-example/1/chat/proto" }

    // MARK: - Private Properties

    private let actor = WakuActor()
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
            print("[WakuNode] Already started or starting")
            return
        }

        // Create message stream
        let messageStream = AsyncStream<WakuMessage> { continuation in
            Task {
                await self.actor.setMessageContinuation(continuation)
            }
        }

        // Create status stream
        let statusStream = AsyncStream<WakuStatusUpdate> { continuation in
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

    private func handleStatusUpdate(_ update: WakuStatusUpdate) {
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
