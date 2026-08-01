import Foundation
import Compression

/// Сжатие/распаковка через системный Compression framework (zlib).
/// Без внешних зависимостей.
extension Data {

    func compressed() -> Data? {
        return Data.process(self, operation: COMPRESSION_STREAM_ENCODE)
    }

    func decompressed() -> Data? {
        return Data.process(self, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func process(_ input: Data, operation: compression_stream_operation) -> Data? {
        guard !input.isEmpty else { return Data() }

        // compression_stream нельзя создать через пустой init() в Swift — нужно
        // выделить память под структуру и инициализировать через compression_stream_init.
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }

        let initStatus = compression_stream_init(streamPtr, operation, COMPRESSION_ZLIB)
        guard initStatus != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(streamPtr) }

        let dstBufferSize = 64 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstBufferSize)
        defer { dstBuffer.deallocate() }

        var output = Data()

        return input.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data? in
            let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress!
            streamPtr.pointee.src_ptr = srcBase
            streamPtr.pointee.src_size = input.count
            streamPtr.pointee.dst_ptr = dstBuffer
            streamPtr.pointee.dst_size = dstBufferSize

            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

            while true {
                let s = compression_stream_process(streamPtr, flags)
                switch s {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = dstBufferSize - streamPtr.pointee.dst_size
                    if produced > 0 {
                        output.append(dstBuffer, count: produced)
                    }
                    streamPtr.pointee.dst_ptr = dstBuffer
                    streamPtr.pointee.dst_size = dstBufferSize
                    if s == COMPRESSION_STATUS_END {
                        return output
                    }
                case COMPRESSION_STATUS_ERROR:
                    return nil
                default:
                    return nil
                }
            }
        }
    }
}
