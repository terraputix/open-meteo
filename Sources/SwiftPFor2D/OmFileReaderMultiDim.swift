//
//  File.swift
//  
//
//  Created by Patrick Zippenfenig on 09.09.2024.
//

import Foundation
@_implementationOnly import CTurboPFor
@_implementationOnly import CHelper


struct OmFileDecoder<Backend: OmFileReaderBackend> {
    let fn: Backend
    
    /// The scalefactor that is applied to all write data
    public let scalefactor: Float
    
    /// Type of compression and coding. E.g. delta, zigzag coding is then implemented in different compression routines
    public let compression: CompressionType
    
    /// The dimensions of the file
    let dims: [Int]
    
    /// How the dimensions are chunked
    let chunks: [Int]
    
    /// The offset position of the beignning of the LUT
    let lutStart: Int
    
    /// How long a chunk inside the LUT is after compression
    let lutChunkLength: Int
    
    /// Number of elements in index LUT chunk. Might be hardcoded to 256 later
    let lutChunkElementCount: Int
    
    /// Offset in bytes of data. Only used in V1 files. Otherwise 0.
    let dataStart: Int
    
    public static func open_file(fn: Backend, lutChunkElementCount: Int = 256) throws -> Self {
        // read header
        
        // switch version 2 and 3
        
        // if version 3, read trailer
        
        //let lutStart = lutStart ?? OmHeader.length
        //let dataStart = version == 3 ? 3 : OmHeader.length + nChunks*8
        
        return try fn.withUnsafeBytes({ptr in
            
            /*let lutStart = ptr.baseAddress!.advanced(by: fn.count - 8).assumingMemoryBound(to: Int.self).pointee
            let lutChunkLength = ptr.baseAddress!.advanced(by: fn.count - 16).assumingMemoryBound(to: Int.self).pointee
            let nDims = ptr.baseAddress!.advanced(by: fn.count - 24).assumingMemoryBound(to: Int.self).pointee
            
            let dimensions = [Int](unsafeUninitializedCapacity: nDims, initializingWith: {
                memcpy($0.baseAddress!, ptr.baseAddress!.advanced(by: fn.count - 24 - 2*nDims*8), nDims*8)
                $1 = nDims
            })
            
            let chunks = [Int](unsafeUninitializedCapacity: nDims, initializingWith: {
                memcpy($0.baseAddress!, ptr.baseAddress!.advanced(by: fn.count - 24 - nDims*8), nDims*8)
                $1 = nDims
            })*/
            
            let jsonLength = ptr.baseAddress!.advanced(by: fn.count - 8).assumingMemoryBound(to: Int.self).pointee
            let jsonData = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: (ptr.baseAddress!.advanced(by: fn.count - 8 - jsonLength))),
                count: jsonLength,
                deallocator: .none
            )
            let json = try JSONDecoder().decode(OmFileJSON.self, from: jsonData)
            // Just read the first variable. Ignoring the rest.
            let variable = json.variables[0]
            
            //print(lutStart, nDims, dimensions, chunks)
            
            return OmFileDecoder(
                fn: fn,
                scalefactor: 1,
                compression: .p4nzdec256,
                dims: variable.dimensions,
                chunks: variable.chunks,
                lutStart: variable.lutOffset,
                lutChunkLength: variable.lutChunkSize,
                lutChunkElementCount: lutChunkElementCount,
                dataStart: 0
            )
        })
    }
    
    public func read(into: UnsafeMutablePointer<Float>, dimRead: [Range<Int>], intoCoordLower: [Int], intoCubeDimension: [Int]) {
        let chunkLength = chunks.reduce(1, *)
        let bufferSize = P4NDEC256_BOUND(n: chunkLength, bytesPerElement: compression.bytesPerElement)
        let chunkBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 4)

        let read = OmFileReadRequest(
            scalefactor: scalefactor,
            compression: compression,
            dims: dims,
            chunks: chunks,
            dimReadOffset: dimRead.map{$0.lowerBound},
            dimReadCount: dimRead.map{$0.count},
            intoCoordLower: intoCoordLower,
            intoCubeDimension: intoCubeDimension,
            lutChunkLength: lutChunkLength,
            lutChunkElementCount: lutChunkElementCount, // `1` if version <2
            dataStart: dataStart,
            lutStart: lutStart
        )
        read.read_from_file(fn: fn, into: into, chunkBuffer: chunkBuffer.baseAddress!, version: 3)
        chunkBuffer.deallocate()
    }
    
    public func read(_ dimRead: [Range<Int>]) -> [Float] {
        let outDims = dimRead.map({$0.count})
        let n = outDims.reduce(1, *)
        var out = [Float](repeating: .nan, count: n)
        out.withUnsafeMutableBufferPointer({
            read(into: $0.baseAddress!, dimRead: dimRead, intoCoordLower: .init(repeating: 0, count: dimRead.count), intoCubeDimension: outDims)
        })
        return out
    }
}

