import Foundation
import IOKit

nonisolated final class SMCSensorReader {
    private enum Command: UInt8 {
        case kernelIndex = 2
        case readBytes = 5
        case readKeyInfo = 9
    }

    private struct KeyData {
        typealias Bytes = (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )

        struct Version {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }

        struct LimitData {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuLimit: UInt32 = 0
            var gpuLimit: UInt32 = 0
            var memoryLimit: UInt32 = 0
        }

        struct KeyInfo {
            var dataSize: IOByteCount32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }

        var key: UInt32 = 0
        var version = Version()
        var limitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private struct Value {
        let type: String
        let bytes: [UInt8]
    }

    private var connection: io_connect_t = 0

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            connection = 0
            return
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func value(for key: String) -> Double? {
        guard let value = read(key), !value.bytes.isEmpty else { return nil }
        let bytes = value.bytes

        switch value.type {
        case "ui8 ":
            return Double(bytes[0])
        case "ui16" where bytes.count >= 2:
            return Double(unsigned16(bytes))
        case "ui32" where bytes.count >= 4:
            return Double(unsigned32(bytes))
        case "sp1e" where bytes.count >= 2:
            return Double(unsigned16(bytes)) / 16_384
        case "sp3c" where bytes.count >= 2:
            return Double(unsigned16(bytes)) / 4_096
        case "sp4b" where bytes.count >= 2:
            return Double(unsigned16(bytes)) / 2_048
        case "sp5a" where bytes.count >= 2:
            return Double(unsigned16(bytes)) / 1_024
        case "sp69" where bytes.count >= 2:
            return Double(unsigned16(bytes)) / 512
        case "sp78" where bytes.count >= 2:
            return Double(unsigned16(bytes)) / 256
        case "sp87" where bytes.count >= 2:
            return Double(unsigned16(bytes)) / 128
        case "sp96" where bytes.count >= 2:
            return Double(unsigned16(bytes)) / 64
        case "spa5" where bytes.count >= 2:
            return Double(unsigned16(bytes)) / 32
        case "spb4" where bytes.count >= 2:
            return Double(unsigned16(bytes)) / 16
        case "spf0" where bytes.count >= 2:
            return Double(unsigned16(bytes))
        case "fpe2" where bytes.count >= 2:
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case "flt " where bytes.count >= 4:
            let float = bytes.withUnsafeBytes { raw in
                raw.loadUnaligned(as: Float.self)
            }
            return Double(float)
        default:
            return nil
        }
    }

    private func read(_ key: String) -> Value? {
        guard connection != 0, key.utf8.count == 4 else { return nil }

        var input = KeyData()
        var output = KeyData()
        input.key = fourCharacterCode(key)
        input.data8 = Command.readKeyInfo.rawValue
        guard call(&input, output: &output) == kIOReturnSuccess else { return nil }

        let size = Int(output.keyInfo.dataSize)
        guard size > 0, size <= 32 else { return nil }
        let type = string(from: output.keyInfo.dataType)

        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = Command.readBytes.rawValue
        guard call(&input, output: &output) == kIOReturnSuccess else { return nil }
        let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(size)) }
        return Value(type: type, bytes: bytes)
    }

    private func call(_ input: inout KeyData, output: inout KeyData) -> kern_return_t {
        var outputSize = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(
            connection,
            UInt32(Command.kernelIndex.rawValue),
            &input,
            MemoryLayout<KeyData>.stride,
            &output,
            &outputSize
        )
    }

    private func fourCharacterCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func string(from value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private func unsigned16(_ bytes: [UInt8]) -> UInt16 {
        (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    private func unsigned32(_ bytes: [UInt8]) -> UInt32 {
        (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }
}
