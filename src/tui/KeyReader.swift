#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

import Foundation

public enum TUIKey: Equatable {
    case up
    case down
    case left
    case right
    case enter
    case tab
    case backspace
    case escape
    case char(Character)
    case ctrlC
    case unknown
}

public struct KeyReader {
    public static func readKey() -> TUIKey {
        readKey(readBytes: readFromStdin)
    }

    static func readKey(readBytes: (Int) -> [UInt8]) -> TUIKey {
        var buffer = readBytes(8)
        guard let first = buffer.first else { return .unknown }

        // Ctrl+C is ASCII 3
        if first == 3 {
            return .ctrlC
        }

        if first == 27 { // ESC
            if buffer.count == 1 {
                return .escape
            }
            if buffer[1] == 91 { // '['
                guard buffer.count >= 3 else { return .escape }
                switch buffer[2] {
                case 65: return .up    // 'A'
                case 66: return .down  // 'B'
                case 67: return .right // 'C'
                case 68: return .left  // 'D'
                default: break
                }
            }
            return .escape
        }

        switch first {
        case 10, 13:
            return .enter
        case 9:
            return .tab
        case 127, 8:
            return .backspace
        default:
            if first < 0x80 {
                return .char(Character(UnicodeScalar(first)))
            }
            guard let expectedLength = utf8Length(firstByte: first) else {
                return .unknown
            }
            while buffer.count < expectedLength {
                let next = readBytes(expectedLength - buffer.count)
                guard next.isEmpty == false else { return .unknown }
                buffer.append(contentsOf: next)
            }
            let bytes = Array(buffer.prefix(expectedLength))
            guard bytes.dropFirst().allSatisfy(isUTF8Continuation),
                  let string = String(bytes: bytes, encoding: .utf8),
                  string.count == 1,
                  let char = string.first else {
                return .unknown
            }
            return .char(char)
        }
    }

    private static func readFromStdin(maxCount: Int) -> [UInt8] {
        guard maxCount > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: maxCount)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return read(STDIN_FILENO, baseAddress, maxCount)
        }
        guard bytesRead > 0 else { return [] }
        return Array(buffer.prefix(bytesRead))
    }

    private static func utf8Length(firstByte: UInt8) -> Int? {
        switch firstByte {
        case 0xC2...0xDF:
            return 2
        case 0xE0...0xEF:
            return 3
        case 0xF0...0xF4:
            return 4
        default:
            return nil
        }
    }

    private static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        (0x80...0xBF).contains(byte)
    }
}