/**
 TODO:
 - consider if we need to access the index LUT inside decompress call instead of relying on returned data size
 */
struct OmFileReadRequest {
    /// The scalefactor that is applied to all write data
    public let scalefactor: Float
    
    /// Type of compression and coding. E.g. delta, zigzag coding is then implemented in different compression routines
    public let compression: CompressionType
    
    /// The dimensions of the file
    let dims: [Int]
    
    /// How the dimensions are chunked
    let chunks: [Int]
    
    /// Which values to read
    let dimReadOffset: [Int]
    
    /// Which values to read
    let dimReadCount: [Int]
    
    /// The offset the result should be placed into the target cube. E.g. a slice or a chunk of a cube
    let intoCoordLower: [Int]
    
    /// The target cube dimensions. E.g. Reading 2 years of data may read data from mutliple files
    let intoCubeDimension: [Int] // = dimRead.map { $0.count }
    
    /// Automatically merge and break up IO to ideal sizes
    /// Merging is important to reduce the number of IO operations for the lookup table
    /// A maximum size will break up chunk reads. Otherwise a full file read could result in a single 20GB read.
    let io_size_merge: Int = 512
    
    /// Maximum length of a return IO read
    let io_size_max: Int = 65536
    
    /// How long a chunk inside the LUT is after compression
    let lutChunkLength: Int
    
    /// Number of elements in each LUT chunk
    let lutChunkElementCount: Int
    
    /// Offset in bytes of data. Only used in V1 files. Otherwise 0.
    let dataStart: Int
    
    /// Offset  in bytes of LUT index
    let lutStart: Int
    
    /// Actually read data from a file. Merges IO for optimal sizes
    /// TODO: The read offset calculation is not ideal
    func read_from_file<Backend: OmFileReaderBackend>(fn: Backend, into: UnsafeMutablePointer<Float>, chunkBuffer: UnsafeMutableRawPointer, version: Int = 2) {
        
        var chunkIndex: Range<Int>? = get_first_chunk_position()
        
        //print("new read \(self), start \(chunkIndex ?? 0..<0)")
        
        let nChunks = number_of_chunks()
        
        let lutTotalSize = nChunks.divideRoundedUp(divisor: lutChunkElementCount) * lutChunkLength
        
        fn.withUnsafeBytes({ ptr in
            /// Loop over index blocks
            while let chunkIndexStart = chunkIndex {
                let readIndexInstruction = get_next_index_read(chunkIndex: chunkIndexStart)
                chunkIndex = readIndexInstruction.nextChunk
                var chunkData: Range<Int>? = chunkIndexStart
                
                // actually "read" index data from file
                //print("read index \(readIndexInstruction), chunkIndexRead=\(chunkData ?? 0..<0)")
                assert(readIndexInstruction.offset + readIndexInstruction.count - lutStart <= lutTotalSize)
                let indexData = UnsafeRawBufferPointer(rebasing: ptr[readIndexInstruction.offset ..< readIndexInstruction.offset + readIndexInstruction.count])
                //ptr.baseAddress!.advanced(by: lutStart + readIndexInstruction.offset).assumingMemoryBound(to: UInt8.self)
                //print(ptr.baseAddress!.advanced(by: lutStart).assumingMemoryBound(to: Int.self).assumingMemoryBound(to: Int.self, capacity: readIndexInstruction.count / 8).map{$0})
                      
                
                /// Loop over data blocks
                while let chunkDataStart = chunkData {
                    let readDataInstruction = get_next_data_read(chunkIndex: chunkDataStart, indexRange: readIndexInstruction.indexRange, indexData: indexData)
                    chunkData = readDataInstruction.nextChunk
                    
                    // actually "read" compressed chunk data from file
                    //print("read data \(readDataInstruction)")
                    let dataData = ptr.baseAddress!.advanced(by: readDataInstruction.offset)
                    
                    let uncompressedSize = decode_chunks(globalChunkNum: readDataInstruction.dataStartChunk, lastChunk: readDataInstruction.dataLastChunk, data: dataData, into: into, chunkBuffer: chunkBuffer)
                    if uncompressedSize != readDataInstruction.count {
                        fatalError("Uncompressed size missmatch")
                    }
                }
            }
        })
    }
    
