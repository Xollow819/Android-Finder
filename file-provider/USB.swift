import CryptoKit
import Foundation
import IOKit

struct USBDevice {
    let identifier: String
    let name: String
    let vendor: UInt16
    let product: UInt16
    let bus: UInt32
    let address: UInt8
    let session: UInt64
}

enum USBScanner {
    static func connectedDevices() throws -> [USBDevice] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)
        guard result == KERN_SUCCESS else {
            throw NSError(domain: NSMachErrorDomain, code: Int(result))
        }
        defer { IOObjectRelease(iterator) }

        var devices: [String: USBDevice] = [:]
        while case let interface = IOIteratorNext(iterator), interface != 0 {
            defer { IOObjectRelease(interface) }
            let interfaceNames = ["kUSBString", "USB Interface Name"].compactMap {
                property(interface, $0) as? String
            }
            let advertisedMTP = interfaceNames.contains {
                $0.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("MTP")
            }
            var device: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(interface, kIOServicePlane, &device) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(device) }

            guard let vendor = (property(device, "idVendor") as? NSNumber)?.uint16Value,
                  let product = (property(device, "idProduct") as? NSNumber)?.uint16Value,
                  let location = (property(device, "locationID") as? NSNumber)?.uint32Value,
                  let address = (property(device, "USB Address") as? NSNumber)?.uint8Value else { continue }
            let interfaceClass = property(interface, "bInterfaceClass") as? Int
            // Product ID used by the Vivo V19 in File transfer mode.
            let knownMTP = vendor == 0x2d95 && product == 0x6003 &&
                (interfaceClass == 6 || interfaceClass == 255)
            guard advertisedMTP || knownMTP else { continue }

            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(device, &registryID) == KERN_SUCCESS else { continue }
            let serial = property(device, "USB Serial Number") as? String
                ?? property(device, "kUSBSerialNumberString") as? String
            let identity = "\(vendor):\(product):\(serial ?? String(location))"
            let digest = SHA256.hash(data: Data(identity.utf8)).prefix(16)
            let identifier = "mtp-write-" + digest.map { String(format: "%02x", $0) }.joined()
            let productName = (property(device, "USB Product Name") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let safeName = productName.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == ":" ? "_" : String($0)
            }.joined()
            let name = safeName.isEmpty || safeName == "." || safeName == ".." ? "Android Device" : String(safeName.prefix(100))
            devices[identifier] = USBDevice(identifier: identifier, name: name, vendor: vendor,
                                            product: product, bus: location >> 24, address: address, session: registryID)
        }
        return Array(devices.values)
    }

    private static func property(_ service: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
