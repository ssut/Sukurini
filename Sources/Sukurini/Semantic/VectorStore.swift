import Accelerate
import Darwin
import Foundation

final class VectorStore {
    private static let scanChunk = 1024

    private let dimension: Int
    private let vectorURL: URL
    private let scaleURL: URL
    private let lock = NSLock()

    private var vectorDescriptor: Int32 = -1
    private var scaleDescriptor: Int32 = -1
    private var mappedVectors: UnsafeRawPointer?
    private var mappedScales: UnsafeRawPointer?
    private var mappedSlotCount = 0
    private var ready = false

    init?(dimension: Int, vectorURL: URL, scaleURL: URL) {
        guard dimension > 0 else { return nil }
        self.dimension = dimension
        self.vectorURL = vectorURL
        self.scaleURL = scaleURL

        do {
            try FileManager.default.createDirectory(at: vectorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            Log.vectors.error("directory create failed path=\(vectorURL.deletingLastPathComponent().path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        for url in [vectorURL, scaleURL] where !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                Log.vectors.error("file create failed path=\(url.path, privacy: .public)")
                return nil
            }
        }

        vectorDescriptor = open(vectorURL.path, O_RDWR)
        scaleDescriptor = open(scaleURL.path, O_RDWR)
        guard vectorDescriptor >= 0, scaleDescriptor >= 0 else {
            Log.vectors.error("open failed vectors=\(self.vectorDescriptor, privacy: .public) scales=\(self.scaleDescriptor, privacy: .public)")
            closeDescriptors()
            return nil
        }
        ready = true
        Log.vectors.info("store ready dim=\(dimension, privacy: .public) slots=\(self.slotCount, privacy: .public) path=\(vectorURL.path, privacy: .public)")
    }

    deinit {
        unmapLocked()
        closeDescriptors()
    }

    private func closeDescriptors() {
        if vectorDescriptor >= 0 { close(vectorDescriptor); vectorDescriptor = -1 }
        if scaleDescriptor >= 0 { close(scaleDescriptor); scaleDescriptor = -1 }
    }

    var slotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return slotCountLocked()
    }

    private func slotCountLocked() -> Int {
        var stats = stat()
        guard vectorDescriptor >= 0, fstat(vectorDescriptor, &stats) == 0 else { return 0 }
        return Int(stats.st_size) / dimension
    }

    private func growLocked(to slots: Int) -> Bool {
        let vectorBytes = off_t(slots * dimension)
        let scaleBytes = off_t(slots * MemoryLayout<Float>.size)
        var stats = stat()
        guard fstat(vectorDescriptor, &stats) == 0 else { return false }
        if stats.st_size < vectorBytes {
            guard ftruncate(vectorDescriptor, vectorBytes) == 0 else {
                Log.vectors.error("grow vectors failed slots=\(slots, privacy: .public) errno=\(errno, privacy: .public)")
                return false
            }
        }
        guard fstat(scaleDescriptor, &stats) == 0 else { return false }
        if stats.st_size < scaleBytes {
            guard ftruncate(scaleDescriptor, scaleBytes) == 0 else {
                Log.vectors.error("grow scales failed slots=\(slots, privacy: .public) errno=\(errno, privacy: .public)")
                return false
            }
        }
        unmapLocked()
        return true
    }

    private func unmapLocked() {
        if let pointer = mappedVectors {
            munmap(UnsafeMutableRawPointer(mutating: pointer), mappedSlotCount * dimension)
            mappedVectors = nil
        }
        if let pointer = mappedScales {
            munmap(UnsafeMutableRawPointer(mutating: pointer), mappedSlotCount * MemoryLayout<Float>.size)
            mappedScales = nil
        }
        mappedSlotCount = 0
    }

    private func ensureMappedLocked() -> Bool {
        let slots = slotCountLocked()
        guard slots > 0 else { return false }
        if mappedVectors != nil, mappedScales != nil, mappedSlotCount == slots { return true }
        unmapLocked()

        guard let vectors = mmap(nil, slots * dimension, PROT_READ, MAP_SHARED, vectorDescriptor, 0), vectors != MAP_FAILED else {
            Log.vectors.error("mmap vectors failed slots=\(slots, privacy: .public) errno=\(errno, privacy: .public)")
            return false
        }
        guard let scales = mmap(nil, slots * MemoryLayout<Float>.size, PROT_READ, MAP_SHARED, scaleDescriptor, 0), scales != MAP_FAILED else {
            munmap(vectors, slots * dimension)
            Log.vectors.error("mmap scales failed slots=\(slots, privacy: .public) errno=\(errno, privacy: .public)")
            return false
        }
        madvise(vectors, slots * dimension, MADV_SEQUENTIAL)
        mappedVectors = UnsafeRawPointer(vectors)
        mappedScales = UnsafeRawPointer(scales)
        mappedSlotCount = slots
        return true
    }

