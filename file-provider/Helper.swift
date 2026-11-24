import Darwin
import FileProvider
import Foundation
import OSLog

@main
struct AndroidFinderHelper {
    private static let logger = Logger(subsystem: "local.androidfinder.provider", category: "helper")

    static func main() async {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "--remove-domains":
                for domain in try await NSFileProviderManager.domains() {
                    if let saved = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData) {
                        print("Preserved unsynced files: \(saved.path)")
                    }
                }
            case "--scan":
                for device in try USBScanner.connectedDevices() {
                    print(device.name)
                }
            case "--check-storage":
                for device in try USBScanner.connectedDevices() {
                    let availability = await checkStorage(device)
                    print("\(device.name): \(availability.rawValue)")
                }
            case "--status":
                for domain in try await NSFileProviderManager.domains() {
                    guard let manager = NSFileProviderManager(for: domain) else { continue }
                    let url = try await manager.getUserVisibleURL(for: .rootContainer)
                    print("\(domain.displayName) — \(url.path)")
                }
            case "--refresh-once":
                try await refresh()
            case nil:
                return
            case "--agent":
                var lastError: String?
                while !Task.isCancelled {
                    do {
                        try await refresh()
                        lastError = nil
                    } catch {
                        let message = String(reflecting: error)
                        if message != lastError {
                            logger.error("File Provider refresh failed: \(message, privacy: .public)")
                            lastError = message
                        }
                    }
                    try await Task.sleep(for: .seconds(3))
                }
            default:
                throw CocoaError(.featureUnsupported)
            }
        } catch {
            FileHandle.standardError.write(Data("\(String(reflecting: error))\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func refresh() async throws {
        let attached = try USBScanner.connectedDevices()
        let deviceNames = Dictionary(uniqueKeysWithValues: attached.map { ($0.identifier, $0.name) })
        var availability: [String: StorageAvailability] = [:]
        for device in attached {
            availability[device.identifier] = await checkStorage(device)
        }

        let existing = try await NSFileProviderManager.domains()
        var kept: Set<String> = []
        for domain in existing where domain.identifier.rawValue.hasPrefix("mtp-") || domain.identifier.rawValue.hasPrefix("usb-") {
            let identifier = domain.identifier.rawValue
            switch availability[identifier] {
            case .some(.available):
                // Re-adding the same identifier updates its name without dropping cached files.
                if domain.displayName == deviceNames[identifier] {
                    kept.insert(identifier)
                }
            case .some(.indeterminate):
                kept.insert(identifier)
            case .some(.unavailable), .none:
                _ = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
            }
        }
        for device in attached where availability[device.identifier] == .available && !kept.contains(device.identifier) {
            try await NSFileProviderManager.add(
                NSFileProviderDomain(identifier: .init(rawValue: device.identifier), displayName: device.name)
            )
        }
    }

    private static func checkStorage(_ device: USBDevice) async -> StorageAvailability {
        await withCheckedContinuation { continuation in
            DeviceStorage(identifier: device.identifier).run({ try $0.availability() }) { result in
                continuation.resume(returning: (try? result.get()) ?? .indeterminate)
            }
        }
    }
}
