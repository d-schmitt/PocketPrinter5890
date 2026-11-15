import Foundation
import PocketPrinter5890Kit

public enum BLETransportError: Error, Equatable {
    case notReady
    case bluetoothUnavailable
    case connectionFailed(String)
    case discoveryFailed(String)
    case notificationFailed(characteristic: String, message: String)
    case writeFailed(String)
    case disconnected
}

public enum BLEConnectionState: Equatable {
    case disconnected
    case connecting
    case discovering
    case subscribing
    case ready
    case disconnecting
    case failed(BLETransportError)
}

/// A drain is local submission, not confirmation that paper was printed.
public enum BLEWriteState: Equatable {
    case idle
    case pending(remainingBytes: Int, awaitingResponse: Bool)
    case drained
    case cancelled
    case failed(BLETransportError)
}

// Shared by the CoreBluetooth adapter and hardware-free executable checks.
package struct BLETransportState {
    package init() {}

    package struct Write {
        package var bytes: [UInt8]
        package let label: String
        package let requiresCredit: Bool
    }

    package struct Response {
        package let id = UUID()
        package let label: String
        package let context: String
    }

    package private(set) var connection: BLEConnectionState = .disconnected
    package private(set) var writes: BLEWriteState = .idle
    package private(set) var generation = UUID()
    package private(set) var queue: [Write] = []
    package private(set) var credits = 0
    package private(set) var awaitingResponse = false
    package var waitingForDelay = false
    package var watchdogArmed = false
    package private(set) var totalBytes = 0
    package private(set) var submittedBytes = 0
    package private(set) var responses: [Response] = []
    private var requiredNotifications: Set<String> = []
    private var confirmedNotifications: Set<String> = []

    package var progress: Double {
        totalBytes == 0 ? 1 : Double(submittedBytes) / Double(totalBytes)
    }

    package mutating func reset(connection: BLEConnectionState, writes: BLEWriteState) {
        self = BLETransportState()
        self.connection = connection
        self.writes = writes
    }

    package mutating func discovering() {
        connection = .discovering
    }

    package mutating func subscribe(to required: Set<String>) {
        requiredNotifications = required
        confirmedNotifications.removeAll()
        connection = .subscribing
    }

    package mutating func notification(_ uuid: String, enabled: Bool, error: String? = nil) {
        guard requiredNotifications.contains(uuid),
              connection == .subscribing || connection == .ready else { return }
        guard enabled, error == nil else {
            let failure = BLETransportError.notificationFailed(
                characteristic: uuid, message: error ?? "Notification subscription is disabled"
            )
            reset(connection: .failed(failure), writes: .failed(failure))
            return
        }
        confirmedNotifications.insert(uuid)
        if confirmedNotifications == requiredNotifications {
            connection = .ready
        }
    }

    package mutating func enqueue(_ segments: [PrintSegment]) {
        let nonempty = segments.filter { !$0.bytes.isEmpty }
        guard !nonempty.isEmpty else { return }
        guard connection == .ready else {
            writes = .failed(.notReady)
            return
        }
        if queue.isEmpty, !awaitingResponse {
            totalBytes = 0
            submittedBytes = 0
        }
        for segment in nonempty {
            totalBytes += segment.bytes.count
            // Classify once at the command boundary, never from a shrinking
            // tail. Even a complete 384-dot one-row raster is only 56 bytes.
            // Keep the historical bulk guard for other large raw payloads.
            let isRaster = segment.bytes.starts(with: [0x1d, 0x76, 0x30])
            queue.append(Write(bytes: segment.bytes, label: segment.name,
                               requiresCredit: isRaster || segment.bytes.count > 64))
        }
        updateWrites()
    }

    package mutating func grantCredits(_ count: UInt8) {
        credits += Int(count)
    }

    package mutating func nextChunk(limit: Int, withResponse: Bool, useCredits: Bool) -> Write? {
        guard connection == .ready, !awaitingResponse, !waitingForDelay,
              let first = queue.first else { return nil }
        if useCredits, first.requiresCredit, credits == 0 { return nil }
        var request = queue.removeFirst()
        let chunk = Array(request.bytes.prefix(max(1, limit)))
        request.bytes.removeFirst(chunk.count)
        if !request.bytes.isEmpty { queue.insert(request, at: 0) }
        if useCredits, request.requiresCredit { credits -= 1 }
        awaitingResponse = withResponse
        submittedBytes += chunk.count
        rememberResponse(label: request.label, bytes: chunk)
        updateWrites()
        return Write(bytes: chunk, label: request.label, requiresCredit: request.requiresCredit)
    }

    package mutating func completeResponse(generation: UUID, error: String? = nil) {
        guard self.generation == generation, awaitingResponse else { return }
        if let error {
            let failure = BLETransportError.writeFailed(error)
            reset(connection: .failed(failure), writes: .failed(failure))
        } else {
            awaitingResponse = false
            updateWrites()
        }
    }

    package mutating func resume(generation: UUID) -> Bool {
        guard self.generation == generation else { return false }
        waitingForDelay = false
        return true
    }

    package mutating func resolveResponse(_ bytes: [UInt8]) -> Response? {
        guard let index = responses.firstIndex(where: {
            ResponseDecoder.looksLikeSolicitedResponse(bytes, context: $0.context)
        }) else { return nil }
        return responses.remove(at: index)
    }

    package mutating func expireResponse(id: UUID, generation: UUID) -> Response? {
        guard self.generation == generation,
              let index = responses.firstIndex(where: { $0.id == id }) else { return nil }
        return responses.remove(at: index)
    }

    private mutating func updateWrites() {
        let remaining = queue.reduce(0) { $0 + $1.bytes.count }
        writes = remaining == 0 && !awaitingResponse
            ? .drained : .pending(remainingBytes: remaining, awaitingResponse: awaitingResponse)
    }

    private mutating func rememberResponse(label: String, bytes: [UInt8]) {
        let context: String
        switch bytes {
        case PrinterCommand.model: context = "model"
        case PrinterCommand.firmware: context = "firmware"
        case PrinterCommand.serialNumber: context = "serial"
        case PrinterCommand.battery: context = "battery"
        case PrinterCommand.paperStatus: context = "paper"
        default: return
        }
        responses.append(Response(label: label, context: context))
    }
}
