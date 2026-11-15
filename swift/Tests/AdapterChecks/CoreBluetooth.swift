// Minimal inert test doubles. This module never loads Apple's CoreBluetooth.
import Foundation

public let CBCentralManagerScanOptionAllowDuplicatesKey = "allowDuplicates"
public let CBAdvertisementDataLocalNameKey = "localName"
public let CBAdvertisementDataServiceUUIDsKey = "serviceUUIDs"
public enum CBManagerState { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public enum CBCharacteristicWriteType { case withResponse, withoutResponse }
public protocol CBCentralManagerDelegate: AnyObject {}
public protocol CBPeripheralDelegate: AnyObject {}

public final class CBUUID: NSObject {
    public let uuidString: String
    public init(string: String) { uuidString = string.uppercased() }
    public override var hash: Int { uuidString.hashValue }
    public override func isEqual(_ object: Any?) -> Bool {
        (object as? CBUUID)?.uuidString == uuidString
    }
}

public struct CBCharacteristicProperties: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let write = Self(rawValue: 1)
    public static let writeWithoutResponse = Self(rawValue: 2)
    public static let notify = Self(rawValue: 4)
    public static let indicate = Self(rawValue: 8)
}

public final class CBCharacteristic: NSObject {
    public let uuid: CBUUID
    public let properties: CBCharacteristicProperties
    public var value: Data?
    public var isNotifying = false
    public init(_ uuid: String, properties: CBCharacteristicProperties) {
        self.uuid = CBUUID(string: uuid)
        self.properties = properties
    }
}

public final class CBService: NSObject {
    public let uuid: CBUUID
    public var characteristics: [CBCharacteristic]?
    public init(_ uuid: String, characteristics: [CBCharacteristic]) {
        self.uuid = CBUUID(string: uuid)
        self.characteristics = characteristics
    }
}

public final class CBPeripheral: NSObject {
    public let identifier = UUID()
    public var name: String? = "Test printer"
    public weak var delegate: CBPeripheralDelegate?
    public var services: [CBService]?
    public var canSendWriteWithoutResponse = true
    public var writes: [Data] = []
    public var subscriptions: [CBCharacteristic] = []
    public var serviceDiscoveries = 0
    public var characteristicDiscoveries = 0
    public func discoverServices(_ uuids: [CBUUID]?) { serviceDiscoveries += 1 }
    public func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService) {
        characteristicDiscoveries += 1
    }
    public func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        subscriptions.append(characteristic)
    }
    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 180 }
    public func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append(data)
    }
}

public final class CBCentralManager: NSObject {
    public static var latest: CBCentralManager?
    public var state = CBManagerState.poweredOn
    public var connects = 0
    public var cancellations = 0
    public init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?) {
        super.init()
        Self.latest = self
    }
    public func scanForPeripherals(withServices: [CBUUID]?, options: [String: Any]?) {}
    public func stopScan() {}
    public func connect(_ peripheral: CBPeripheral) { connects += 1 }
    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancellations += 1 }
}
