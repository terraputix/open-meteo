//
//  File.swift
//  
//
//  Created by Patrick Zippenfenig on 09.09.2024.
//

import Foundation
@_implementationOnly import CTurboPFor
@_implementationOnly import CHelper

/**
 TODO:
 - differnet compression implementation
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
    let dimRead: [Range<Int>]
    
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
    
    /// Actually read data from a file. Merges IO for optimal sizes
    /// TODO: The read offset calculation is not ideal
    func read_from_file<Backend: OmFileReaderBackend>(fn: Backend, into: UnsafeMutablePointer<Float>, chunkBuffer: UnsafeMutableRawPointer) {
        
        print("new read \(self)")
        
        var chunkIndex: Int? = get_first_chunk_position()
        
        let nChunks = number_of_chunks()
        
        fn.withUnsafeBytes({ ptr in
            /// Loop over index blocks
            while let chunkIndexStart = chunkIndex {
                let readIndexInstruction = get_next_index_read(chunkIndex: chunkIndexStart)
                chunkIndex = readIndexInstruction.nextChunk
                var chunkData: Int? = readIndexInstruction.indexChunkNumStart
                let indexEndChunk = readIndexInstruction.endChunk
                
                // actually "read" index data from file
                print("read index \(readIndexInstruction), chunkIndexRead=\(chunkData ?? -1), indexEndChunk=\(indexEndChunk)")
                let indexData = ptr.baseAddress!.advanced(by: OmHeader.length + readIndexInstruction.offset).assumingMemoryBound(to: UInt8.self)
                
                /// Loop over data blocks
                while let chunkDataStart = chunkData {
                    let readDataInstruction = get_next_data_read(chunkIndex: chunkDataStart, indexStartChunk: readIndexInstruction.indexChunkNumStart, indexEndChunk: indexEndChunk, indexData: indexData)
                    chunkData = readDataInstruction.nextChunk
                    
                    // actually "read" compressed chunk data from file
                    print("read data \(readDataInstruction)")
                    let dataData = ptr.baseAddress!.advanced(by: OmHeader.length + nChunks*8 + readDataInstruction.offset)
                    
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
    /// Modifies `globalChunkNum` to keep as a internal reference counter
    /// Should be called in a loop. Return `nil` once all blocks have been processed and the hyperchunk read is complete
    public func get_next_index_read(chunkIndex indexStartChunk: Int) -> (offset: Int, count: Int, indexChunkNumStart: Int, endChunk: Int, nextChunk: Int?) {
        
        var globalChunkNum = indexStartChunk
        var nextChunkOut: Int? = indexStartChunk
        
        /// loop to next chunk until the end is reached, consecutive reads are further appart than `io_size_merge` or the maximum read length is reached `io_size_max`
        while true {
            guard let next = get_next_chunk_position(globalChunkNum: globalChunkNum) else {
                // there is no next chunk anymore, finish processing the current one and then stop with the next call
                nextChunkOut = nil
                break
            }
            nextChunkOut = next
            
            guard (next - globalChunkNum)*8 <= io_size_merge, (next - indexStartChunk)*8 <= io_size_max else {
                // the next read would exceed IO limitons
                break
            }
            globalChunkNum = next
        }
        if indexStartChunk == 0 {
            return (0, (globalChunkNum + 1) * 8, indexStartChunk, globalChunkNum, nextChunkOut)
        }
        return ((indexStartChunk-1) * 8, (globalChunkNum - indexStartChunk + 1) * 8, indexStartChunk, globalChunkNum, nextChunkOut)
    }
    
    
    /// Data = index of global chunk num
    public func get_next_data_read(chunkIndex dataStartChunk: Int, indexStartChunk: Int, indexEndChunk: Int, indexData: UnsafeRawPointer) -> (offset: Int, count: Int, dataStartChunk: Int, dataLastChunk: Int, nextChunk: Int?) {
        var globalChunkNum = dataStartChunk
        var nextChunkOut: Int? = dataStartChunk
        
        // index is a flat Int64 array
        let data = indexData.assumingMemoryBound(to: Int.self)
        
        /// If the start index starts at 0, the entire array is shifted by one, because the start position of 0 is not stored
        let startOffset = indexStartChunk == 0 ? 1 : 0
        
        /// Index data relative to startindex, needs special care because startpos==0 reads one value less
        let startPos = dataStartChunk == 0 ? 0 : data.advanced(by: indexStartChunk - dataStartChunk - startOffset).pointee
        var endPos = data.advanced(by: dataStartChunk == 0 ? 0 : 1).pointee
        
        /// loop to next chunk until the end is reached, consecutive reads are further appart than `io_size_merge` or the maximum read length is reached `io_size_max`
        while true {
            guard let next = get_next_chunk_position(globalChunkNum: globalChunkNum), next <= indexEndChunk else {
                nextChunkOut = nil
                break
            }
            nextChunkOut = next
            
            let dataStartPos = data.advanced(by: next - indexStartChunk - startOffset).pointee
            let dataEndPos = data.advanced(by: next - indexStartChunk - startOffset + 1).pointee
            
            /// Merge and split IO requests
            if dataEndPos - startPos > io_size_max,
                dataStartPos - endPos > io_size_merge {
                break
            }
            endPos = dataEndPos
            globalChunkNum = next
        }
        //print("Read \(startPos)-\(endPos) (\(endPos - startPos) bytes)")
        return (startPos, endPos - startPos, dataStartChunk, globalChunkNum, nextChunkOut)
    }
    
    /// Decode multiple chunks inside `data`. Chunks are ordered strictly increasing by 1. Due to IO merging, a chunk might be read, that does not contain relevant data for the output.
    /// Returns number of processed bytes from input
    public func decode_chunks(globalChunkNum: Int, lastChunk: Int, data: UnsafeRawPointer, into: UnsafeMutablePointer<Float>, chunkBuffer: UnsafeMutableRawPointer) -> Int {

        // Note: Relays on the correct number of uncompressed bytes from the compression library...
        // Maybe we need a differnet way that is independenet of this information
        var pos = 0
        for chunkNum in globalChunkNum ... lastChunk {
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
        
        let chunkBuffer = chunkBuffer.assumingMemoryBound(to: UInt16.self)
        
        var rollingMultiplty = 1
        var rollingMultiplyChunkLength = 1
        var rollingMultiplyTargetCube = 1
        
        /// Read coordinate from temporary chunk buffer
        var d = 0
        
        /// Write coordinate to output cube
        var q = 0
        
        var lengthLast = 0
        
        var no_data = false
        
        /// Count length in chunk and find first buffer offset position
        for i in (0..<dims.count).reversed() {
            let nChunksInThisDimension = dims[i].divideRoundedUp(divisor: chunks[i])
            let c0 = (globalChunkNum / rollingMultiplty) % nChunksInThisDimension
            let length0 = min((c0+1) * chunks[i], dims[i]) - c0 * chunks[i]
            let chunkGlobal0 = c0 * chunks[i] ..< c0 * chunks[i] + length0
            
            if dimRead[i].upperBound <= chunkGlobal0.lowerBound || dimRead[i].lowerBound >= chunkGlobal0.upperBound {
                // There is no data in this chunk that should be read. This happens if IO is merged, combining mutliple read blocks.
                // The returned bytes count still needs to be computed
                //print("Not reading chunk \(globalChunkNum)")
                no_data = true
            }
            
            let clampedGlobal0 = chunkGlobal0.clamped(to: dimRead[i])
            let clampedLocal0 = clampedGlobal0.substract(c0 * chunks[i])
            
            if i == dims.count-1 {
                lengthLast = length0
            }
            
            /// start only!
            let d0 = clampedLocal0.lowerBound
            /// Target coordinate in hyperchunk. Range `0...dim0Read`
            let t0 = chunkGlobal0.lowerBound - dimRead[i].lowerBound + d0
            
            let q0 = t0 + intoCoordLower[i]
            
            d = d + rollingMultiplyChunkLength * d0
            q = q + rollingMultiplyTargetCube * q0
                            
            rollingMultiplty *= nChunksInThisDimension
            rollingMultiplyTargetCube *= intoCubeDimension[i]
            rollingMultiplyChunkLength *= length0
        }
        
        /// How many elements are in this chunk
        let lengthInChunk = rollingMultiplyChunkLength
        //print("lengthInChunk \(lengthInChunk), t sstart=\(d)")
        
        let mutablePtr = UnsafeMutablePointer(mutating: data.assumingMemoryBound(to: UInt8.self))
        let uncompressedBytes = p4nzdec128v16(mutablePtr, lengthInChunk, chunkBuffer)
        
        if no_data {
            return uncompressedBytes
        }
        
        // TODO multi dimensional encode/decode
        delta2d_decode(lengthInChunk / lengthLast, lengthLast, chunkBuffer)
        
        /// Loop over all values need to be copied to the output buffer
        loopBuffer: while true {
            //print("read buffer from pos=\(d) and write to \(q)")
            
            let val = chunkBuffer[d]
            if val == Int16.max {
                into.advanced(by: q).pointee = .nan
            } else {
                let unscaled = compression == .p4nzdec256logarithmic ? (powf(10, Float(val) / scalefactor) - 1) : (Float(val) / scalefactor)
                into.advanced(by: q).pointee = unscaled
            }
            
            
            // TODO for the last dimension, it would be better to have a range copy
            // The loop below could be expensive....
                            
            /// Move `q` and `d` to next position
            rollingMultiplty = 1
            rollingMultiplyTargetCube = 1
            rollingMultiplyChunkLength = 1
            for i in (0..<dims.count).reversed() {
                let nChunksInThisDimension = dims[i].divideRoundedUp(divisor: chunks[i])
                let c0 = (globalChunkNum / rollingMultiplty) % nChunksInThisDimension
                let length0 = min((c0+1) * chunks[i], dims[i]) - c0 * chunks[i]
                let chunkGlobal0 = c0 * chunks[i] ..< c0 * chunks[i] + length0
                let clampedGlobal0 = chunkGlobal0.clamped(to: dimRead[i])
                let clampedLocal0 = clampedGlobal0.substract(c0 * chunks[i])
                
                /// More forward
                d += rollingMultiplyChunkLength
                q += rollingMultiplyTargetCube
                
                let d0 = (d / rollingMultiplyChunkLength) % length0
                if d0 != clampedLocal0.upperBound && d0 != 0 {
                    break // no overflow in this dimension, break
                }
                
                d -= clampedLocal0.count * rollingMultiplyChunkLength
                q -= clampedLocal0.count * rollingMultiplyTargetCube
                
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
    
    /// Find the first chunk index that needs to be processed
    func get_first_chunk_position() -> Int {
        var globalChunkNum = 0
        for i in 0..<dims.count {
            let chunkInThisDimension = dimRead[i].divide(by: chunks[i])
            let firstChunkInThisDimension = chunkInThisDimension.lowerBound
            let nChunksInThisDimension = dims[i].divideRoundedUp(divisor: chunks[i])
            globalChunkNum = globalChunkNum * nChunksInThisDimension + firstChunkInThisDimension
        }
        return globalChunkNum
    }
    
    /// Find the next chunk index that should be processed to satisfy the read request. Nil if not further chunks need to be read
    func get_next_chunk_position(globalChunkNum: Int) -> Int? {
        var nextChunk = globalChunkNum
        
        // Move `globalChunkNum` to next position
        var rollingMultiplty = 1
        for i in (0..<dims.count).reversed() {
            // E.g. 10
            let nChunksInThisDimension = dims[i].divideRoundedUp(divisor: chunks[i])
            
            // E.g. 2..<4
            let chunkInThisDimension = dimRead[i].divide(by: chunks[i])
                            
            // Move forward by one
            nextChunk += rollingMultiplty
            // Check for overflow in limited read coordinates
            
            let c0 = (nextChunk / rollingMultiplty) % nChunksInThisDimension
            if c0 != chunkInThisDimension.upperBound && c0 != 0 {
                break // no overflow in this dimension, break
            }
            nextChunk -= chunkInThisDimension.count * rollingMultiplty
            rollingMultiplty *= nChunksInThisDimension
            if i == 0 {
                // All chunks have been read. End of iteration
                return nil
            }
        }
        return nextChunk
    }
}
