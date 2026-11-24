import FileProvider
import Foundation

enum DeviceItem: Hashable {
    case root
    case storage(UInt32)
    case object(storage: UInt32, id: UInt32)

    init(_ identifier: NSFileProviderItemIdentifier) throws {
        if identifier == .rootContainer {
            self = .root
            return
        }
        let fields = identifier.rawValue.split(separator: "-")
        if fields.count == 2, fields[0] == "storage", let storage = UInt32(fields[1]) {
            self = .storage(storage)
        } else if fields.count == 3, fields[0] == "object",
                  let storage = UInt32(fields[1]), let id = UInt32(fields[2]) {
            self = .object(storage: storage, id: id)
        } else {
            throw NSFileProviderError(.noSuchItem)
        }
    }

    var identifier: NSFileProviderItemIdentifier {
        switch self {
        case .root: return .rootContainer
        case .storage(let storage): return .init(rawValue: "storage-\(storage)")
        case .object(let storage, let id): return .init(rawValue: "object-\(storage)-\(id)")
        }
    }
}

enum StorageAvailability: String {
    case available
    case unavailable
    case indeterminate
}

struct DeviceEntry {
    let item: DeviceItem
    let parent: DeviceItem
    var name: String
    let directory: Bool
    var size: UInt64 = 0
    var modifiedAt: Date? = nil
    var writable = false
}

// libmtp serializes commands on each USB session. All consumers use this queue,
// including initialization and release of the native handle.
final class DeviceStorage {
    private static let queue = DispatchQueue(label: "local.androidfinder.mtp")
    private static let initialized: Void = LIBMTP_Init()
    private let identifier: String
    private var handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private var generation: UInt64?
    private var invalidated = false
    private var access: [UInt32: Bool] = [:]

    init(identifier: String) {
        self.identifier = identifier
    }

    func invalidate() {
        Self.queue.async {
            self.invalidated = true
            self.close()
        }
    }

    func run<T>(_ operation: @escaping (DeviceStorage) throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        Self.queue.async {
            let result = Result { try operation(self) }
            self.close()
            completion(result)
        }
    }

    private func close() {
        if let handle { LIBMTP_Release_Device(handle) }
        handle = nil
        generation = nil
        access.removeAll()
    }

    // A failed USB claim can simply mean Finder or another app is transferring a file.
    func availability() throws -> StorageAvailability {
        guard let usb = try USBScanner.connectedDevices().first(where: { $0.identifier == identifier }) else {
            return .unavailable
        }
        return withRawDevice(usb) {
            switch ANDROIDFINDER_Probe_Storage($0) {
            case 1: return .available
            case 0: return .unavailable
            default: return .indeterminate
            }
        } ?? .indeterminate
    }

