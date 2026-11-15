#!/bin/sh
# Compile the unchanged adapter against inert Bluetooth doubles and real Combine.
set -eu
root="$(cd "$(dirname "$0")/../../.." && pwd)"
mkdir -p "$root/.build"
scratch="$(mktemp -d "$root/.build/ble-adapter-checks.XXXXXX")"
trap 'rm -f "$scratch/CoreBluetooth.swiftmodule" "$scratch/CoreBluetooth.swiftdoc" "$scratch/CoreBluetooth.swiftsourceinfo" "$scratch/CoreBluetooth.abi.json" "$scratch/libCoreBluetooth.dylib" "$scratch/PocketPrinter5890Kit.swiftmodule" "$scratch/PocketPrinter5890Kit.swiftdoc" "$scratch/PocketPrinter5890Kit.swiftsourceinfo" "$scratch/PocketPrinter5890Kit.abi.json" "$scratch/libPocketPrinter5890Kit.dylib" "$scratch/checks"; rmdir "$scratch"' EXIT
swiftc -swift-version 5 -emit-module -emit-library -module-name CoreBluetooth \
    "$root/swift/Tests/AdapterChecks/CoreBluetooth.swift" \
    -emit-module-path "$scratch/CoreBluetooth.swiftmodule" -o "$scratch/libCoreBluetooth.dylib"
swiftc -swift-version 5 -emit-module -emit-library -module-name PocketPrinter5890Kit \
    "$root"/swift/Sources/PocketPrinter5890Kit/*.swift \
    -emit-module-path "$scratch/PocketPrinter5890Kit.swiftmodule" -o "$scratch/libPocketPrinter5890Kit.dylib"
swiftc -swift-version 5 -parse-as-library -package-name BLEAdapterChecks \
    -I "$scratch" -L "$scratch" -lCoreBluetooth -lPocketPrinter5890Kit \
    -Xlinker -rpath -Xlinker "$scratch" \
    "$root/swift/Sources/PocketPrinter5890BLE/BLEUARTProfile.swift" \
    "$root/swift/Sources/PocketPrinter5890BLE/BLETransportState.swift" \
    "$root/swift/Sources/PocketPrinter5890BLE/PocketPrinterBLETransport.swift" \
    "$root/swift/Tests/AdapterChecks/AdapterChecks.swift" -o "$scratch/checks"
"$scratch/checks"