    /// Return the total number of chunks in this file
    func number_of_chunks() -> Int {
        var n = 1
        for i in 0..<dims.count {
            n *= dims[i].divideRoundedUp(divisor: chunks[i])
        }
        return n
    }
    
    /// Return the next data-block to read from the lookup table. Merges reads from mutliple chunks adress lookups.
    /// Modifies `chunkIndex` to keep as a internal reference counter
    /// Should be called in a loop. Return `nil` once all blocks have been processed and the hyperchunk read is complete
    public func get_next_index_read(chunkIndex chunkIndexStart: Range<Int>) -> (offset: Int, count: Int, indexRange: Range<Int>, nextChunk: Range<Int>?) {
        
        var chunkIndex = chunkIndexStart.lowerBound
        var nextChunkOut: Range<Int>? = chunkIndexStart
        
        let isV3LUT = dataStart == 0
        
        /// Old files do not store the chunk start in the first LUT entry
        /// LUT old: end0, end1, end2
        /// LUT new: start0, end0, end1, end2
        let alignOffset = isV3LUT || chunkIndexStart.lowerBound == 0 ? 0 : 1
        let endAlignOffset = isV3LUT ? 1 : 0
        
        var rangeEnd = chunkIndexStart.upperBound
        
        /// The current read start position
        let readStart = (chunkIndexStart.lowerBound-alignOffset) / lutChunkElementCount * lutChunkLength
        
        /// loop to next chunk until the end is reached, consecutive reads are further appart than `io_size_merge` or the maximum read length is reached `io_size_max`
        while true {
            /// The read end potiions of the previous chunk index. Could be consecutive, or has a huge gap.
            let readEndPrevious = chunkIndex / lutChunkElementCount * lutChunkLength
            
            /// How many elements could we read before we reach the maximum IO size
            let maxRead = io_size_max / lutChunkLength * lutChunkElementCount
            let nextIncrement = max(1, min(maxRead, rangeEnd - chunkIndex - 1))
            
            var next = chunkIndex + nextIncrement
            if next >= rangeEnd {
                guard let nextRange = get_next_chunk_position(globalChunkNum: chunkIndex) else {
                    // there is no next chunk anymore, finish processing the current one and then stop with the next call
                    nextChunkOut = nil
                    break
                }
                rangeEnd = nextRange.upperBound
                next = nextRange.lowerBound
                
                nextChunkOut = next ..< rangeEnd
                let readStartNext = (next+endAlignOffset) / lutChunkElementCount * lutChunkLength - lutChunkLength
                
                // The new range could be quite far apart.
                // E.g. A LUT of 10MB and you only need information from the beginning and end
                // Check how "far" appart the the new read
                guard readStartNext - readEndPrevious <= io_size_merge else {
                    // Reads are too far appart. E.g. a lot of unsed data in the middle
                    break
                }
            }
            nextChunkOut = next ..< rangeEnd
            
            /// The read end position if the current index would be read
            let readEndNext = (next+endAlignOffset) / lutChunkElementCount * lutChunkLength
            
            guard readEndNext - readStart <= io_size_max else {
                // the next read would exceed IO limitons
                break
            }
            chunkIndex = next
        }
        let readEnd = ((chunkIndex + endAlignOffset) / lutChunkElementCount + 1) * lutChunkLength
        return (lutStart + readStart, readEnd - readStart, chunkIndexStart.lowerBound..<chunkIndex+1, nextChunkOut)
    }
    
    
    /// Data = index of global chunk num
    public func get_next_data_read(chunkIndex dataStartChunk: Range<Int>, indexRange: Range<Int>, indexData: UnsafeRawBufferPointer) -> (offset: Int, count: Int, dataStartChunk: Int, dataLastChunk: Int, nextChunk: Range<Int>?) {
        var globalChunkNum = dataStartChunk.lowerBound
        var nextChunkOut: Range<Int>? = dataStartChunk
        
        /// Version 1 case
        if lutChunkElementCount == 1 {
            // index is a flat Int64 array
            let data = indexData.assumingMemoryBound(to: Int.self).baseAddress!
            
            /// If the start index starts at 0, the entire array is shifted by one, because the start position of 0 is not stored
            let startOffset = indexRange.lowerBound == 0 ? 1 : 0
            
            /// Index data relative to startindex, needs special care because startpos==0 reads one value less
            let startPos = indexRange.lowerBound == 0 ? 0 : data.advanced(by: indexRange.lowerBound - dataStartChunk.lowerBound - startOffset).pointee
            var endPos = data.advanced(by: indexRange.lowerBound == 0 ? 0 : 1).pointee
            
            var rangeEnd = dataStartChunk.upperBound
            
            /// loop to next chunk until the end is reached, consecutive reads are further appart than `io_size_merge` or the maximum read length is reached `io_size_max`
            while true {
                var next = globalChunkNum + 1
                if next >= rangeEnd {
                    guard let nextRange = get_next_chunk_position(globalChunkNum: globalChunkNum) else {
                        // there is no next chunk anymore, finish processing the current one and then stop with the next call
                        nextChunkOut = nil
                        break
                    }
                    rangeEnd = nextRange.upperBound
                    next = nextRange.lowerBound
                }
                guard next < indexRange.upperBound else {
                    nextChunkOut = nil
                    break
                }
                nextChunkOut = next ..< rangeEnd
                
                let dataStartPos = data.advanced(by: next - indexRange.lowerBound - startOffset).pointee
                let dataEndPos = data.advanced(by: next - indexRange.lowerBound - startOffset + 1).pointee
                
                /// Merge and split IO requests
                if dataEndPos - startPos > io_size_max,
                    dataStartPos - endPos > io_size_merge {
                    break
                }
                endPos = dataEndPos
                globalChunkNum = next
            }
            //print("Read \(startPos)-\(endPos) (\(endPos - startPos) bytes)")
            // IMPORTANT: V1 files have a add dataStart
            return (startPos + dataStart, endPos - startPos, dataStartChunk.lowerBound, globalChunkNum, nextChunkOut)
        }
        
        /// TODO optimise
        let nChunks = number_of_chunks()
        
        // index is a flat Int64 array
        //let data = indexData.assumingMemoryBound(to: Int.self)
        
        let indexDataPtr = UnsafeMutablePointer(mutating: indexData.baseAddress!.assumingMemoryBound(to: UInt8.self))
        
        /// If the start index starts at 0, the entire array is shifted by one, because the start position of 0 is not stored
        //let startOffset = indexRange.lowerBound == 0 ? 1 : 0
        
        /// Note: This should be stack allocated to a max size of 256 elements
        /// TODO LUT buffer may need to be larger. Maybe no bounding is required anymore at all
        var uncompressedLut = [UInt64](repeating: 0, count: lutChunkElementCount+16)
        
        /// Which LUT chunk is currently loaded into `uncompressedLut`
        var lutChunk = -1
        
        /// Uncompress the first LUT index chunk and check the length
        if true { // if indexRange.lowerBound > 0 {
            lutChunk = (dataStartChunk.lowerBound - 0) / lutChunkElementCount
            let thisLutChunkElementCount = min((lutChunk + 1) * lutChunkElementCount, nChunks+1) - lutChunk * lutChunkElementCount
            let start = lutChunk * self.lutChunkLength - max(0, indexRange.lowerBound - 0) / lutChunkElementCount * self.lutChunkLength
            assert(start >= 0)
            assert(start + self.lutChunkLength <= indexData.count)
            if lutChunkElementCount == 1 {
                // Old files do not compress LUTs
                uncompressedLut[0] = indexDataPtr.advanced(by: start).assumingMemoryBound(to: UInt64.self, capacity: 1)[0]
            } else {
                // Decompress LUT chunk
                uncompressedLut.withUnsafeMutableBufferPointer { dest in
                    let _ = p4nddec64(indexDataPtr.advanced(by: start), thisLutChunkElementCount, dest.baseAddress)
                }
            }
            //print("Initial LUT load \(uncompressedLut), \(thisLutChunkElementCount), start=\(start)")
        }
        
        /// The last value for the previous LUT chunk
        //var uncompressedLutPreviousEnd = UInt64(0)
        
        /// Index data relative to startindex, needs special care because startpos==0 reads one value less
        let startPos = /*indexRange.lowerBound == 0 ? UInt64(dataStart) : */uncompressedLut[(dataStartChunk.lowerBound - 0) % lutChunkElementCount]
        
        /// For the unlucky case that only th last value of the LUT was required, we now have to decompress the next LUT
        if (indexRange.lowerBound + 1) / lutChunkElementCount != lutChunk {
            lutChunk = (dataStartChunk.lowerBound + 1) / lutChunkElementCount
            let thisLutChunkElementCount = min((lutChunk + 1) * lutChunkElementCount, nChunks+1) - lutChunk * lutChunkElementCount
            let start = lutChunk * self.lutChunkLength - max(0, indexRange.lowerBound - 0) / lutChunkElementCount * self.lutChunkLength
            assert(start >= 0)
            assert(start + self.lutChunkLength <= indexData.count)
            if lutChunkElementCount == 1 {
                // Old files do not compress LUTs
                uncompressedLut[0] = indexDataPtr.advanced(by: start).assumingMemoryBound(to: UInt64.self, capacity: 1)[0]
            } else {
                // Decompress LUT chunk
                uncompressedLut.withUnsafeMutableBufferPointer { dest in
                    let _ = p4nddec64(indexDataPtr.advanced(by: start), thisLutChunkElementCount, dest.baseAddress)
                }
            }
            //print("Secondary LUT load \(uncompressedLut), \(thisLutChunkElementCount), start=\(start)")
        }
        
        var endPos = uncompressedLut[(dataStartChunk.lowerBound+1) % lutChunkElementCount]
        
        var rangeEnd = dataStartChunk.upperBound
        
        /// loop to next chunk until the end is reached, consecutive reads are further appart than `io_size_merge` or the maximum read length is reached `io_size_max`
        while true {
            var next = globalChunkNum + 1
            //print("next \(next)")
            if next >= rangeEnd {
                guard let nextRange = get_next_chunk_position(globalChunkNum: globalChunkNum) else {
                    // there is no next chunk anymore, finish processing the current one and then stop with the next call
                    nextChunkOut = nil
                    break
                }
                rangeEnd = nextRange.upperBound
                next = nextRange.lowerBound
            }
            guard next < indexRange.upperBound else {
                nextChunkOut = nil
                break
            }
            nextChunkOut = next ..< rangeEnd
            
            let nextLutChunk = (next+1) / lutChunkElementCount
            
            /// Maybe the next LUT chunk needs to be uncompressed
            if nextLutChunk != lutChunk {
                let nextlutChunkElementCount = min((nextLutChunk + 1) * lutChunkElementCount, nChunks+1) - nextLutChunk * lutChunkElementCount
                let start = nextLutChunk * self.lutChunkLength - max(0, indexRange.lowerBound - 0) / lutChunkElementCount * self.lutChunkLength
                assert(start >= 0)
                assert(start + self.lutChunkLength <= indexData.count)
                if lutChunkElementCount == 1 {
                    // Old files do not compress LUTs
                    uncompressedLut[0] = indexDataPtr.advanced(by: start).assumingMemoryBound(to: UInt64.self, capacity: 1)[0]
                } else {
                    // Decompress LUT chunk
                    uncompressedLut.withUnsafeMutableBufferPointer { dest in
                        let _ = p4nddec64(indexDataPtr.advanced(by: start), nextlutChunkElementCount, dest.baseAddress)
                    }
                }
                //print("Next LUT load \(uncompressedLut), \(nextlutChunkElementCount), start=\(start)")
                //print(uncompressedLut)
                lutChunk = nextLutChunk
            }
            
            //let dataStartPos = data.advanced(by: next - indexRange.lowerBound - startOffset).pointee
            //let dataEndPos = data.advanced(by: next - indexRange.lowerBound - startOffset + 1).pointee
            
            let dataEndPos = uncompressedLut[(next+1) % lutChunkElementCount]
            
            /// Merge and split IO requests
            if dataEndPos - startPos > io_size_max,
               dataEndPos - endPos > io_size_merge {
                break
            }
            endPos = dataEndPos
            globalChunkNum = next
        }
        //print("Read \(startPos)-\(endPos) (\(endPos - startPos) bytes)")
        return (Int(startPos), Int(endPos) - Int(startPos), dataStartChunk.lowerBound, globalChunkNum, nextChunkOut)
    }
    
