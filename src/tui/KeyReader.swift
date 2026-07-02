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
        var buffer = [UInt8](repeating: 0, count: 8)
        let bytesRead = read(STDIN_FILENO, &buffer, buffer.count)
        guard bytesRead > 0 else { return .unknown }

        let first = buffer[0]
        
        // Ctrl+C is ASCII 3
        if first == 3 {
            return .ctrlC
        }
        
        if first == 27 { // ESC
            if bytesRead == 1 {
                return .escape
            }
            if buffer[1] == 91 { // '['
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
            let char = Character(UnicodeScalar(first))
            return .char(char)
        }
    }
}
