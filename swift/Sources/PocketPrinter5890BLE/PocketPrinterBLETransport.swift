import Combine
import CoreBluetooth
import Foundation
import PocketPrinter5890Kit

public struct PrinterDevice: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let isLikelyL13: Bool

    public init(id: UUID, name: String, rssi: Int, isLikelyL13: Bool) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.isLikelyL13 = isLikelyL13
    }
}

public struct HexLogEntry: Identifiable, Equatable {
    public enum Direction: String {
        case tx = "TX"
        case rx = "RX"
        case info = "INFO"
        case error = "ERR"
    }

    public let id = UUID()
    public let date = Date()
    public let direction: Direction
    public let label: String
    public let hex: String
    public let decoded: String

    public init(direction: Direction, label: String, bytes: [UInt8], decoded: String = "") {
        self.direction = direction
        self.label = label
        self.hex = Hex.encode(bytes)
        self.decoded = decoded
    }

    public init(direction: Direction, label: String, message: String) {
        self.direction = direction
        self.label = label
        self.hex = message
        self.decoded = ""
    }

    public var line: String {
        let decodedSuffix = decoded.isEmpty ? "" : "  \(decoded)"
        return "\(Self.dateFormatter.string(from: date)) \(direction.rawValue) \(label): \(hex)\(decodedSuffix)"
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

@MainActor
public final class PocketPrinter5890BLE: NSObject, ObservableObject {
    public let logFileURL: URL
    public let fileLoggingEnabled: Bool
    private var central: CBCentralManager?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    // Do not reuse a peripheral until CoreBluetooth finishes its old connection.
    private var disconnectingPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var activeProfile: BLEUARTProfile?
    private var transportState = BLETransportState()
    private var notifyCharacteristics: [CBCharacteristic] = []
    private var isPublishingState = false
    private var isDrainingWrites = false

    @Published public private(set) var devices: [PrinterDevice] = []
    @Published public private(set) var stateText = "Bluetooth non initialise"
    @Published public private(set) var isScanning = false
    @Published public private(set) var isConnected = false
    /// Ready only after every required notification subscription is confirmed.
    @Published public private(set) var connectionState: BLEConnectionState = .disconnected
    /// Local queue state, never an acknowledgement of physical printing.
    @Published public private(set) var writeState: BLEWriteState = .idle
    @Published public private(set) var selectedService = "-"
    @Published public private(set) var selectedRX = "-"
    @Published public private(set) var selectedTX = "-"
    @Published public private(set) var selectedNotify = "-"
    @Published public private(set) var log: [HexLogEntry] = []
    /// Delai fixe entre paquets. Inutile quand le controle de flux par
    /// credits est actif: l'imprimante dit elle-meme quand elle peut recevoir.
    @Published public var interPacketDelay: TimeInterval = 0
    /// Taille de paquet. L'application officielle negocie un MTU jusqu'a 512
    /// octets; 20 octets etait la valeur minimale du BLE et rendait
    /// l'impression extremement lente.
    @Published public var maxChunkSize = 180
    /// Utilise les trames `01 nn` comme credits de flux.
    @Published public var useCreditFlowControl = true
    @Published public var showOnlyLikelyPrinters = true
    @Published public var preferWriteWithResponse = false
    @Published public var preferredProfileID = PrinterBLEProfiles.automaticID
    /// Fraction submitted to CoreBluetooth. Use writeState, not this, to await drain.
    @Published public private(set) var sendProgress: Double = 1
    /// Niveau de batterie en pourcentage, nil tant qu'il n'a pas ete lu.
    @Published public private(set) var batteryPercent: Int?
    /// Dernier etat papier/capot connu.
    @Published public private(set) var printerStatus: PrinterStatus?
    /// Modele et firmware annonces par l'imprimante.
    @Published public private(set) var deviceModel: String?
    @Published public private(set) var deviceFirmware: String?

    private var batteryTimer: Timer?

    public override convenience init() {
        self.init(fileLoggingEnabled: true)
    }

    /// Disabling file logging retains the in-memory log without creating or
    /// appending to ble.log. Existing log files are not removed.
    public init(fileLoggingEnabled: Bool) {
        self.fileLoggingEnabled = fileLoggingEnabled
        logFileURL = Self.makeLogFileURL()
        super.init()
        if fileLoggingEnabled { prepareLogFile() }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    public func startScan() {
        guard central?.state == .poweredOn else {
            stateText = "Activez Bluetooth pour rechercher l'imprimante"
            return
        }
        devices.removeAll()
        discoveredPeripherals.removeAll()
        isScanning = true
        stateText = "Recherche BLE non filtree..."
        central?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    public func stopScan() {
        central?.stopScan()
        isScanning = false
    }

    public func connect(to device: PrinterDevice) {
        guard connectedPeripheral == nil, disconnectingPeripheral == nil else {
            recordLocalError("Disconnect the current peripheral before connecting again")
            return
        }
        guard let peripheral = discoveredPeripherals[device.id] else { return }
        stopScan()
        guard connectedPeripheral == nil, disconnectingPeripheral == nil else { return }
        resetConnectionState("Connexion a \(device.name)...", connection: .connecting,
                             writes: .idle, connecting: peripheral)
    }

    public func disconnect() {
        guard connectedPeripheral != nil else { return }
        resetConnectionState("Deconnexion...", connection: .disconnecting, writes: .cancelled)
    }

    /// Enqueue a complete command (or the builder's complete raster segment).
    /// Do not flatten activation and wake-up into the same byte array.
    public func send(_ bytes: [UInt8], label: String) {
        send([PrintSegment(name: label, bytes: bytes)])
    }

    /// Reprise de securite de la file d'ecriture.
    ///
    /// Elle couvre le cas ou le buffer BLE est plein et ou CoreBluetooth ne
    /// declenche pas `peripheralIsReady(toSendWriteWithoutResponse:)`.
    private func scheduleQueueWatchdog() {
        guard !transportState.watchdogArmed else { return }
        transportState.watchdogArmed = true
        let generation = transportState.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.transportState.generation == generation else { return }
            self.transportState.watchdogArmed = false
            if !self.transportState.queue.isEmpty {
                self.drainWriteQueue()
            }
        }
    }

    /// Met a jour l'etat publie a partir d'une trame recue.
    ///
    /// La batterie arrive sous deux formes selon le moment:
    /// - `02 64 00` emis spontanement sur FF03 a la connexion;
    /// - `00 62` en reponse a `10 FF 50 F1` sur FF01.
    ///
    /// Dans les deux cas le pourcentage est le **deuxieme** octet, ce que fait
    /// aussi le SDK officiel (`lambda$getBatteryLuck$6` lit `bArr[1]` sans
    /// tester le premier octet).
    private func updatePrinterState(with bytes: [UInt8], context: String?) {
        if bytes == [0xaa, 0x0d, 0x0a] { return }
        // Un credit de flux `01 nn` n'est jamais une donnee: il est emis en
        // continu et son second octet serait pris pour un pourcentage.
        if bytes.count == 2, bytes[0] == 0x01 { return }

        if let status = ResponseDecoder.printerStatus(bytes, isPaperResponse: context == "paper") {
            printerStatus = status
            stateText = "Capteur papier: \(status.description)"
            return
        }
        // Deux formes de trame batterie, toutes deux longues de 2 ou 3 octets
        // avec le pourcentage en deuxieme position:
        //   `02 64 00` emis spontanement a la connexion,
        //   `00 62`    en reponse a `10 FF 50 F1`.
        // On ne se fie pas au contexte: la reponse arrive sur FF01 apres un
        // credit, et le contexte peut deja avoir ete resolu.
        let looksLikeBattery = (bytes.count == 3 && bytes[0] == 0x02)
            || (bytes.count == 2 && bytes[0] == 0x00)
        if looksLikeBattery {
            let value = Int(bytes[1])
            if value <= 100 {
                batteryPercent = value
                return
            }
        }

        // Reponse texte a une demande de modele ou de firmware.
        if bytes.count >= 3,
           let text = String(bytes: bytes.filter { $0 >= 0x20 && $0 <= 0x7e }, encoding: .ascii),
           !text.isEmpty {
            if text.hasPrefix("V"), text.contains(".") {
                deviceFirmware = text
            } else if deviceModel == nil, text.count <= 12, text.allSatisfy({ $0.isLetter || $0.isNumber }) {
                deviceModel = text
            }
        }
    }

    /// Interroge la batterie periodiquement, comme le `BatteryLoader` de
    /// l'application officielle qui utilise une periode de 25 secondes.
    private func startBatteryPolling() {
        stopBatteryPolling()
        guard transportState.connection == .ready else { return }
        readBattery()
        let generation = transportState.generation
        let timer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.transportState.generation == generation else { return }
                self.readBattery()
            }
        }
        batteryTimer = timer
    }

    private func stopBatteryPolling() {
        batteryTimer?.invalidate()
        batteryTimer = nil
    }

    /// Demande le niveau de batterie sans polluer la file d'impression.
    public func readBattery() {
        guard isConnected, transportState.queue.isEmpty, !transportState.awaitingResponse else { return }
        send(LuckPrinter.battery, label: "Lire batterie")
    }

    private func publishState() {
        // Combine delivers synchronously. A subscriber may enqueue or cancel;
        // finish publishing that new state without recursively publishing ready.
        guard !isPublishingState else { return }
        isPublishingState = true
        defer { isPublishingState = false }
        repeat {
            if isConnected != (transportState.connection == .ready) {
                isConnected = transportState.connection == .ready
            }
            if connectionState != transportState.connection { connectionState = transportState.connection }
            if writeState != transportState.writes { writeState = transportState.writes }
            if sendProgress != transportState.progress { sendProgress = transportState.progress }
        } while isConnected != (transportState.connection == .ready)
            || connectionState != transportState.connection || writeState != transportState.writes
            || sendProgress != transportState.progress
    }

    /// Atomically enqueue all segments before any write or pending/drained event.
    /// Call only when connectionState is .ready; rejection sets .failed(.notReady).
    public func send(_ segments: [PrintSegment]) {
        transportState.enqueue(segments)
        if case let .failed(error) = transportState.writes {
            appendLog(HexLogEntry(direction: .error, label: "Ecriture", message: "\(error)"))
        }
        publishState()
        drainWriteQueue()
    }

    public func readDeviceInformation() {
        send(PrinterCommand.model, label: "Lire modele")
        send(PrinterCommand.firmware, label: "Lire firmware")
        send(PrinterCommand.battery, label: "Lire batterie")
        send(PrinterCommand.paperStatus, label: "Lire papier")
    }

    public func recordLocalError(_ message: String) {
        appendLog(HexLogEntry(direction: .error, label: "Application", message: message))
    }

    private func drainWriteQueue() {
        guard !isDrainingWrites, transportState.connection == .ready,
              let peripheral = connectedPeripheral, let characteristic = rxCharacteristic,
              !transportState.awaitingResponse, !transportState.waitingForDelay,
              !transportState.queue.isEmpty else { return }
        isDrainingWrites = true
        defer { isDrainingWrites = false }

        let canWriteWithResponse = characteristic.properties.contains(.write)
        let writeType: CBCharacteristicWriteType = preferWriteWithResponse && canWriteWithResponse
            ? .withResponse
            : (characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        if writeType == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
            // CoreBluetooth ne rappelle `peripheralIsReady(toSendWriteWithoutResponse:)`
            // de maniere fiable que lorsqu'une ecriture a reellement sature le buffer.
            // En sortant ici sans replanifier, la file restait bloquee definitivement
            // et le raster partait tronque (ex. 20 octets envoyes sur 2168 annonces).
            // On arme donc une reprise de securite.
            scheduleQueueWatchdog()
            return
        }

        let mtu = peripheral.maximumWriteValueLength(for: writeType)
        let chunkSize = max(1, min(mtu, maxChunkSize))
        let previousResponse = transportState.responses.last?.id
        guard let chunk = transportState.nextChunk(
            limit: chunkSize, withResponse: writeType == .withResponse, useCredits: useCreditFlowControl
        ) else { return } // A credit notification resumes a credit-starved queue.
        let generation = transportState.generation
        if let response = transportState.responses.last, response.id != previousResponse {
            scheduleResponseTimeout(response, generation: generation)
        }

        appendLog(HexLogEntry(direction: .tx, label: chunk.label, bytes: chunk.bytes))
        guard transportState.generation == generation else { return }
        peripheral.writeValue(Data(chunk.bytes), for: characteristic, type: writeType)

        if writeType == .withoutResponse {
            if interPacketDelay <= 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.transportState.generation == generation else { return }
                    self.drainWriteQueue()
                }
            } else {
                transportState.waitingForDelay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + interPacketDelay) { [weak self] in
                    guard let self, self.transportState.resume(generation: generation) else { return }
                    self.drainWriteQueue()
                }
            }
        }
        publishState()
    }

    private func resetConnectionState(
        _ text: String, connection: BLEConnectionState = .disconnected,
        writes: BLEWriteState = .cancelled, connecting: CBPeripheral? = nil
    ) {
        stopBatteryPolling()
        if let peripheral = connectedPeripheral {
            disconnectingPeripheral = peripheral
            connectedPeripheral = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        transportState.reset(connection: connection, writes: writes)
        if let peripheral = connecting {
            // Own and initiate the connection before any synchronous observer
            // can cancel the published .connecting transition.
            connectedPeripheral = peripheral
            peripheral.delegate = self
            central?.connect(peripheral)
        }
        batteryPercent = nil
        printerStatus = nil
        deviceModel = nil
        deviceFirmware = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        activeProfile = nil
        notifyCharacteristics.removeAll()
        selectedService = "-"
        selectedRX = "-"
        selectedTX = "-"
        selectedNotify = "-"
        stateText = text
        publishState()
    }

    private func fail(_ error: BLETransportError) {
        appendLog(HexLogEntry(direction: .error, label: "BLE", message: "\(error)"))
        resetConnectionState("\(error)", connection: .failed(error), writes: .failed(error))
    }

    private func isCurrentConnection(_ peripheral: CBPeripheral, generation: UUID) -> Bool {
        peripheral === connectedPeripheral && transportState.generation == generation
    }

    private static func makeLogFileURL() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("PocketPrinter5890App", isDirectory: true)
            .appendingPathComponent("ble.log")
    }

    private func prepareLogFile() {
        let directory = logFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
    }

    private func appendLog(_ entry: HexLogEntry) {
        log.append(entry)
        guard fileLoggingEnabled else { return }
        guard let data = (entry.line + "\n").data(using: .utf8) else { return }
        // `seekToEnd()` et `write(contentsOf:)` exigent iOS 13.4; leurs
        // equivalents historiques fonctionnent depuis les toutes premieres
        // versions et gardent la librairie compatible avec les vieux
        // appareils.
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }
}