    @discardableResult
    func write(_ vector: [Float], at slot: Int) -> Bool {
        guard ready, vector.count == dimension, slot >= 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        guard growLocked(to: slot + 1) else { return false }

        var peak: Float = 0
        vDSP_maxmgv(vector, 1, &peak, vDSP_Length(dimension))
        guard peak > 0, peak.isFinite else {
            Log.vectors.error("write refused reason=degenerate slot=\(slot, privacy: .public)")
            return false
        }
        var bytes = [Int8](repeating: 0, count: dimension)
        let factor = 127.0 / peak
        for index in 0..<dimension {
            let scaled = (vector[index] * factor).rounded()
            bytes[index] = Int8(max(-127, min(127, scaled)))
        }
        var scale = peak / 127.0

        let vectorOffset = off_t(slot * dimension)
        let written = bytes.withUnsafeBytes { pwrite(vectorDescriptor, $0.baseAddress, dimension, vectorOffset) }
        guard written == dimension else {
            Log.vectors.error("pwrite vector failed slot=\(slot, privacy: .public) written=\(written, privacy: .public)")
            return false
        }
        let scaleOffset = off_t(slot * MemoryLayout<Float>.size)
        let scaleWritten = withUnsafeBytes(of: &scale) { pwrite(scaleDescriptor, $0.baseAddress, MemoryLayout<Float>.size, scaleOffset) }
        guard scaleWritten == MemoryLayout<Float>.size else {
            Log.vectors.error("pwrite scale failed slot=\(slot, privacy: .public)")
            return false
        }
        unmapLocked()
        return true
    }

    @discardableResult
    func clear(slots: [Int]) -> Int {
        guard ready, !slots.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        let zeros = [Int8](repeating: 0, count: dimension)
        var zeroScale: Float = 0
        var cleared = 0
        let available = slotCountLocked()
        for slot in slots where slot >= 0 && slot < available {
            let written = zeros.withUnsafeBytes { pwrite(vectorDescriptor, $0.baseAddress, dimension, off_t(slot * dimension)) }
            guard written == dimension else { continue }
            _ = withUnsafeBytes(of: &zeroScale) { pwrite(scaleDescriptor, $0.baseAddress, MemoryLayout<Float>.size, off_t(slot * MemoryLayout<Float>.size)) }
            cleared += 1
        }
        unmapLocked()
        Log.vectors.info("cleared requested=\(slots.count, privacy: .public) cleared=\(cleared, privacy: .public)")
        return cleared
    }

    func search(query: [Float], limit: Int) -> [(slot: Int, score: Float)] {
        guard ready, query.count == dimension, limit > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard ensureMappedLocked(), let vectors = mappedVectors, let scales = mappedScales else { return [] }

        let started = Date()
        let count = mappedSlotCount
        let base = vectors.assumingMemoryBound(to: Int8.self)
        let scaleBase = scales.assumingMemoryBound(to: Float.self)
        var scratch = [Float](repeating: 0, count: VectorStore.scanChunk * dimension)
        var raw = [Float](repeating: 0, count: VectorStore.scanChunk)
        var best: [(slot: Int, score: Float)] = []
        best.reserveCapacity(limit + 1)
        var worst: Float = -.greatestFiniteMagnitude

        query.withUnsafeBufferPointer { queryBuffer in
            scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                raw.withUnsafeMutableBufferPointer { rawBuffer in
                    var offset = 0
                    while offset < count {
                        let batch = min(VectorStore.scanChunk, count - offset)
                        vDSP_vflt8(base + offset * dimension, 1, scratchBuffer.baseAddress!, 1, vDSP_Length(batch * dimension))
                        cblas_sgemv(
                            CblasRowMajor, CblasNoTrans, Int32(batch), Int32(dimension), 1.0,
                            scratchBuffer.baseAddress!, Int32(dimension),
                            queryBuffer.baseAddress!, 1, 0.0, rawBuffer.baseAddress!, 1
                        )
                        for index in 0..<batch {
                            let slot = offset + index
                            let score = rawBuffer[index] * scaleBase[slot]
                            guard score > 0 else { continue }
                            if best.count < limit {
                                best.append((slot, score))
                                if best.count == limit {
                                    best.sort { $0.score > $1.score }
                                    worst = best[limit - 1].score
                                }
                            } else if score > worst {
                                best[limit - 1] = (slot, score)
                                var position = limit - 1
                                while position > 0 && best[position].score > best[position - 1].score {
                                    best.swapAt(position, position - 1)
                                    position -= 1
                                }
                                worst = best[limit - 1].score
                            }
                        }
                        offset += batch
                    }
                }
            }
        }

        best.sort { $0.score > $1.score }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.vectors.info("search slots=\(count, privacy: .public) hits=\(best.count, privacy: .public) ms=\(elapsed, privacy: .public)")
        return best
    }
}