    /// Decode multiple chunks inside `data`. Chunks are ordered strictly increasing by 1. Due to IO merging, a chunk might be read, that does not contain relevant data for the output.
    /// Returns number of processed bytes from input
    public func decode_chunks(globalChunkNum: Int, lastChunk: Int, data: UnsafeRawPointer, into: UnsafeMutablePointer<Float>, chunkBuffer: UnsafeMutableRawPointer) -> Int {

        // Note: Relays on the correct number of uncompressed bytes from the compression library...
        // Maybe we need a differnet way that is independenet of this information
        var pos = 0
        for chunkNum in globalChunkNum ... lastChunk {
            //print("decompress chunk \(chunkNum), pos \(pos)")
            let uncompressedBytes = decode_chunk_into_array(globalChunkNum: chunkNum, data: data.advanced(by: pos), into: into, chunkBuffer: chunkBuffer)
            pos += uncompressedBytes
        }
        return pos
    }
    
    /// Writes a chunk index into the
    /// Return number of uncompressed bytes from the data
    @discardableResult
    public func decode_chunk_into_array(globalChunkNum: Int, data: UnsafeRawPointer, into: UnsafeMutablePointer<Float>, chunkBuffer: UnsafeMutableRawPointer) -> Int {
        //print("globalChunkNum=\(globalChunkNum)")
        
        var rollingMultiplty = 1
        var rollingMultiplyChunkLength = 1
        var rollingMultiplyTargetCube = 1
        
        /// Read coordinate from temporary chunk buffer
        var d = 0
        
        /// Write coordinate to output cube
        var q = 0
        
        /// Copy multiple elements from the decoded chunk into the output buffer. For long time-series this drastically improves copy performance.
        var linearReadCount = 1
        
        /// Internal state to keep track if everything is kept linear
        var linearRead = true
        
        /// Used for 2d delta coding
        var lengthLast = 0
        
        /// If no data needs to be read from this chunk, it will still be decompressed to caclculate the number of compressed bytes
        var no_data = false
        
        /// Count length in chunk and find first buffer offset position
        for i in (0..<dims.count).reversed() {
            let nChunksInThisDimension = dims[i].divideRoundedUp(divisor: chunks[i])
            let c0 = (globalChunkNum / rollingMultiplty) % nChunksInThisDimension
            /// Number of elements in this dim in this chunk
            let length0 = min((c0+1) * chunks[i], dims[i]) - c0 * chunks[i]
            
            let chunkGlobal0Start = c0 * chunks[i]
            let chunkGlobal0End = chunkGlobal0Start + length0
            let clampedGlobal0Start = max(chunkGlobal0Start, dimReadOffset[i])
            let clampedGlobal0End = min(chunkGlobal0End, dimReadOffset[i] + dimReadCount[i])
            let clampedLocal0Start = clampedGlobal0Start - c0 * chunks[i]
            //let clampedLocal0End = clampedGlobal0End - c0 * chunks[i]
            /// Numer of elements read in this chunk
            let lengthRead = clampedGlobal0End - clampedGlobal0Start
            
            if dimReadOffset[i] + dimReadCount[i] <= chunkGlobal0Start || dimReadOffset[i] >= chunkGlobal0End {
                // There is no data in this chunk that should be read. This happens if IO is merged, combining mutliple read blocks.
                // The returned bytes count still needs to be computed
                //print("Not reading chunk \(globalChunkNum)")
                no_data = true
            }
            
            if i == dims.count-1 {
                lengthLast = length0
            }
            
            /// start only!
            let d0 = clampedLocal0Start
            /// Target coordinate in hyperchunk. Range `0...dim0Read`
            let t0 = chunkGlobal0Start - dimReadOffset[i] + d0
            
            let q0 = t0 + intoCoordLower[i]
            
            d = d + rollingMultiplyChunkLength * d0
            q = q + rollingMultiplyTargetCube * q0
            
            if i == dims.count-1 && !(lengthRead == length0 && dimReadCount[i] == length0 && intoCubeDimension[i] == length0) {
                // if fast dimension and only partially read
                linearReadCount = lengthRead
                linearRead = false
            }
            if linearRead && lengthRead == length0 && dimReadCount[i] == length0 && intoCubeDimension[i] == length0 {
                // dimension is read entirely
                // and can be copied linearly into the output buffer
                linearReadCount *= length0
            } else {
                // dimension is read partly, cannot merge further reads
                linearRead = false
            }
                            
            rollingMultiplty *= nChunksInThisDimension
            rollingMultiplyTargetCube *= intoCubeDimension[i]
            rollingMultiplyChunkLength *= length0
        }
        
        /// How many elements are in this chunk
        let lengthInChunk = rollingMultiplyChunkLength
        //print("lengthInChunk \(lengthInChunk), t sstart=\(d)")
        
        
        let uncompressedBytes: Int
        
        switch compression {
        case .p4nzdec256, .p4nzdec256logarithmic:
            let chunkBuffer = chunkBuffer.assumingMemoryBound(to: UInt16.self)
            let mutablePtr = UnsafeMutablePointer(mutating: data.assumingMemoryBound(to: UInt8.self))
            uncompressedBytes = p4nzdec128v16(mutablePtr, lengthInChunk, chunkBuffer)
        case .fpxdec32:
            let chunkBuffer = chunkBuffer.assumingMemoryBound(to: UInt32.self)
            let mutablePtr = UnsafeMutablePointer(mutating: data.assumingMemoryBound(to: UInt8.self))
            uncompressedBytes = fpxdec32(mutablePtr, lengthInChunk, chunkBuffer, 0)
        }
        
        //print("uncompressed bytes", uncompressedBytes, "lengthInChunk", lengthInChunk)
        
        if no_data {
            return uncompressedBytes
        }

        switch compression {
        case .p4nzdec256, .p4nzdec256logarithmic:
            let chunkBuffer = chunkBuffer.assumingMemoryBound(to: UInt16.self)
            delta2d_decode(lengthInChunk / lengthLast, lengthLast, chunkBuffer)
        case .fpxdec32:
            let chunkBuffer = chunkBuffer.assumingMemoryBound(to: Float.self)
            delta2d_decode_xor(lengthInChunk / lengthLast, lengthLast, chunkBuffer)
        }
        
        
        /// Loop over all values need to be copied to the output buffer
        loopBuffer: while true {
            //print("read buffer from pos=\(d) and write to \(q), count=\(linearReadCount)")
            //linearReadCount=1
            
            switch compression {
            case .p4nzdec256:
                let chunkBuffer = chunkBuffer.assumingMemoryBound(to: UInt16.self)
                for i in 0..<linearReadCount {
                    let val = chunkBuffer[d+i]
                    if val == Int16.max {
                        into.advanced(by: q+i).pointee = .nan
                    } else {
                        let unscaled = Float(val) / scalefactor
                        into.advanced(by: q+i).pointee = unscaled
                    }
                }
            case .fpxdec32:
                let chunkBuffer = chunkBuffer.assumingMemoryBound(to: Float.self)
                for i in 0..<linearReadCount {
                    into.advanced(by: q+i).pointee = chunkBuffer[d+i]
                }
            case .p4nzdec256logarithmic:
                let chunkBuffer = chunkBuffer.assumingMemoryBound(to: UInt16.self)
                for i in 0..<linearReadCount {
                    let val = chunkBuffer[d+i]
                    if val == Int16.max {
                        into.advanced(by: q+i).pointee = .nan
                    } else {
                        let unscaled = powf(10, Float(val) / scalefactor) - 1
                        into.advanced(by: q+i).pointee = unscaled
                    }
                }
            }

            q += linearReadCount-1
            d += linearReadCount-1
                            
            /// Move `q` and `d` to next position
            rollingMultiplty = 1
            rollingMultiplyTargetCube = 1
            rollingMultiplyChunkLength = 1
            linearReadCount = 1
            linearRead = true
            for i in (0..<dims.count).reversed() {
                let nChunksInThisDimension = dims[i].divideRoundedUp(divisor: chunks[i])
                let c0 = (globalChunkNum / rollingMultiplty) % nChunksInThisDimension
                /// Number of elements in this dim in this chunk
                let length0 = min((c0+1) * chunks[i], dims[i]) - c0 * chunks[i]
                let chunkGlobal0Start = c0 * chunks[i]
                let chunkGlobal0End = chunkGlobal0Start + length0
                let clampedGlobal0Start = max(chunkGlobal0Start, dimReadOffset[i])
                let clampedGlobal0End = min(chunkGlobal0End, dimReadOffset[i] + dimReadCount[i])
                //let clampedLocal0Start = clampedGlobal0Start - c0 * chunks[i]
                let clampedLocal0End = clampedGlobal0End - c0 * chunks[i]
                /// Numer of elements read in this chunk
                let lengthRead = clampedGlobal0End - clampedGlobal0Start
                
                /// More forward
                d += rollingMultiplyChunkLength
                q += rollingMultiplyTargetCube
                
                if i == dims.count-1 && !(lengthRead == length0 && dimReadCount[i] == length0 && intoCubeDimension[i] == length0) {
                    // if fast dimension and only partially read
                    linearReadCount = lengthRead
                    linearRead = false
                }
                if linearRead && lengthRead == length0 && dimReadCount[i] == length0 && intoCubeDimension[i] == length0 {
                    // dimension is read entirely
                    // and can be copied linearly into the output buffer
                    linearReadCount *= length0
                } else {
                    // dimension is read partly, cannot merge further reads
                    linearRead = false
                }
                
                let d0 = (d / rollingMultiplyChunkLength) % length0
                if d0 != clampedLocal0End && d0 != 0 {
                    break // no overflow in this dimension, break
                }
                
                d -= lengthRead * rollingMultiplyChunkLength
                q -= lengthRead * rollingMultiplyTargetCube
                
                rollingMultiplty *= nChunksInThisDimension
                rollingMultiplyTargetCube *= intoCubeDimension[i]
                rollingMultiplyChunkLength *= length0
                if i == 0 {
                    // All chunks have been read. End of iteration
                    break loopBuffer
                }
            }
        }
        
        return uncompressedBytes
    }
    