extension PocketPrinter5890BLE: CBCentralManagerDelegate {
    // CBCentralManager is created with queue: nil, so delegate callbacks are
    // already on the main queue. Handle them synchronously rather than letting
    // unstructured Tasks from an old connection run inside a new connection.
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if transportState.connection == .failed(.bluetoothUnavailable) {
                    resetConnectionState("Pret a rechercher", writes: .idle)
                } else {
                    stateText = "Pret a rechercher"
                }
            default:
                isScanning = false
                discoveredPeripherals.removeAll()
                fail(.bluetoothUnavailable)
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard isScanning else { return }
            let name = peripheral.name
                ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
                ?? "BLE \(peripheral.identifier.uuidString.prefix(8))"
            let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let lowercasedName = name.lowercased()
            let hasKnownService = advertisedServices.contains { PrinterBLEProfiles.allServiceUUIDs.contains($0) }
            let hasPrinterName = lowercasedName.contains("printer")
                || lowercasedName.contains("pocket")
                || lowercasedName.contains("l13")
                || lowercasedName.contains("dp-l13")
            let device = PrinterDevice(
                id: peripheral.identifier,
                name: name,
                rssi: RSSI.intValue,
                isLikelyL13: hasKnownService || hasPrinterName
            )
            discoveredPeripherals[peripheral.identifier] = peripheral
            devices.removeAll { $0.id == device.id }
            if !showOnlyLikelyPrinters || device.isLikelyL13 {
                devices.append(device)
            }
            devices.sort { $0.rssi > $1.rssi }
            stateText = "\(devices.count) peripherique(s) trouve(s)"
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === connectedPeripheral, transportState.connection == .connecting else { return }
            let generation = transportState.generation
            transportState.discovering()
            publishState()
            appendLog(HexLogEntry(direction: .info, label: "BLE", message: "Connecte, decouverte des services"))
            stateText = "Decouverte des services..."
            guard isCurrentConnection(peripheral, generation: generation) else { return }
            peripheral.discoverServices(nil)
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if peripheral === disconnectingPeripheral {
                disconnectingPeripheral = nil
                peripheral.delegate = nil
                if transportState.connection == .disconnecting {
                    resetConnectionState("Deconnecte")
                }
                return
            }
            guard peripheral === connectedPeripheral else { return }
            connectedPeripheral = nil
            peripheral.delegate = nil
            fail(.disconnected)
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if peripheral === disconnectingPeripheral {
                disconnectingPeripheral = nil
                peripheral.delegate = nil
                if transportState.connection == .disconnecting {
                    resetConnectionState("Deconnecte")
                }
                return
            }
            guard peripheral === connectedPeripheral else { return }
            connectedPeripheral = nil
            peripheral.delegate = nil
            fail(.connectionFailed(error?.localizedDescription ?? "Connexion impossible"))
        }
    }
}