    private func connectedHandle() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard !invalidated, let usb = try USBScanner.connectedDevices().first(where: { $0.identifier == identifier }) else {
            close()
            throw NSFileProviderError(.serverUnreachable)
        }
        if let handle, generation == usb.session {
            LIBMTP_Clear_Errorstack(handle)
            return handle
        }
        close()
        if let opened = withRawDevice(usb, { candidate in
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
                if let opened = LIBMTP_Open_Raw_Device_Uncached(candidate) {
                    return opened
                }
            }
            return nil
        }) ?? nil {
            handle = opened
            generation = usb.session
            return opened
        }
        throw NSFileProviderError(.serverUnreachable)
    }

    private func withRawDevice<T>(_ usb: USBDevice,
                                  _ work: (UnsafeMutablePointer<LIBMTP_raw_device_t>) -> T) -> T? {
        _ = Self.initialized
        var devices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let result = LIBMTP_Detect_Raw_Devices(&devices, &count)
        defer { free(devices) }
        guard result == LIBMTP_ERROR_NONE, let devices else { return nil }
        for index in 0..<Int(count) {
            let candidate = devices.advanced(by: index)
            guard candidate.pointee.bus_location == usb.bus, candidate.pointee.devnum == usb.address,
                  candidate.pointee.device_entry.vendor_id == usb.vendor,
                  candidate.pointee.device_entry.product_id == usb.product else { continue }
            return work(candidate)
        }
        return nil
    }

    private func storageEntries(_ handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) throws -> [DeviceEntry] {
        guard LIBMTP_Get_Storage(handle, LIBMTP_STORAGE_SORTBY_NOTSORTED) == 0 else {
            close()
            throw NSFileProviderError(.serverUnreachable)
        }
        var entries: [DeviceEntry] = []
        access.removeAll(keepingCapacity: true)
        var next = handle.pointee.storage
        while let storage = next?.pointee {
            let writable = storage.AccessCapability == 0
            access[storage.id] = writable
            entries.append(DeviceEntry(item: .storage(storage.id), parent: .root,
                                       name: cleanName(storage.StorageDescription, fallback: "Storage"),
                                       directory: true, writable: writable))
            next = storage.next
        }
        if entries.isEmpty {
            close()
            throw NSFileProviderError(.serverUnreachable)
        }
        return entries
    }

    func entry(_ item: DeviceItem) throws -> DeviceEntry {
        let handle = try connectedHandle()
        switch item {
        case .root:
            return DeviceEntry(item: .root, parent: .root, name: "Android", directory: true)
        case .storage:
            guard let result = try storageEntries(handle).first(where: { $0.item == item }) else {
                throw NSFileProviderError(.noSuchItem)
            }
            return result
        case .object(let storage, let id):
            if access[storage] == nil { _ = try storageEntries(handle) }
            guard let file = LIBMTP_Get_Filemetadata(handle, id) else {
                throw NSFileProviderError(.noSuchItem)
            }
            defer { LIBMTP_destroy_file_t(file) }
            guard file.pointee.storage_id == storage else { throw NSFileProviderError(.noSuchItem) }
            return objectEntry(file.pointee)
        }
    }

    func children(_ item: DeviceItem) throws -> [DeviceEntry] {
        let handle = try connectedHandle()
        let storage: UInt32
        let parent: UInt32
        switch item {
        case .root: return try storageEntries(handle)
        case .storage(let id): (storage, parent) = (id, UInt32.max)
        case .object(let id, let object): (storage, parent) = (id, object)
        }
        if access[storage] == nil { _ = try storageEntries(handle) }
        var files = LIBMTP_Get_Files_And_Folders(handle, storage, parent)
        if files == nil, LIBMTP_Get_Errorstack(handle) != nil {
            close()
            throw NSFileProviderError(.serverUnreachable)
        }
        var entries: [DeviceEntry] = []
        while let file = files {
            entries.append(objectEntry(file.pointee))
            files = file.pointee.next
            LIBMTP_destroy_file_t(file)
        }
        return entries
    }

    func download(_ item: DeviceItem, destination: URL, progress: Progress) throws -> DeviceEntry {
        guard case .object(_, let id) = item else { throw NSFileProviderError(.noSuchItem) }
        let metadata = try entry(item)
        guard !metadata.directory else { throw NSFileProviderError(.noSuchItem) }
        let handle = try connectedHandle()
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }
        let context = Unmanaged.passUnretained(progress).toOpaque()
        let result = LIBMTP_Get_File_To_File_Descriptor(handle, id, fd, { sent, total, pointer in
            guard let pointer else { return 1 }
            let progress = Unmanaged<Progress>.fromOpaque(pointer).takeUnretainedValue()
            if progress.isCancelled { return 1 }
            if total > 0 { progress.completedUnitCount = Int64(min(99, 100 * Double(sent) / Double(total))) }
            return 0
        }, context)
        var info = stat()
        guard result == 0, fstat(fd, &info) == 0, UInt64(info.st_size) == metadata.size else {
            close()
            throw progress.isCancelled ? CocoaError(.userCancelled) : CocoaError(.fileReadUnknown)
        }
        progress.completedUnitCount = 100
        return metadata
    }

    func create(in folder: DeviceItem, name: String, directory: Bool,
                source: URL?, mergeFolder: Bool, progress: Progress) throws -> DeviceEntry {
        try validateName(name)
        let metadata = try entry(folder)
        guard metadata.directory, metadata.writable else { throw CocoaError(.fileWriteNoPermission) }

        if let existing = try children(folder).first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            if mergeFolder, directory, existing.directory {
                progress.completedUnitCount = 100
                return existing
            }
            throw NSFileProviderError(.filenameCollision)
        }

        let storage: UInt32
        let parent: UInt32
        switch folder {
        case .root:
            throw CocoaError(.fileWriteNoPermission)
        case .storage(let id):
            (storage, parent) = (id, UInt32.max)
        case .object(let id, let object):
            (storage, parent) = (id, object)
        }

        guard !progress.isCancelled else { throw CocoaError(.userCancelled) }
        let handle = try connectedHandle()
        if directory {
            var filename = name.utf8CString
            let object = filename.withUnsafeMutableBufferPointer {
                LIBMTP_Create_Folder(handle, $0.baseAddress, parent, storage)
            }
            guard object != 0 else { throw CocoaError(.fileWriteUnknown) }
            progress.completedUnitCount = 100
            let item = DeviceItem.object(storage: storage, id: object)
            if let created = try? entry(item) { return created }
            return DeviceEntry(item: item, parent: folder, name: name, directory: true, writable: true)
        }
        guard let source else { throw CocoaError(.fileReadNoSuchFile) }
        return try upload(source, name: name, to: folder, storage: storage, parent: parent,
                          handle: handle, progress: progress)
    }

    private func upload(_ source: URL, name: String, to folder: DeviceItem, storage: UInt32, parent: UInt32,
                        handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, progress: Progress) throws -> DeviceEntry {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard let file = LIBMTP_new_file_t() else { throw CocoaError(.fileWriteUnknown) }
        defer { LIBMTP_destroy_file_t(file) }
        file.pointee.filename = strdup(name)
        guard file.pointee.filename != nil else { throw CocoaError(.fileWriteUnknown) }
        file.pointee.storage_id = storage
        file.pointee.parent_id = parent
        file.pointee.filesize = UInt64(info.st_size)
        file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        file.pointee.modificationdate = info.st_mtimespec.tv_sec
        let context = Unmanaged.passUnretained(progress).toOpaque()
        let result = LIBMTP_Send_File_From_File_Descriptor(handle, fd, file, { sent, total, pointer in
            guard let pointer else { return 1 }
            let progress = Unmanaged<Progress>.fromOpaque(pointer).takeUnretainedValue()
            if progress.isCancelled { return 1 }
            if total > 0 { progress.completedUnitCount = Int64(min(99, 100 * Double(sent) / Double(total))) }
            return 0
        }, context)
        guard result == 0, file.pointee.item_id != 0 else {
            if file.pointee.item_id != 0 {
                // This handle was allocated by this upload, so a partial file can be removed safely.
                _ = LIBMTP_Delete_Object(handle, file.pointee.item_id)
            }
            close()
            throw progress.isCancelled ? CocoaError(.userCancelled) : CocoaError(.fileWriteUnknown)
        }
        progress.completedUnitCount = 100
        let item = DeviceItem.object(storage: file.pointee.storage_id, id: file.pointee.item_id)
        if let uploaded = try? entry(item) { return uploaded }
        return DeviceEntry(item: item, parent: folder, name: name, directory: false,
                           size: UInt64(info.st_size), writable: true)
    }

    func rename(_ item: DeviceItem, to name: String, validate: (DeviceEntry) throws -> Void) throws -> DeviceEntry {
        guard case .object(_, let id) = item else { throw CocoaError(.fileWriteNoPermission) }
        try validateName(name)
        var metadata = try entry(item)
        guard metadata.writable else { throw CocoaError(.fileWriteNoPermission) }
        try validate(metadata)
        if metadata.name == name { return metadata }
        if try children(metadata.parent).contains(where: {
            $0.item != item && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            throw NSFileProviderError(.filenameCollision)
        }
        let handle = try connectedHandle()
        var filename = name.utf8CString
        let result = filename.withUnsafeMutableBufferPointer { LIBMTP_Set_Object_Filename(handle, id, $0.baseAddress) }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        if let renamed = try? entry(item) { return renamed }
        metadata.name = name
        return metadata
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf16.count <= 254,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == ":" }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    private func objectEntry(_ file: LIBMTP_file_t) -> DeviceEntry {
        let storage = file.storage_id
        let parent: DeviceItem = file.parent_id == 0 || file.parent_id == UInt32.max
            ? .storage(storage) : .object(storage: storage, id: file.parent_id)
        let directory = file.filetype == LIBMTP_FILETYPE_FOLDER
        return DeviceEntry(item: .object(storage: storage, id: file.item_id), parent: parent,
                           name: cleanName(file.filename, fallback: "Item \(file.item_id)"), directory: directory,
                           size: directory ? 0 : file.filesize,
                           modifiedAt: file.modificationdate > 0 ? Date(timeIntervalSince1970: Double(file.modificationdate)) : nil,
                           writable: access[storage] == true)
    }

    private func cleanName(_ value: UnsafeMutablePointer<CChar>?, fallback: String) -> String {
        guard let value else { return fallback }
        let name = String(cString: value).unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == ":" ? "_" : String($0)
        }.joined()
        return name.isEmpty || name == "." || name == ".." ? fallback : name
    }
}
