import Darwin
import Foundation

/// Parallel directory walker built on getattrlistbulk(2), which returns names, types, sizes and
/// modification times for a whole directory in a few syscalls.
final class DiskScanner: @unchecked Sendable {
    struct Progress: Sendable {
        var files: Int64 = 0
        var dirs: Int64 = 0
        var bytes: Int64 = 0
        var currentPath = ""
    }

    /// Files at least this large get their own node so they show up in the treemap.
    static let largeFileThreshold: Int64 = 64 * 1024 * 1024
    /// Finished subdirectories smaller than this are folded into their parent to save memory.
    static let foldThreshold: Int64 = 1024 * 1024

    let root: DiskNode
    private let skip: [String: String] // absolute path -> reason
    private let condition = NSCondition()
    private var pending: [(DiskNode, String)] = []
    private var active = 0
    private var cancelled = false
    private var progress = Progress()
    private var rootDevice: Int32 = 0
    private var remaining: [ObjectIdentifier: Int] = [:] // subdirectories still being scanned
    private let latestPlausibleDate = Date.now.timeIntervalSince1970 + 86_400

    init(rootPath: String, skip: [String: String] = [:]) {
        let path = rootPath.count > 1 && rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        root = DiskNode(name: path, parent: nil, isDirectory: true, isHidden: false)
        self.skip = skip
    }

    /// Scans a single existing directory node in place (used to refresh one subtree).
    init(replacing node: DiskNode, skip: [String: String] = [:]) {
        root = DiskNode(name: node.name, parent: node.parent, isDirectory: true, isHidden: node.isHidden)
        self.skip = skip
        rootPathOverride = node.path
    }

    private var rootPathOverride: String?

    var currentProgress: Progress {
        condition.lock()
        defer { condition.unlock() }
        return progress
    }

