import FileProvider
import Foundation
import UniformTypeIdentifiers

@objc(AndroidFinderProvider)
final class AndroidFinderProvider: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let storage: DeviceStorage

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        storage = DeviceStorage(identifier: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() { storage.invalidate() }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(FinderItem(DeviceEntry(item: .root, parent: .root,
                                                     name: domain.displayName, directory: true)), nil)
        } else {
            storage.run({ try $0.entry(DeviceItem(identifier)) }) { result in
                switch result {
                case .success(let entry): completionHandler(FinderItem(entry), nil)
                case .failure(let error): completionHandler(nil, error)
                }
            }
        }
        return Progress(totalUnitCount: 0)
    }

    func enumerator(for identifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let item: DeviceItem? = identifier == .workingSet || identifier == .trashContainer
            ? nil : try DeviceItem(identifier)
        return FolderEnumerator(item: item, storage: storage)
    }

    func fetchContents(for identifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        do {
            guard let manager = NSFileProviderManager(for: domain) else {
                throw NSFileProviderError(.serverUnreachable)
            }
            let target = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
            storage.run({ try $0.download(DeviceItem(identifier), destination: target, progress: progress) }) { result in
                switch result {
                case .success(let entry): completionHandler(target, FinderItem(entry), nil)
                case .failure(let error):
                    try? FileManager.default.removeItem(at: target)
                    completionHandler(nil, nil, error)
                }
            }
        } catch {
            completionHandler(nil, nil, error)
        }
        return progress
    }

    func createItem(basedOn item: NSFileProviderItem, fields: NSFileProviderItemFields,
                    contents: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        storage.run({ backend in
            let type = item.contentType ?? .data
            guard !type.conforms(to: .symbolicLink), !type.conforms(to: .package) else {
                throw CocoaError(.featureUnsupported)
            }
            return try backend.create(in: DeviceItem(item.parentItemIdentifier), name: item.filename,
                                      directory: type.conforms(to: .folder), source: contents,
                                      mergeFolder: options.contains(.mayAlreadyExist), progress: progress)
        }) { result in
            switch result {
            case .success(let entry): completionHandler(FinderItem(entry), [], false, nil)
            case .failure(let error): completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents: URL?,
                    options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        guard changedFields.contains(.filename),
              changedFields.intersection([.parentItemIdentifier, .contents]).isEmpty else {
            completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission))
            return progress
        }
        storage.run({ backend in
            try backend.rename(DeviceItem(item.itemIdentifier), to: item.filename) { entry in
                let current = FinderItem(entry).itemVersion
                guard current.metadataVersion == baseVersion.metadataVersion else {
                    throw NSFileProviderError(.versionNoLongerAvailable)
                }
            }
        }) { result in
            switch result {
            case .success(let entry): completionHandler(FinderItem(entry), [], false, nil)
            case .failure(let error): completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(CocoaError(.fileWriteNoPermission))
        return Progress(totalUnitCount: 0)
    }
}

private final class FinderItem: NSObject, NSFileProviderItem {
    let entry: DeviceEntry
    var filename: String { entry.name }
    var itemIdentifier: NSFileProviderItemIdentifier { entry.item.identifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier { entry.parent.identifier }
    var contentType: UTType {
        if entry.directory { return .folder }
        let suffix = (entry.name as NSString).pathExtension
        return UTType(filenameExtension: suffix) ?? .data
    }
    var capabilities: NSFileProviderItemCapabilities {
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading]
        if entry.writable {
            if entry.directory { capabilities.insert(.allowsAddingSubItems) }
            if case .object = entry.item { capabilities.insert(.allowsRenaming) }
        }
        return capabilities
    }
    var fileSystemFlags: NSFileProviderFileSystemFlags {
        var flags: NSFileProviderFileSystemFlags = [.userReadable]
        if entry.directory {
            flags.insert(.userExecutable)
            if entry.writable { flags.insert(.userWritable) }
        }
        return flags
    }
    var documentSize: NSNumber? { entry.directory ? nil : NSNumber(value: entry.size) }
    var contentModificationDate: Date? { entry.modifiedAt }
    var itemVersion: NSFileProviderItemVersion {
        let version = Data("\(entry.size):\(entry.modifiedAt?.timeIntervalSince1970 ?? 0)".utf8)
        return NSFileProviderItemVersion(contentVersion: version,
                                         metadataVersion: Data("\(entry.writable):\(entry.name)".utf8) + version)
    }

    init(_ entry: DeviceEntry) {
        self.entry = entry
    }
}

private final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let item: DeviceItem?
    private let storage: DeviceStorage
    private let anchor = NSFileProviderSyncAnchor(Data([2]))

    init(item: DeviceItem?, storage: DeviceStorage) {
        self.item = item
        self.storage = storage
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let item else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        storage.run({ try $0.children(item) }) { result in
            switch result {
            case .success(let entries):
                observer.didEnumerate(entries.map(FinderItem.init))
                observer.finishEnumerating(upTo: nil)
            case .failure(let error):
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from previous: NSFileProviderSyncAnchor) {
        if previous == anchor {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchor)
    }
}
