import Foundation
import ShallWeTalkCore

enum AppDataDirectory {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-meeting-" + UUID().uuidString)
    static func url() -> URL { directory }
}
enum DiagLog { static func log(_ component: String, _ message: String) {} }
enum CloudHistorySync {
    static let containerID = "review-no-cloud"
    static func documentsFolder() -> URL? { nil }
}

@main enum MeetingRepro {
    static func main() throws {
        let fm = FileManager.default
        let base = AppDataDirectory.directory
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("meetings.json")
        let seed = MeetingRecord(title: "existing meeting", startedAt: Date(), state: .transcribed, speakerInfoEnabled: false)
        let seedData = try JSONEncoder().encode([seed])
        // A directory at the file path deterministically makes the initial read fail.
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        let store = MeetingStore()
        try fm.removeItem(at: file)
        try seedData.write(to: file)
        _ = store.beginMeeting(speakerInfoEnabled: false)
        let disk = try JSONDecoder().decode([MeetingRecord].self, from: Data(contentsOf: file))
        precondition(disk.contains { $0.id == seed.id }, "recovered disk meeting was overwritten")
        // Actual cloud conversion must preserve segment identity for in-flight operations.
        let segment = MeetingSegment(index: 0, startedAt: Date(), audioFileName: "segment.wav")
        var local = seed
        local.segments = [segment]
        var remote = local.cloudRecord()
        remote.title = "remote title edit"
        remote.updatedAt = local.updatedAt.addingTimeInterval(1)
        let converted = MeetingRecord(fromCloud: remote, preservingAudioFrom: local)
        precondition(converted.segments[0].id == segment.id && converted.segments[0].audioFileName == segment.audioFileName)
        // A failed write is forgotten: the next timer tick does not retry it.
        try fm.removeItem(at: file)
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        store.setTitle(id: store.meetings[0].id, "title pending save")
        try fm.removeItem(at: file)
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        precondition(store.flush(), "save must retry after path recovery")
        precondition(fm.fileExists(atPath: file.path), "failed save was forgotten")
        let deleting = store.meetings[0]
        let audioName = deleting.id.uuidString + "-source.wav"
        let audio = store.audioURL(for: audioName)
        try Data([1, 2, 3]).write(to: audio)
        let stateFile = base.appendingPathComponent("meetings-state.json")
        try fm.removeItem(at: stateFile)
        try fm.createDirectory(at: stateFile, withIntermediateDirectories: false)
        precondition(!store.delete(id: deleting.id), "failed commit must not report success")
        precondition(fm.fileExists(atPath: audio.path), "audio removed before durable deletion")
        try fm.removeItem(at: stateFile)
        precondition(store.flush())
        precondition(!fm.fileExists(atPath: audio.path), "committed deletion must clean audio")
        precondition(!MeetingStore().meetings.contains { $0.id == deleting.id }, "deleted meeting resurrected")
        precondition(!store.replaceTranscript(meetingID: UUID(), segmentID: UUID(), utterances: []))
        print("PASS: meeting read recovery, save retry, durable deletion, stable segment identity")
    }
}
