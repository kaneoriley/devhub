import BuildIdentity
import Foundation

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else {
        throw NSError(domain: "BuildInfo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: BuildInfoTool SOURCE OUTPUT"])
    }
    try BuildIdentity.read(source: URL(fileURLWithPath: arguments[1]))
        .write(to: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
