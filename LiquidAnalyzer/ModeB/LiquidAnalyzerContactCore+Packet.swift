import Foundation

extension LiquidAnalyzerContactCore {
    /// Binary wire-protocol constants for Phase R3 `MODE_B` USB-C CDC / BLE 5.2 L2CAP RF frames (`LA-R3-SPEC-001` v1.0.0).
    public enum WireProtocol {
        public static let syncWord: UInt16 = 0xAA55
        public static let protocolVersion: UInt16 = 0x0001
        public static let headerByteCount: Int = 24
        public static let payloadCRCByteCount: Int = 4
        public static let defaultSampleCount: Int = 8_800 // 220 µs @ 40 MSPS
        public static let maxSampleCount: Int = 32_768    // 819.2 µs @ 40 MSPS
        public static let adcFullScaleDivisor: Float = 2_048.0 // 12-bit signed (-2048...+2047)
    }

    public struct HardwareFrameHeader: Equatable, Sendable {
        public let protocolVersion: UInt16
        public let sequenceId: UInt32
        public let containerId: UInt16
        public let sampleCount: Int
        public let sampleRate: Double
        public let liquidTemperatureC: Double
        public let transducerTemperatureC: Double
        public let analogGainDb: Float

        public init(
            protocolVersion: UInt16 = WireProtocol.protocolVersion,
            sequenceId: UInt32,
            containerId: UInt16 = 0,
            sampleCount: Int,
            sampleRate: Double = 40_000_000.0,
            liquidTemperatureC: Double = 20.0,
            transducerTemperatureC: Double = 20.0,
            analogGainDb: Float = 24.0
        ) {
            self.protocolVersion = protocolVersion
            self.sequenceId = sequenceId
            self.containerId = containerId
            self.sampleCount = sampleCount
            self.sampleRate = sampleRate
            self.liquidTemperatureC = liquidTemperatureC
            self.transducerTemperatureC = transducerTemperatureC
            self.analogGainDb = analogGainDb
        }
    }

    public enum FrameDecodingError: Error, Equatable, Sendable {
        case invalidSyncWord(UInt16)
        case unsupportedProtocolVersion(UInt16)
        case invalidSampleCount(Int)
        case truncatedPayload(expectedBytes: Int, actualBytes: Int)
        case headerCRCMismatch(expected: UInt16, actual: UInt16)
        case payloadCRCMismatch(expected: UInt32, actual: UInt32)
    }

    // MARK: - CRC-16-CCITT (Poly 0x1021, Init 0xFFFF) & CRC-32 (IEEE 802.3, Poly 0xEDB88320)

    public static func crc16CCITT(_ bytes: UnsafeRawBufferPointer, count: Int) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        let limit = min(count, bytes.count)
        for i in 0..<limit {
            crc ^= UInt16(bytes[i]) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    public static func crc32IEEE(_ bytes: UnsafeRawBufferPointer, offset: Int, count: Int) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        let start = max(0, offset)
        let end = min(bytes.count, start + count)
        guard end > start else { return ~crc }
        for i in start..<end {
            crc ^= UInt32(bytes[i])
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~crc
    }

    // MARK: - Encoder (Reference Bench / Loopback Testing)

    /// Serializes a normalized `[-1.0 ... +1.0]` RF frame into the little-endian `LA-R3-SPEC-001` v1.0.0 binary packet:
    /// `Header (24 B, incl. CRC-16-CCITT) + Int16 Payload (2*N B) + Payload CRC-32 (4 B)`.
    public static func packHardwareRFFrame(
        header: HardwareFrameHeader,
        rfSignal: [Float]
    ) -> Data {
        let sampleCount = min(rfSignal.count, Int(UInt16.max))
        let payloadBytes = sampleCount * 2
        let totalBytes = WireProtocol.headerByteCount + payloadBytes + WireProtocol.payloadCRCByteCount
        var data = Data(count: totalBytes)

        let tempRaw = Int16(clamping: Int(round(header.liquidTemperatureC * 100.0)))
        let xducerTempRaw = Int16(clamping: Int(round(header.transducerTemperatureC * 100.0)))
        let gainRaw = Int16(clamping: Int(round(Double(header.analogGainDb) * 10.0)))
        let sampleRateU32 = UInt32(clamping: Int(round(max(0.0, header.sampleRate))))

        data.withUnsafeMutableBytes { raw in
            func writeLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
                var le = value.littleEndian
                withUnsafeBytes(of: &le) { src in
                    for b in 0..<MemoryLayout<T>.size {
                        raw[offset + b] = src[b]
                    }
                }
            }

            writeLE(WireProtocol.syncWord, at: 0x00)
            writeLE(header.protocolVersion, at: 0x02)
            writeLE(header.sequenceId, at: 0x04)
            writeLE(header.containerId, at: 0x08)
            writeLE(UInt16(sampleCount), at: 0x0A)
            writeLE(sampleRateU32, at: 0x0C)
            writeLE(tempRaw, at: 0x10)
            writeLE(xducerTempRaw, at: 0x12)
            writeLE(gainRaw, at: 0x14)

            let headerCRC = crc16CCITT(UnsafeRawBufferPointer(raw), count: 0x16)
            writeLE(headerCRC, at: 0x16)

            for i in 0..<sampleCount {
                let clamped = max(-1.0, min(0.9995, rfSignal[i].isFinite ? rfSignal[i] : 0.0))
                let quantized = Int16(clamping: Int(round(clamped * WireProtocol.adcFullScaleDivisor)))
                writeLE(quantized, at: WireProtocol.headerByteCount + i * 2)
            }

            let payloadCRC = crc32IEEE(
                UnsafeRawBufferPointer(raw),
                offset: WireProtocol.headerByteCount,
                count: payloadBytes
            )
            writeLE(payloadCRC, at: WireProtocol.headerByteCount + payloadBytes)
        }

        return data
    }

