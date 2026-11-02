import Foundation

struct MirrorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
