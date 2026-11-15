import Foundation
import PocketPrinter5890Kit
import PocketPrinter5890BLE

private var failures = 0
private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func readyState() -> BLETransportState {
    var state = BLETransportState()
    state.subscribe(to: ["FF01", "FF03"])
    state.notification("FF01", enabled: true)
    state.notification("FF03", enabled: true)
    return state
}

private func bitmap(rows: Int) throws -> MonochromeBitmap {
    try MonochromeBitmap(width: 384, height: rows, bytes: Array(repeating: 0x55, count: rows * 48))
}

private func raster(rows: Int) throws -> [UInt8] {
    RasterEncoder.bandedRasterCommands(for: try bitmap(rows: rows)).flatMap { $0 }
}

private func checkRasterCredits() throws {
    var state = readyState()
    let image = try raster(rows: 250)
    state.enqueue([PrintSegment(name: "Raster", bytes: image)])
    check(state.nextChunk(limit: 180, withResponse: false, useCredits: true) == nil,
          "raster must wait for first credit")
    state.grantCredits(67)
    var sent: [UInt8] = []
    for _ in 0..<67 {
        sent += state.nextChunk(limit: 180, withResponse: false, useCredits: true)?.bytes ?? []
    }
    check(sent.count == 12060, "67 credits submit exactly 67 full chunks")
    check(state.nextChunk(limit: 180, withResponse: false, useCredits: true) == nil,
          "28-byte raster tail still requires credit")
    state.grantCredits(1)
    sent += state.nextChunk(limit: 180, withResponse: false, useCredits: true)?.bytes ?? []
    check(sent == image && state.writes == .drained, "later credit drains exact raster bytes")

    state = readyState()
    let oneRow = try raster(rows: 1)
    state.enqueue([PrintSegment(name: "One row", bytes: oneRow)])
    check(state.nextChunk(limit: 180, withResponse: false, useCredits: true) == nil,
          "entire 56-byte one-row raster requires credit")
    state.grantCredits(1)
    check(state.nextChunk(limit: 180, withResponse: false, useCredits: true)?.bytes == oneRow,
          "one-row raster resumes after credit")
}

private func checkAtomicJobAndActivation() throws {
    var state = readyState()
    let segments = PrintJobBuilder.segments(bitmap: try bitmap(rows: 25), options: PrintOptions())
    let expected = segments.flatMap(\.bytes)
    state.enqueue(segments)
    check(state.writes == .pending(remainingBytes: expected.count, awaitingResponse: false),
          "all job segments become pending in one enqueue")
    let enable = state.nextChunk(limit: 180, withResponse: false, useCredits: true)
    let wake = state.nextChunk(limit: 180, withResponse: false, useCredits: true)
    check(enable?.bytes == [0x10, 0xff, 0xf1, 0x03], "activation is its own write without credits")
    check(wake?.bytes == Array(repeating: 0, count: 12), "wake-up is a separate 12-byte write")
    check(state.writes != .drained && state.progress < 1, "prologue cannot signal job drain")
    var sent = (enable?.bytes ?? []) + (wake?.bytes ?? [])
    while let next = state.nextChunk(limit: 180, withResponse: false, useCredits: true) {
        sent += next.bytes
    }
    check(sent == Array(expected.prefix(sent.count)), "bootstrap preserves ordering")
    check(state.queue.first?.bytes.starts(with: [0x1d, 0x76, 0x30]) == true,
          "raster blocks after all credit-free configuration commands")
    state.grantCredits(20)
    while let next = state.nextChunk(limit: 180, withResponse: false, useCredits: true) {
        sent += next.bytes
    }
    check(sent == expected && state.writes == .drained, "credit grant drains entire ordered job")
    check(state.credits == 13, "only seven raster packets consume the twenty credits")
    let bands = RasterEncoder.bandedRasterCommands(for: try bitmap(rows: 25))
    check(bands.count == 2 && bands[0].count == 1160 && bands[1].count == 56,
          "builder retains 24-line bands and one-row remainder")
}

private func checkNotifications() {
    var state = BLETransportState()
    state.enqueue([PrintSegment(name: "Rejected", bytes: [0x1b, 0x40])])
    check(state.writes == .failed(.notReady) && state.queue.isEmpty, "unready sends are rejected, not replayed")
    state.reset(connection: .connecting, writes: .idle)
    state.discovering()
    state.subscribe(to: ["FF01", "FF03"])
    state.notification("FF03", enabled: true)
    check(state.connection == .subscribing, "FF03 alone is not readiness")
    state.notification("unrelated", enabled: true)
    check(state.connection == .subscribing, "unrelated notification cannot satisfy readiness")
    state.notification("FF01", enabled: false, error: "subscription denied")
    let failure = BLETransportError.notificationFailed(characteristic: "FF01", message: "subscription denied")
    check(state.connection == .failed(failure) && state.writes == .failed(failure),
          "notification error is a typed terminal failure")
    state.notification("FF01", enabled: true)
    check(state.connection == .failed(failure), "late subscription success cannot revive failure")

    state = readyState()
    state.enqueue([PrintSegment(name: "Queued", bytes: [0x1b, 0x40])])
    state.notification("FF03", enabled: false)
    check(state.queue.isEmpty && state.connection != .ready, "lost required subscription cancels pending writes")
    state = BLETransportState()
    state.subscribe(to: ["FF01", "FF03"])
    state.notification("FF01", enabled: true)
    check(state.connection == .subscribing, "FF01 alone is not readiness")
    state.notification("FF03", enabled: true)
    check(state.connection == .ready, "both subscription confirmations establish readiness")
}