    // MARK: - Alignment-Safe Zero-Copy Decoder with Full Header CRC-16 + Payload CRC-32 Verification

    /// Unpacks and validates a framed little-endian binary A-Scan packet from USB-C CDC or BLE L2CAP.
    /// Uses alignment-safe unaligned loads so sliced `Data` buffers from stream readers never trap.
    public static func unpackHardwareRFFrame(data: Data) throws -> (HardwareFrameHeader, [Float]) {
        guard data.count >= WireProtocol.headerByteCount else {
            throw FrameDecodingError.truncatedPayload(
                expectedBytes: WireProtocol.headerByteCount,
                actualBytes: data.count
            )
        }

        return try data.withUnsafeBytes { rawBuffer in
            let sync = UInt16(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 0x00, as: UInt16.self))
            guard sync == WireProtocol.syncWord else {
                throw FrameDecodingError.invalidSyncWord(sync)
            }

            let version = UInt16(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 0x02, as: UInt16.self))
            guard version == WireProtocol.protocolVersion else {
                throw FrameDecodingError.unsupportedProtocolVersion(version)
            }

            let expectedHeaderCRC = UInt16(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 0x16, as: UInt16.self))
            let actualHeaderCRC = crc16CCITT(rawBuffer, count: 0x16)
            guard actualHeaderCRC == expectedHeaderCRC else {
                throw FrameDecodingError.headerCRCMismatch(expected: expectedHeaderCRC, actual: actualHeaderCRC)
            }

            let seq = UInt32(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 0x04, as: UInt32.self))
            let containerId = UInt16(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 0x08, as: UInt16.self))
            let sampleCount = Int(UInt16(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 0x0A, as: UInt16.self)))
            guard sampleCount >= 64 && sampleCount <= WireProtocol.maxSampleCount else {
                throw FrameDecodingError.invalidSampleCount(sampleCount)
            }

            let sampleRate = Double(UInt32(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 0x0C, as: UInt32.self)))
            let tempRaw = Int16(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 0x10, as: Int16.self))
            let xducerTempRaw = Int16(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 0x12, as: Int16.self))
            let gainRaw = Int16(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 0x14, as: Int16.self))

            let payloadBytes = sampleCount * 2
            let expectedTotal = WireProtocol.headerByteCount + payloadBytes + WireProtocol.payloadCRCByteCount
            guard rawBuffer.count >= expectedTotal else {
                throw FrameDecodingError.truncatedPayload(expectedBytes: expectedTotal, actualBytes: rawBuffer.count)
            }

            let expectedPayloadCRC = UInt32(
                littleEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: WireProtocol.headerByteCount + payloadBytes,
                    as: UInt32.self
                )
            )
            let actualPayloadCRC = crc32IEEE(
                rawBuffer,
                offset: WireProtocol.headerByteCount,
                count: payloadBytes
            )
            guard actualPayloadCRC == expectedPayloadCRC else {
                throw FrameDecodingError.payloadCRCMismatch(expected: expectedPayloadCRC, actual: actualPayloadCRC)
            }

            let header = HardwareFrameHeader(
                protocolVersion: version,
                sequenceId: seq,
                containerId: containerId,
                sampleCount: sampleCount,
                sampleRate: sampleRate,
                liquidTemperatureC: Double(tempRaw) / 100.0,
                transducerTemperatureC: Double(xducerTempRaw) / 100.0,
                analogGainDb: Float(gainRaw) / 10.0
            )

            var floatSamples = [Float](repeating: 0.0, count: sampleCount)
            let sampleScale: Float = 1.0 / WireProtocol.adcFullScaleDivisor
            for i in 0..<sampleCount {
                let rawSample = Int16(
                    littleEndian: rawBuffer.loadUnaligned(
                        fromByteOffset: WireProtocol.headerByteCount + i * 2,
                        as: Int16.self
                    )
                )
                floatSamples[i] = Float(rawSample) * sampleScale
            }

            return (header, floatSamples)
        }
    }

    /// End-to-end hardware packet pipeline: unpacks & validates binary USB-C/BLE RF data and solves for velocity & polarity.
    public func processHardwareRFFrame(data: Data) throws -> (HardwareFrameHeader, UltrasonicMeasurement?) {
        let (header, samples) = try Self.unpackHardwareRFFrame(data: data)
        let meas = processAScan(rfSignal: samples, temperatureCelsius: header.liquidTemperatureC)
        return (header, meas)
    }
}
