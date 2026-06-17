//
//  AirplaneTensorReadTests.swift
//  TailspotTests
//
//  Regression coverage for AirplaneDetector.logicalTensor — the MLMultiArray →
//  [Float] read. The original code blind-copied the backing buffer as
//  contiguous Float32, which scrambled every anchor when CoreML returned a
//  padded / non-contiguous output (FP16 compute on the Neural Engine), giving
//  impossible scores (>1) and zero-size boxes in the field — the bracket
//  snapped off the plane. These tests build MLMultiArrays with deliberate row
//  padding (the layout the old copy mishandled) and assert the strided read
//  reconstructs the logical row-major tensor without ever touching padding.
//

import Testing
import CoreML
@testable import Tailspot

@Suite("AirplaneDetector tensor read")
struct AirplaneTensorReadTests {

    /// Build a (1, 8400, 85) Float32 array whose rows are padded by `rowPad`
    /// extra elements (so `strides[1] = 85 + rowPad`). Real cell (a, c) holds a
    /// known value; padding cells hold a -999 sentinel that must never surface.
    private func makeArray(rowPad: Int) throws -> MLMultiArray {
        let anchors = AirplaneDetectionDecoder.anchorCount   // 8400
        let chans = AirplaneDetectionDecoder.anchorStride    // 85
        let rowStride = chans + rowPad
        let total = anchors * rowStride
        let ptr = UnsafeMutableRawPointer.allocate(
            byteCount: total * MemoryLayout<Float>.stride,
            alignment: MemoryLayout<Float>.alignment
        )
        let fp = ptr.bindMemory(to: Float.self, capacity: total)
        for a in 0 ..< anchors {
            for c in 0 ..< rowStride {
                fp[a * rowStride + c] = c < chans ? value(a, c) : -999
            }
        }
        return try MLMultiArray(
            dataPointer: ptr,
            shape: [1, anchors, chans] as [NSNumber],
            dataType: .float32,
            strides: [total, rowStride, 1] as [NSNumber],
            deallocator: { $0.deallocate() }
        )
    }

    /// Known per-cell value; distinct per (anchor, channel).
    private func value(_ a: Int, _ c: Int) -> Float { Float(a % 997) + Float(c) * 0.01 }

    @Test func contiguousReadIsRowMajor() throws {
        let arr = try makeArray(rowPad: 0)
        let flat = try #require(AirplaneDetector.logicalTensor(from: arr))
        #expect(flat.count == AirplaneDetectionDecoder.anchorCount * AirplaneDetectionDecoder.anchorStride)
        let chans = AirplaneDetectionDecoder.anchorStride
        #expect(flat[0] == value(0, 0))
        #expect(flat[9] == value(0, 9))                 // airplane class column
        #expect(flat[5 * chans + 9] == value(5, 9))
    }

    @Test func paddedRowsAreSkippedViaStrides() throws {
        // The layout that defeated the old blind contiguous copy.
        let arr = try makeArray(rowPad: 11)
        let flat = try #require(AirplaneDetector.logicalTensor(from: arr))
        let anchors = AirplaneDetectionDecoder.anchorCount
        let chans = AirplaneDetectionDecoder.anchorStride
        #expect(flat.count == anchors * chans)
        // The -999 padding must never appear in the logical tensor.
        #expect(!flat.contains(-999))
        // Real values land at their logical positions, not shifted by padding.
        #expect(flat[5 * chans + 9] == value(5, 9))
        #expect(flat[(anchors - 1) * chans + (chans - 1)] == value(anchors - 1, chans - 1))
    }

    @Test func wrongShapeReturnsNil() throws {
        let bad = try MLMultiArray(shape: [1, 100, 85], dataType: .float32)
        #expect(AirplaneDetector.logicalTensor(from: bad) == nil)
    }
}