    func cancel() {
        condition.lock()
        cancelled = true
        pending.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    /// Blocks until the walk finishes. Totals are aggregated before returning.
    func run(threads: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))) {
        let rootPath = rootPathOverride ?? root.name
        var info = stat()
        if stat(rootPath, &info) == 0 { rootDevice = info.st_dev }
        pending = [(root, rootPath)]

        let group = DispatchGroup()
        for index in 0..<threads {
            group.enter()
            let thread = Thread { [self] in
                worker()
                group.leave()
            }
            thread.name = "devdash.disk-scan.\(index)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
        if cancelled { root.aggregate() }
    }

    private func worker() {
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        while true {
            condition.lock()
            while pending.isEmpty && active > 0 && !cancelled {
                condition.wait()
            }
            if cancelled || pending.isEmpty {
                condition.broadcast()
                condition.unlock()
                return
            }
            let (node, path) = pending.removeLast()
            active += 1
            condition.unlock()

            let (subdirs, stats) = scanDirectory(node, path: path, buffer: buffer, bufferSize: bufferSize)

            condition.lock()
            pending.append(contentsOf: subdirs)
            if subdirs.isEmpty {
                complete(node)
            } else {
                remaining[ObjectIdentifier(node)] = subdirs.count
            }
            progress.files += stats.files
            progress.dirs += 1
            progress.bytes += stats.bytes
            progress.currentPath = path
            active -= 1
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Called with the lock held once a directory and all its subdirectories are scanned:
    /// computes its totals, folds small children, and completes the parent if it was the last one.
    private func complete(_ node: DiskNode) {
        var current: DiskNode? = node
        while let finished = current {
            var totals = finished.own
            var kept: [DiskNode] = []
            kept.reserveCapacity(finished.children.count)
            for child in finished.children {
                if child.isDirectory && child.total.allocated < Self.foldThreshold && child.skippedReason == nil && !child.denied {
                    finished.own.add(child.total, hidden: child.isHidden)
                } else {
                    kept.append(child)
                }
                totals.add(child.isDirectory ? child.total : child.own, hidden: child.isHidden)
                if !child.isDirectory { child.total = child.own }
            }
            totals.dirs += 1
            finished.children = kept
            finished.total = totals

            guard let parent = finished.parent, finished !== root else { return }
            let key = ObjectIdentifier(parent)
            let left = (remaining[key] ?? 1) - 1
            if left > 0 {
                remaining[key] = left
                return
            }
            remaining[key] = nil
            current = parent
        }
    }

    private func scanDirectory(
        _ node: DiskNode, path: String, buffer: UnsafeMutableRawPointer, bufferSize: Int
    ) -> ([(DiskNode, String)], (files: Int64, bytes: Int64)) {
        if let reason = skip[path] {
            node.skippedReason = reason
            return ([], (0, 0))
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 {
            node.denied = true
            return ([], (0, 0))
        }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Attr.returned | Attr.name | Attr.error | Attr.device | Attr.type | Attr.modified | Attr.flags
        request.fileattr = Attr.totalSize | Attr.allocSize

        var subdirs: [(DiskNode, String)] = []
        var files: Int64 = 0
        var bytes: Int64 = 0
        let prefix = path.hasSuffix("/") ? path : path + "/"

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 {
                if node.children.isEmpty && files == 0 { node.denied = true }
                break
            }
            if count == 0 { break }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var cursor = entry + 4
                let returned = cursor.loadUnaligned(as: attribute_set_t.self)
                cursor += MemoryLayout<attribute_set_t>.size

                if returned.commonattr & Attr.error != 0 {
                    let error = cursor.loadUnaligned(as: UInt32.self)
                    cursor += 4
                    if error != 0 { continue }
                }
                var namePointer: UnsafePointer<CChar>?
                var nameLength = 0
                if returned.commonattr & Attr.name != 0 {
                    let reference = cursor.loadUnaligned(as: attrreference_t.self)
                    namePointer = (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    nameLength = max(Int(reference.attr_length) - 1, 0)
                    cursor += MemoryLayout<attrreference_t>.size
                }
                guard let namePointer else { continue }
                var device: Int32 = rootDevice
                if returned.commonattr & Attr.device != 0 {
                    device = cursor.loadUnaligned(as: Int32.self)
                    cursor += 4
                }
                var type: UInt32 = 0
                if returned.commonattr & Attr.type != 0 {
                    type = cursor.loadUnaligned(as: UInt32.self)
                    cursor += 4
                }
                var modified: Double = 0
                if returned.commonattr & Attr.modified != 0 {
                    let time = cursor.loadUnaligned(as: timespec.self)
                    // Files with bogus future dates would otherwise make whole trees look "just written".
                    modified = Double(time.tv_sec) <= latestPlausibleDate ? Double(time.tv_sec) : 0
                    cursor += MemoryLayout<timespec>.size
                }
                var flags: UInt32 = 0
                if returned.commonattr & Attr.flags != 0 {
                    flags = cursor.loadUnaligned(as: UInt32.self)
                    cursor += 4
                }
                var apparent: Int64 = 0
                var allocated: Int64 = 0
                if returned.fileattr & Attr.totalSize != 0 {
                    apparent = cursor.loadUnaligned(as: Int64.self)
                    cursor += 8
                }
                if returned.fileattr & Attr.allocSize != 0 {
                    allocated = cursor.loadUnaligned(as: Int64.self)
                    cursor += 8
                }

                let hidden = namePointer.pointee == 0x2E || flags & UInt32(UF_HIDDEN) != 0
                switch type {
                case UInt32(VDIR.rawValue):
                    let name = String(cString: namePointer)
                    if name == ".git" { node.markers.insert(.git) }
                    if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") { node.markers.insert(.xcodeProject) }
                    let child = DiskNode(name: name, parent: node, isDirectory: true, isHidden: hidden)
                    child.own.newest = modified
                    node.children.append(child)
                    if device != rootDevice {
                        child.skippedReason = "Different volume"
                    } else {
                        subdirs.append((child, prefix + name))
                    }
                case UInt32(VREG.rawValue), UInt32(VLNK.rawValue):
                    if ProjectMarkers.candidateLengths.contains(nameLength) {
                        node.markers.formUnion(ProjectMarkers.forFile(String(cString: namePointer)))
                    }
                    files += 1
                    bytes += allocated
                    var totals = DiskTotals(allocated: allocated, apparent: apparent, files: 1, newest: modified)
                    if allocated >= Self.largeFileThreshold {
                        let leaf = DiskNode(name: String(cString: namePointer), parent: node, isDirectory: false, isHidden: hidden)
                        leaf.own = totals
                        node.children.append(leaf)
                    } else {
                        if hidden {
                            totals.hiddenAllocated = allocated
                            totals.hiddenApparent = apparent
                            totals.hiddenFiles = 1
                        }
                        node.own.add(totals, hidden: false)
                    }
                default:
                    continue
                }
            }
        }
        return (subdirs, (files, bytes))
    }
}

/// getattrlist bit constants normalized to attrgroup_t (the C macros import with mixed signedness).
private enum Attr {
    static let returned = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
    static let name = attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
    static let error = attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
    static let device = attrgroup_t(truncatingIfNeeded: ATTR_CMN_DEVID)
    static let type = attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
    static let modified = attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
    static let flags = attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
    static let totalSize = attrgroup_t(truncatingIfNeeded: ATTR_FILE_TOTALSIZE)
    static let allocSize = attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)
}

enum DiskAccess {
    /// Full Disk Access is required to read other apps' data; ~/Library/Safari is a reliable probe.
    static var hasFullDiskAccess: Bool {
        let fd = open(NSHomeDirectory() + "/Library/Safari", O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd); return true }
        return errno != EPERM && errno != EACCES
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Folders that make macOS prompt ("access data from other apps", cloud providers) or always
    /// fail without Full Disk Access. They are skipped and shown as needing access instead.
    static func protectedFolders(fullDiskAccess: Bool) -> [String: String] {
        guard !fullDiskAccess else { return [:] }
        let library = NSHomeDirectory() + "/Library"
        let reason = "Needs Full Disk Access"
        return [
            library + "/Containers": reason,
            library + "/Group Containers": reason,
            library + "/CloudStorage": reason,
            library + "/Mobile Documents": reason,
            library + "/Mail": reason,
            library + "/Messages": reason,
            library + "/Safari": reason,
            library + "/Biome": reason,
            library + "/Application Support/AddressBook": reason,
            library + "/Application Support/CallHistoryDB": reason,
            library + "/Application Support/com.apple.TCC": reason,
            library + "/Application Support/FileProvider": reason,
        ]
    }
}
