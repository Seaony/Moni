import Darwin
import Foundation

nonisolated struct DiskAnalysisFile: Identifiable, Sendable {
    let path: String
    let sizeBytes: UInt64

    var id: String { path }
}

nonisolated struct DiskAnalysisUpdate: Sendable {
    let rootPath: String
    let entrySizes: [String: UInt64]
    let largestFiles: [DiskAnalysisFile]
    let scannedFileCount: Int
    let scannedBytes: UInt64
    let unreadableItemCount: Int
    let currentPath: String?
    let isComplete: Bool
}

nonisolated enum DiskAnalyzer {
    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct FileMetadata {
        let identity: FileIdentity
        let allocatedBytes: UInt64
        let isDirectory: Bool
        let isRegularFile: Bool
        let isSymbolicLink: Bool
    }

    static func updates(for rootPath: String) -> AsyncStream<DiskAnalysisUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .utility) {
                _ = scan(
                    rootPath: rootPath,
                    timeLimit: nil,
                    tracksLargestFiles: true,
                    publishProgress: { continuation.yield($0) }
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func finalUpdates(
        for rootPath: String,
        timeLimit: TimeInterval = 6,
        excludingPaths: Set<String> = []
    ) -> AsyncStream<DiskAnalysisUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .utility) {
                let update = scan(
                    rootPath: rootPath,
                    timeLimit: timeLimit,
                    tracksLargestFiles: false,
                    excludingPaths: excludingPaths,
                    publishProgress: nil
                )
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(update)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func scan(
        rootPath: String,
        timeLimit: TimeInterval?,
        tracksLargestFiles: Bool,
        excludingPaths: Set<String> = [],
        publishProgress: ((DiskAnalysisUpdate) -> Void)?
    ) -> DiskAnalysisUpdate {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let normalizedRootPath = rootURL.standardizedFileURL.path
        let fileManager = FileManager.default
        let deadline = timeLimit.map { ProcessInfo.processInfo.systemUptime + $0 }
        let normalizedExcludedPaths = Set(excludingPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        var entrySizes: [String: UInt64] = [:]
        var largestFiles: [DiskAnalysisFile] = []
        var seenFiles: Set<FileIdentity> = []
        var scannedFileCount = 0
        var scannedBytes: UInt64 = 0
        var unreadableItemCount = 0
        var didReachTimeLimit = false

        func update(currentPath: String?, isComplete: Bool) -> DiskAnalysisUpdate {
            let rankedFiles: [DiskAnalysisFile]
            if tracksLargestFiles {
                rankedFiles = largestFiles
                    .sorted { $0.sizeBytes > $1.sizeBytes }
                    .prefix(100)
                    .map { $0 }
            } else {
                rankedFiles = []
            }
            return DiskAnalysisUpdate(
                rootPath: rootPath,
                entrySizes: entrySizes,
                largestFiles: rankedFiles,
                scannedFileCount: scannedFileCount,
                scannedBytes: scannedBytes,
                unreadableItemCount: unreadableItemCount,
                currentPath: currentPath,
                isComplete: isComplete
            )
        }

        func deadlineReached() -> Bool {
            guard let deadline else { return false }
            return ProcessInfo.processInfo.systemUptime >= deadline
        }

        guard let rootMetadata = metadata(at: rootURL),
              rootMetadata.isDirectory,
              !rootMetadata.isSymbolicLink else {
            unreadableItemCount = 1
            let finalUpdate = update(currentPath: nil, isComplete: true)
            publishProgress?(finalUpdate)
            return finalUpdate
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            unreadableItemCount = 1
            let finalUpdate = update(currentPath: nil, isComplete: true)
            publishProgress?(finalUpdate)
            return finalUpdate
        }
        var allowedDevices: Set<UInt64> = [rootMetadata.identity.device]
        if normalizedRootPath == "/",
           let dataVolume = metadata(at: URL(fileURLWithPath: "/System/Volumes/Data")) {
            allowedDevices.insert(dataVolume.identity.device)
        } else if normalizedRootPath == "/Volumes" {
            for child in children {
                if let childMetadata = metadata(at: child), childMetadata.isDirectory {
                    allowedDevices.insert(childMetadata.identity.device)
                }
            }
        }

        childLoop: for child in children {
            guard !Task.isCancelled else {
                return update(currentPath: nil, isComplete: false)
            }
            if deadlineReached() {
                unreadableItemCount += 1
                didReachTimeLimit = true
                break
            }
            if normalizedExcludedPaths.contains(child.standardizedFileURL.path) {
                continue
            }
            guard let childMetadata = metadata(at: child) else {
                unreadableItemCount += 1
                continue
            }
            if childMetadata.isSymbolicLink {
                continue
            }
            guard allowedDevices.contains(childMetadata.identity.device) else { continue }

            if childMetadata.isDirectory {
                var childSize: UInt64 = 0
                guard let enumerator = fileManager.enumerator(
                    at: child,
                    includingPropertiesForKeys: nil,
                    options: [],
                    errorHandler: { _, _ in
                        unreadableItemCount += 1
                        return true
                    }
                ) else {
                    unreadableItemCount += 1
                    continue
                }

                var itemsSinceUpdate = 0
                while let item = enumerator.nextObject() as? URL {
                    guard !Task.isCancelled else {
                        return update(currentPath: nil, isComplete: false)
                    }
                    if deadlineReached() {
                        unreadableItemCount += 1
                        didReachTimeLimit = true
                        break childLoop
                    }
                    guard let itemMetadata = metadata(at: item) else {
                        unreadableItemCount += 1
                        continue
                    }
                    if itemMetadata.isSymbolicLink {
                        if itemMetadata.isDirectory {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                    if itemMetadata.isDirectory {
                        if normalizedExcludedPaths.contains(item.standardizedFileURL.path) {
                            enumerator.skipDescendants()
                            continue
                        }
                        let isDataVolumeAlias = normalizedRootPath == "/"
                            && item.standardizedFileURL.path == "/System/Volumes/Data"
                        if isDataVolumeAlias
                            || !allowedDevices.contains(itemMetadata.identity.device) {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                    guard itemMetadata.isRegularFile,
                          seenFiles.insert(itemMetadata.identity).inserted else {
                        continue
                    }

                    scannedFileCount += 1
                    scannedBytes = addingWithoutOverflow(scannedBytes, itemMetadata.allocatedBytes)
                    childSize = addingWithoutOverflow(childSize, itemMetadata.allocatedBytes)
                    if tracksLargestFiles {
                        largestFiles.append(DiskAnalysisFile(
                            path: item.path,
                            sizeBytes: itemMetadata.allocatedBytes
                        ))
                        trimLargestFiles(&largestFiles)
                    }

                    itemsSinceUpdate += 1
                    if itemsSinceUpdate >= 256, publishProgress != nil {
                        entrySizes[child.path] = childSize
                        publishProgress?(update(currentPath: item.path, isComplete: false))
                        itemsSinceUpdate = 0
                    }
                }
                entrySizes[child.path] = childSize
            } else if childMetadata.isRegularFile,
                      seenFiles.insert(childMetadata.identity).inserted {
                scannedFileCount += 1
                scannedBytes = addingWithoutOverflow(scannedBytes, childMetadata.allocatedBytes)
                entrySizes[child.path] = childMetadata.allocatedBytes
                if tracksLargestFiles {
                    largestFiles.append(DiskAnalysisFile(
                        path: child.path,
                        sizeBytes: childMetadata.allocatedBytes
                    ))
                    trimLargestFiles(&largestFiles)
                }
            }
            publishProgress?(update(currentPath: child.path, isComplete: false))
        }

        let finalUpdate = update(currentPath: nil, isComplete: !didReachTimeLimit)
        publishProgress?(finalUpdate)
        return finalUpdate
    }

    private static func metadata(at url: URL) -> FileMetadata? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0 else { return nil }

        let kind = value.st_mode & S_IFMT
        let allocatedBytes = value.st_blocks > 0
            ? UInt64(value.st_blocks) * 512
            : 0
        return FileMetadata(
            identity: FileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino)),
            allocatedBytes: allocatedBytes,
            isDirectory: kind == S_IFDIR,
            isRegularFile: kind == S_IFREG,
            isSymbolicLink: kind == S_IFLNK
        )
    }

    private static func trimLargestFiles(_ files: inout [DiskAnalysisFile]) {
        guard files.count > 200 else { return }
        files.sort { $0.sizeBytes > $1.sizeBytes }
        files.removeSubrange(100...)
    }

    private static func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
