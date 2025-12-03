//
//  ContentView.swift
//  WakuExample
//
//  Minimal chat PoC using libwaku on iOS
//

import SwiftUI

struct ContentView: View {
    @StateObject private var wakuNode = WakuNode()
    @State private var messageText = ""

    var body: some View {
        ZStack {
            // Main content
            VStack(spacing: 0) {
                // Header with status
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wakuNode.status.rawValue)
                            .font(.caption)
                        if wakuNode.status == .running {
                            HStack(spacing: 4) {
                                Text(wakuNode.isConnected ? "Connected" : "Discovering...")
                                Text("•")
                                filterStatusView
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)

                            // Subscription maintenance status
                            if wakuNode.subscriptionMaintenanceActive {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundColor(.blue)
                                    Text("Maintenance active")
                                    if wakuNode.failedSubscribeAttempts > 0 {
                                        Text("(\(wakuNode.failedSubscribeAttempts) retries)")
                                            .foregroundColor(.orange)
                                    }
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if wakuNode.status == .stopped {
                        Button("Start") {
                            wakuNode.start()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if wakuNode.status == .running {
                        if !wakuNode.filterSubscribed {
                            Button("Resub") {
                                wakuNode.resubscribe()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Button("Stop") {
                            wakuNode.stop()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))

                // Messages list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(wakuNode.receivedMessages.reversed()) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: wakuNode.receivedMessages.count) { _, newCount in
                        if let lastMessage = wakuNode.receivedMessages.first {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Message input
                HStack(spacing: 12) {
                    TextField("Message", text: $messageText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(wakuNode.status != .running)

                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.white)
                            .padding(10)
                            .background(canSend ? Color.blue : Color.gray)
                            .clipShape(Circle())
                    }
                    .disabled(!canSend)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
            }

            // Toast overlay for errors
            VStack {
                ForEach(wakuNode.errorQueue) { error in
                    ToastView(error: error) {
                        wakuNode.dismissError(error)
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                Spacer()
            }
            .padding(.top, 8)
            .animation(.easeInOut(duration: 0.3), value: wakuNode.errorQueue)
        }
    }

    private var statusColor: Color {
        switch wakuNode.status {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .error: return .red
        }
    }

    @ViewBuilder
    private var filterStatusView: some View {
        if wakuNode.filterSubscribed {
            Text("Filter OK")
                .foregroundColor(.green)
        } else if wakuNode.failedSubscribeAttempts > 0 {
            Text("Filter retrying (\(wakuNode.failedSubscribeAttempts))")
                .foregroundColor(.orange)
        } else {
            Text("Filter pending")
                .foregroundColor(.orange)
        }
    }

    private var canSend: Bool {
        wakuNode.status == .running && wakuNode.isConnected && !messageText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        wakuNode.publish(message: text)
        messageText = ""
    }
}

// MARK: - Toast View

struct ToastView: View {
    let error: TimestampedError
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)

            Text(error.message)
                .font(.subheadline)
                .foregroundColor(.white)
                .lineLimit(2)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.8))
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.9))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: WakuMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.payload)
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)

            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