private func checkResponseDrainAndCancellation() throws {
    var state = readyState()
    state.enqueue([PrintSegment(name: "Battery", bytes: LuckPrinter.battery)])
    let oldGeneration = state.generation
    _ = state.nextChunk(limit: 180, withResponse: true, useCredits: true)
    let oldResponse = state.responses.first
    check(state.writes == .pending(remainingBytes: 0, awaitingResponse: true),
          "last with-response submission remains pending until callback")
    state.enqueue([PrintSegment(name: "Raster", bytes: try raster(rows: 1))])
    state.grantCredits(3)
    check(state.nextChunk(limit: 180, withResponse: true, useCredits: true) == nil,
          "credits do not bypass a pending with-response callback")
    state.waitingForDelay = true
    state.watchdogArmed = true
    state.reset(connection: .disconnecting, writes: .cancelled)
    check(state.queue.isEmpty && state.responses.isEmpty && state.credits == 0,
          "disconnect clears queued bytes, pending command contexts, and credits")
    check(!state.awaitingResponse && !state.waitingForDelay && !state.watchdogArmed,
          "disconnect clears all write waits and timer flags")
    check(state.writes == .cancelled, "cancellation is not successful drain")
    state.subscribe(to: ["FF01", "FF03"])
    state.notification("FF01", enabled: true)
    state.notification("FF03", enabled: true)
    check(state.nextChunk(limit: 180, withResponse: false, useCredits: true) == nil,
          "reconnect cannot replay a cancelled raster")
    state.enqueue([PrintSegment(name: "New battery", bytes: LuckPrinter.battery)])
    _ = state.nextChunk(limit: 180, withResponse: true, useCredits: true)
    let current = state.generation
    state.completeResponse(generation: oldGeneration)
    check(state.awaitingResponse, "stale callback cannot complete a new write")
    state.waitingForDelay = true
    check(!state.resume(generation: oldGeneration) && state.waitingForDelay,
          "stale delay cannot advance a new connection")
    if let oldResponse {
        check(state.expireResponse(id: oldResponse.id, generation: oldGeneration) == nil
              && state.responses.count == 1, "stale timeout cannot remove a new response context")
    } else {
        check(false, "battery command must track response context")
    }
    _ = state.resume(generation: current)
    state.completeResponse(generation: current)
    check(state.writes == .drained, "with-response drain follows successful callback")
    state.enqueue([PrintSegment(name: "Failure", bytes: try raster(rows: 1))])
    state.grantCredits(1)
    _ = state.nextChunk(limit: 20, withResponse: true, useCredits: true)
    state.completeResponse(generation: current, error: "ATT rejected")
    check(state.writes == .failed(.writeFailed("ATT rejected")) && state.queue.isEmpty,
          "write error cancels remaining chunks and is never drain")
}

private func checkRepliesAreNotCompletion() {
    var state = readyState()
    state.enqueue([PrintSegment(name: "Arbitrary label", bytes: LuckPrinter.status)])
    _ = state.nextChunk(limit: 180, withResponse: true, useCredits: true)
    check(state.resolveResponse([0x01, 0x04]) == nil, "credits do not consume command contexts")
    check(state.resolveResponse([0xaa, 0x0d, 0x0a]) == nil, "service noise does not consume command contexts")
    check(state.writes == .pending(remainingBytes: 0, awaitingResponse: true),
          "credits and service noise are not job completion acknowledgements")
    let response = state.resolveResponse([0x04])
    check(response?.context == "paper", "paper context derives from command bytes, not localized labels")
    check(ResponseDecoder.printerStatus([0x04], isPaperResponse: response?.context == "paper")?.raw == 0x04,
          "solicited paper status populates typed raw status")
    check(ResponseDecoder.printerStatus([0x00], isPaperResponse: true)?.raw == 0,
          "solicited zero paper status remains valid")
    for bytes: [UInt8] in [[0x01, 0x00], [0x01, 0x04], [0xaa, 0x0d, 0x0a], [0x02, 0x64, 0x00], []] {
        check(ResponseDecoder.printerStatus(bytes, isPaperResponse: true) == nil, "non-status frame stays unknown")
    }
    check(ResponseDecoder.printerStatus([0x00], isPaperResponse: false) == nil,
          "unsolicited byte is not attributed to paper")
    check(!ResponseDecoder.looksLikeSolicitedResponse([0xaa, 0x0d, 0x0a], context: "battery"),
          "service noise cannot become battery 13 percent")
    check(ResponseDecoder.decode([0xaa, 0x0d, 0x0a], context: "battery").isEmpty,
          "service noise is not decoded as battery")
}

try checkRasterCredits()
try checkAtomicJobAndActivation()
checkNotifications()
try checkResponseDrainAndCancellation()
checkRepliesAreNotCompletion()
if failures > 0 {
    print("\(failures) BLE transport check(s) failed")
    exit(1)
}
print("\(checks) BLE transport checks passed")
