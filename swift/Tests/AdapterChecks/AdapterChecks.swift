import Combine
import CoreBluetooth
import Foundation
import PocketPrinter5890Kit

@MainActor
private struct Fixture {
    let transport = PocketPrinter5890BLE(fileLoggingEnabled: false)
    let peripheral = CBPeripheral()
    let rx = CBCharacteristic("FF02", properties: [.write, .writeWithoutResponse])
    let tx = CBCharacteristic("FF01", properties: [.notify])
    let flow = CBCharacteristic("FF03", properties: [.notify])
    let central: CBCentralManager
    let service: CBService
    let device: PrinterDevice

    init() {
        central = CBCentralManager.latest!
        service = CBService("FF00", characteristics: [rx, tx, flow])
        peripheral.services = [service]
        device = PrinterDevice(id: peripheral.identifier, name: "Test", rssi: -40, isLikelyL13: true)
        transport.centralManagerDidUpdateState(central)
        transport.startScan()
        transport.centralManager(central, didDiscover: peripheral, advertisementData: [:], rssi: -40)
    }

    func discover() {
        transport.connect(to: device)
        transport.centralManager(central, didConnect: peripheral)
        transport.peripheral(peripheral, didDiscoverServices: nil)
        transport.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
    }

    func ready() {
        discover()
        tx.isNotifying = true
        transport.peripheral(peripheral, didUpdateNotificationStateFor: tx, error: nil)
        flow.isNotifying = true
        transport.peripheral(peripheral, didUpdateNotificationStateFor: flow, error: nil)
    }

    func finish() {
        transport.disconnect()
        transport.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
    }
}

@main
private struct AdapterChecks {
    @MainActor static func main() throws {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(message)") }
        }

        do {
            let f = Fixture()
            let subscription = f.transport.$connectionState.sink {
                if $0 == .connecting { f.transport.disconnect() }
            }
            f.transport.connect(to: f.device)
            check(f.central.connects == 1 && f.central.cancellations == 1,
                  "synchronous cancellation owns and cancels the connecting peripheral")
            check(f.transport.connectionState == .disconnecting, "connecting cancellation is observable")
            f.finish()
            check(f.transport.connectionState == .disconnected, "cancelled connect reaches disconnected")
            withExtendedLifetime(subscription) {}
        }
        do {
            let f = Fixture()
            let subscription = f.transport.$selectedRX.sink {
                if $0 == "FF02" { f.transport.disconnect() }
            }
            f.discover()
            check(f.peripheral.subscriptions.isEmpty, "cancelled discovery cannot subscribe")
            check(f.transport.connectionState == .disconnecting, "discovery cannot overwrite cancellation")
            f.finish()
            check(f.transport.connectionState == .disconnected, "cancelled discovery reaches disconnected")
            withExtendedLifetime(subscription) {}
        }
        do {
            let f = Fixture()
            let subscription = f.transport.$connectionState.sink {
                if $0 == .discovering { f.transport.disconnect() }
            }
            f.discover()
            check(f.peripheral.serviceDiscoveries == 0, "cancelled didConnect cannot discover services")
            f.finish()
            withExtendedLifetime(subscription) {}
        }
        do {
            let f = Fixture()
            f.ready()
            f.transport.preferWriteWithResponse = true
            f.transport.send(LuckPrinter.stopPrintJob, label: "With response")
            check(f.transport.writeState == .pending(remainingBytes: 0, awaitingResponse: true),
                  "adapter publishes final with-response wait immediately")
            check(f.transport.sendProgress == 1, "submitted bytes publish before response")
            f.transport.peripheral(f.peripheral, didWriteValueFor: f.rx, error: nil)
            check(f.transport.writeState == .drained, "successful callback publishes drain")
            f.finish()
        }
        do {
            let f = Fixture()
            f.discover()
            f.tx.isNotifying = true
            f.transport.peripheral(f.peripheral, didUpdateNotificationStateFor: f.tx, error: nil)
            check(f.transport.connectionState == .subscribing && !f.transport.isConnected,
                  "adapter waits for both notifications")
            f.flow.isNotifying = true
            f.transport.peripheral(f.peripheral, didUpdateNotificationStateFor: f.flow, error: nil)
            let bitmap = try MonochromeBitmap(height: 1, bytes: Array(repeating: 0x55, count: 48))
            let raster = RasterEncoder.rasterCommand(for: bitmap)
            let before = f.peripheral.writes.count
            f.transport.send(raster, label: "One row")
            check(f.peripheral.writes.count == before, "adapter blocks one-row raster without credits")
            f.flow.value = Data([0x01, 0x01])
            f.transport.peripheral(f.peripheral, didUpdateValueFor: f.flow, error: nil)
            check(f.peripheral.writes.last == Data(raster) && f.transport.writeState == .drained,
                  "adapter resumes one-row raster on notification")
            check(f.transport.printerStatus == nil, "adapter does not decode credit as paper status")
            f.transport.send(LuckPrinter.status, label: "Status in any language")
            f.tx.value = Data([0x04])
            f.transport.peripheral(f.peripheral, didUpdateValueFor: f.tx, error: nil)
            check(f.transport.printerStatus?.raw == 0x04, "adapter publishes solicited typed paper status")
            f.finish()
        }
        do {
            let f = Fixture()
            f.ready()
            let before = f.peripheral.writes.count
            let subscription = f.transport.$log.sink {
                if $0.last?.label == "Cancel before submit" { f.transport.disconnect() }
            }
            f.transport.send(LuckPrinter.stopPrintJob, label: "Cancel before submit")
            check(f.peripheral.writes.count == before, "synchronous log observer cancellation prevents submission")
            check(f.transport.writeState == .cancelled, "cancelled submission never publishes drain")
            f.finish()
            withExtendedLifetime(subscription) {}
        }
        if failures > 0 { exit(1) }
        print("\(checks) BLE adapter checks passed (inert CoreBluetooth doubles, real Combine)")
    }
}
