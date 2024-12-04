import Foundation

/// Use a backend and frontend adapter to cache access!
///
/// NOTE: Currently buggy is hell due to concurrency issues. This need s proper rewrite in async await before it should be used.
public final class MmapFileCached {
    public let backend: MmapFile
    public let frontend: MmapFile?
    public let cacheFile: String?

    public init(backend: FileHandle, frontend: FileHandle?, cacheFile: String?) throws {
        self.backend = try MmapFile(fn: backend)
        self.frontend = try frontend.map { try MmapFile(fn: $0, mode: .readWrite) }
        self.cacheFile = cacheFile
    }
    
    /// Check if the file was deleted on the file system
    public func wasDeleted() -> Bool {
        if frontend?.wasDeleted() == true {
            return true
        }
        if backend.wasDeleted() {
            if let cacheFile {
                try? FileManager.default.removeItemIfExists(at: cacheFile)
            }
            return true
        }
        return false
    }
    
    /// Check if data is in cache, otherwise load data from backend into cache
    public func prefetchData(offset: Int, count: Int) {
        if let frontend {
            frontend.prefetchData(offset: offset, count: count)
        } else {
            backend.prefetchData(offset: offset, count: count)
        }
    }
}

extension MmapFileCached: OmFileReaderBackend {
    public func getData(offset: Int, count: Int) -> UnsafeRawPointer {
        if let frontend {
            frontend.getData(offset: offset, count: count)
        } else {
            backend.getData(offset: offset, count: count)
        }
    }
    
    /// Populate cache frontend before reading
    public func preRead(offset: Int, count: Int) {
        guard let frontend else {
            return
        }
        // Check for sparse hole in a page and promote data from backend
        // Promote 128k at once
        let blockSize = 128*1024
        let pageSize = 4096
        let pageStart = offset.floor(to: pageSize)
        let pageEnd = (offset + count).ceil(to: pageSize)
        let backendData = UnsafeMutableBufferPointer(mutating: backend.data)
        let frontendData = UnsafeMutableBufferPointer(mutating: frontend.data)
        
        for page in stride(from: pageStart, to: pageEnd, by: pageSize) {
            let range = page..<min(page+pageSize, backendData.count)
            if frontendData.allZero(range) {
                let blockStart = page.floor(to: blockSize)
                let blockEnd = (page + pageSize).ceil(to: blockSize)
                let block = blockStart ..< min(blockEnd, backendData.count)
                backend.prefetchData(offset: blockStart, count: block.count)
                frontendData[block] = backendData[block]
                backend.prefetchData(offset: blockStart, count: block.count, advice: .dontneed)
            }
        }
    }
    
    public var count: Int {
        return backend.count
    }
    
    public var needsPrefetch: Bool {
        return true
    }
}

extension UnsafeMutableBufferPointer where Element == UInt8 {
    /// Check if a range contains all zero bytes
    func allZero(_ range: Range<Int>) -> Bool {
        for i in (range).clamped(to: indices) {
            if self[i] != 0 {
                return false
            }
        }
        return true
    }
}