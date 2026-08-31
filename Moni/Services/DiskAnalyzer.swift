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
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                scan(rootPath: rootPath, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func scan(
        rootPath: String,
        continuation: AsyncStream<DiskAnalysisUpdate>.Continuation
    ) {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let fileManager = FileManager.default
        var entrySizes: [String: UInt64] = [:]
        var largestFiles: [DiskAnalysisFile] = []
        var seenFiles: Set<FileIdentity> = []
        var scannedFileCount = 0
        var scannedBytes: UInt64 = 0
        var unreadableItemCount = 0

        func publish(currentPath: String?, isComplete: Bool) {
            let rankedFiles = largestFiles
                .sorted { $0.sizeBytes > $1.sizeBytes }
                .prefix(100)
                .map { $0 }
            continuation.yield(DiskAnalysisUpdate(
                rootPath: rootPath,
                entrySizes: entrySizes,
                largestFiles: rankedFiles,
                scannedFileCount: scannedFileCount,
                scannedBytes: scannedBytes,
                unreadableItemCount: unreadableItemCount,
                currentPath: currentPath,
                isComplete: isComplete
            ))
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
            publish(currentPath: nil, isComplete: true)
            continuation.finish()
            return
        }

        for child in children {
            guard !Task.isCancelled else {
                continuation.finish()
                return
            }
            guard let childMetadata = metadata(at: child) else {
                unreadableItemCount += 1
                continue
            }
            if childMetadata.isSymbolicLink {
                continue
            }

            if childMetadata.isDirectory {
                var childSize: UInt64 = 0
                guard let enumerator = fileManager.enumerator(
                    at: child,
                    includingPropertiesForKeys: nil,
                    options: [],
                    errorHandler: { _, _ in true }
                ) else {
                    unreadableItemCount += 1
                    continue
                }

                var itemsSinceUpdate = 0
                while let item = enumerator.nextObject() as? URL {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
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
                    guard itemMetadata.isRegularFile,
                          seenFiles.insert(itemMetadata.identity).inserted else {
                        continue
                    }

                    scannedFileCount += 1
                    scannedBytes = addingWithoutOverflow(scannedBytes, itemMetadata.allocatedBytes)
                    childSize = addingWithoutOverflow(childSize, itemMetadata.allocatedBytes)
                    largestFiles.append(DiskAnalysisFile(
                        path: item.path,
                        sizeBytes: itemMetadata.allocatedBytes
                    ))
                    trimLargestFiles(&largestFiles)

                    itemsSinceUpdate += 1
                    if itemsSinceUpdate >= 256 {
                        entrySizes[child.path] = childSize
                        publish(currentPath: item.path, isComplete: false)
                        itemsSinceUpdate = 0
                    }
                }
                entrySizes[child.path] = childSize
            } else if childMetadata.isRegularFile,
                      seenFiles.insert(childMetadata.identity).inserted {
                scannedFileCount += 1
                scannedBytes = addingWithoutOverflow(scannedBytes, childMetadata.allocatedBytes)
                entrySizes[child.path] = childMetadata.allocatedBytes
                largestFiles.append(DiskAnalysisFile(
                    path: child.path,
                    sizeBytes: childMetadata.allocatedBytes
                ))
                trimLargestFiles(&largestFiles)
            }
            publish(currentPath: child.path, isComplete: false)
        }

        publish(currentPath: nil, isComplete: true)
        continuation.finish()
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