extension PocketPrinter5890BLE: CBPeripheralDelegate {
    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connectedPeripheral, transportState.connection == .discovering else { return }
            let generation = transportState.generation
            guard error == nil else {
                fail(.discoveryFailed(error?.localizedDescription ?? "Services BLE introuvables"))
                return
            }
            let services = peripheral.services ?? []
            let profileOrder = PrinterBLEProfiles.orderedProfiles(preferredProfileID: preferredProfileID)
            guard let profile = profileOrder.first(where: { wanted in
                services.contains { $0.uuid == wanted.service }
            }) else {
                fail(.discoveryFailed("Aucun UART L13 connu trouve"))
                return
            }
            activeProfile = profile
            selectedService = profile.service.uuidString
            guard let service = services.first(where: { $0.uuid == profile.service }) else { return }
            var characteristics = [profile.rx, profile.tx]
            if let extraNotify = profile.extraNotify {
                characteristics.append(extraNotify)
            }
            guard isCurrentConnection(peripheral, generation: generation) else { return }
            peripheral.discoverCharacteristics(characteristics, for: service)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connectedPeripheral, transportState.connection == .discovering else { return }
            let generation = transportState.generation
            guard error == nil, let profile = activeProfile else {
                fail(.discoveryFailed(error?.localizedDescription ?? "Caracteristiques BLE introuvables"))
                return
            }
            guard service.uuid == profile.service else { return }
            let characteristics = service.characteristics ?? []
            guard let rx = characteristics.first(where: { $0.uuid == profile.rx }),
                  rx.properties.contains(.write) || rx.properties.contains(.writeWithoutResponse) else {
                fail(.discoveryFailed("Caracteristique RX absente ou non inscriptible"))
                return
            }
            let required = Set(([profile.tx] + [profile.extraNotify].compactMap { $0 }).map(\.uuidString))
            notifyCharacteristics = characteristics.filter { required.contains($0.uuid.uuidString) }
            guard Set(notifyCharacteristics.map { $0.uuid.uuidString }) == required,
                  notifyCharacteristics.allSatisfy({
                      $0.properties.contains(.notify) || $0.properties.contains(.indicate)
                  }) else {
                fail(.discoveryFailed("Caracteristique de notification requise absente"))
                return
            }
            rxCharacteristic = rx
            txCharacteristic = characteristics.first { $0.uuid == profile.tx }
            transportState.subscribe(to: required)
            selectedRX = rx.uuid.uuidString
            guard isCurrentConnection(peripheral, generation: generation) else { return }
            selectedTX = profile.tx.uuidString
            guard isCurrentConnection(peripheral, generation: generation) else { return }
            stateText = "Activation des notifications..."
            guard isCurrentConnection(peripheral, generation: generation) else { return }
            for characteristic in notifyCharacteristics {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            publishState()
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connectedPeripheral,
                  notifyCharacteristics.contains(where: { $0 === characteristic }) else { return }
            let wasReady = transportState.connection == .ready
            transportState.notification(characteristic.uuid.uuidString, enabled: characteristic.isNotifying,
                                        error: error?.localizedDescription)
            if case let .failed(failure) = transportState.connection {
                fail(failure)
                return
            }
            appendNotifyUUID(characteristic.uuid)
            if !wasReady, transportState.connection == .ready {
                stateText = "Pret via \(activeProfile?.id ?? "-")"
                publishState()
                startBatteryPolling()
                drainWriteQueue()
            } else {
                publishState()
            }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connectedPeripheral,
                  notifyCharacteristics.contains(where: { $0 === characteristic }) else { return }
            let generation = transportState.generation
            if let error {
                fail(.notificationFailed(characteristic: characteristic.uuid.uuidString,
                                         message: error.localizedDescription))
                return
            }
            let bytes = Array(characteristic.value ?? Data())

            // Controle de flux par credits.
            //
            // Une trame `01 nn` n'est pas un acquittement ni un statut papier:
            // c'est l'imprimante qui annonce pouvoir accepter `nn` paquets
            // supplementaires. L'application officielle attend d'avoir des
            // credits puis envoie plusieurs paquets d'un coup, au lieu de
            // temporiser a l'aveugle.
            if useCreditFlowControl, bytes.count == 2, bytes[0] == 0x01 {
                transportState.grantCredits(bytes[1])
                drainWriteQueue()
            }

            guard isCurrentConnection(peripheral, generation: generation) else { return }
            let response = transportState.resolveResponse(bytes)
            let context = response?.context
            updatePrinterState(with: bytes, context: context)
            let decoded = ResponseDecoder.decode(bytes, context: context)
            let label = response.map { "\($0.label) reponse" } ?? characteristic.uuid.uuidString
            appendLog(HexLogEntry(direction: .rx, label: label, bytes: bytes, decoded: decoded))
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connectedPeripheral, characteristic === rxCharacteristic,
                  transportState.awaitingResponse else { return }
            if let error {
                fail(.writeFailed(error.localizedDescription))
                return
            }
            transportState.completeResponse(generation: transportState.generation)
            publishState()
            drainWriteQueue()
        }
    }

    public nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === connectedPeripheral else { return }
            drainWriteQueue()
        }
    }
}

private extension PocketPrinter5890BLE {
    func appendNotifyUUID(_ uuid: CBUUID) {
        let value = uuid.uuidString
        if selectedNotify == "-" {
            selectedNotify = value
        } else if !selectedNotify.contains(value) {
            selectedNotify += " + \(value)"
        }
    }

    func scheduleResponseTimeout(_ response: BLETransportState.Response, generation: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  self.transportState.expireResponse(id: response.id, generation: generation) != nil else { return }
            self.appendLog(HexLogEntry(
                direction: .info,
                label: "\(response.label) reponse",
                message: "Aucune reponse decodee recue dans 1,5 s"
            ))
        }
    }

}

extension PocketPrinter5890BLE: PrinterTransport {}