    /// Find the first chunk indices that needs to be processed. If chunks are consecutive, a range is returned.
    func get_first_chunk_position() -> Range<Int> {
        var chunkStart = 0
        var chunkEnd = 1
        for i in 0..<dims.count {
            // E.g. 2..<4
            let chunkInThisDimensionLower = dimReadOffset[i] / chunks[i]
            let chunkInThisDimensionUpper = (dimReadOffset[i] + dimReadCount[i]).divideRoundedUp(divisor: chunks[i])
            let chunkInThisDimensionCount = chunkInThisDimensionUpper - chunkInThisDimensionLower
                            
            let firstChunkInThisDimension = chunkInThisDimensionLower
            let nChunksInThisDimension = dims[i].divideRoundedUp(divisor: chunks[i])
            chunkStart = chunkStart * nChunksInThisDimension + firstChunkInThisDimension
            if dimReadCount[i] == dims[i] {
                // The entire dimension is read
                chunkEnd = chunkEnd * nChunksInThisDimension
            } else {
                // Only parts of this dimension are read
                chunkEnd = chunkStart + chunkInThisDimensionCount
            }
        }
        return chunkStart..<chunkEnd
    }
    
    /// Find the next chunk index that should be processed to satisfy the read request. Nil if not further chunks need to be read
    func get_next_chunk_position(globalChunkNum: Int) -> Range<Int>? {
        var nextChunk = globalChunkNum
        
        // Move `globalChunkNum` to next position
        var rollingMultiplty = 1
        
        /// Number of consecutive chunks that can be read linearly
        var linearReadCount = 1
        
        var linearRead = true
        
        for i in (0..<dims.count).reversed() {
            // E.g. 10
            let nChunksInThisDimension = dims[i].divideRoundedUp(divisor: chunks[i])
            
            // E.g. 2..<4
            let chunkInThisDimensionLower = dimReadOffset[i] / chunks[i]
            let chunkInThisDimensionUpper = (dimReadOffset[i] + dimReadCount[i]).divideRoundedUp(divisor: chunks[i])
            let chunkInThisDimensionCount = chunkInThisDimensionUpper - chunkInThisDimensionLower
                            
            // Move forward by one
            nextChunk += rollingMultiplty
            // Check for overflow in limited read coordinates
            
            
            if i == dims.count-1 && dims[i] != dimReadCount[i] {
                // if fast dimension and only partially read
                linearReadCount = chunkInThisDimensionCount
                linearRead = false
            }
            if linearRead && dims[i] == dimReadCount[i] {
                // dimension is read entirely
                linearReadCount *= nChunksInThisDimension
            } else {
                // dimension is read partly, cannot merge further reads
                linearRead = false
            }
            
            let c0 = (nextChunk / rollingMultiplty) % nChunksInThisDimension
            if c0 != chunkInThisDimensionUpper && c0 != 0 {
                break // no overflow in this dimension, break
            }
            nextChunk -= chunkInThisDimensionCount * rollingMultiplty
            rollingMultiplty *= nChunksInThisDimension
            if i == 0 {
                // All chunks have been read. End of iteration
                return nil
            }
        }
        //print("Next chunk \(nextChunk), count \(linearReadCount), from \(globalChunkNum)")
        return nextChunk ..< nextChunk + linearReadCount
    }
}