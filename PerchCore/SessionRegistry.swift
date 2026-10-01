import Foundation

public enum SessionRegistry {
    public static func liveSessions() -> [SessionRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Paths.sessionsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
            .filter { $0.isInteractive && $0.isAlive }
    }
}
