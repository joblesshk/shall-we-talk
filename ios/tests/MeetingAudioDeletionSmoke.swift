import Foundation

enum DiagLog {
    static func log(_ component: String, _ message: String) {}
}

@main
struct MeetingAudioDeletionSmoke {
    static func main() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let meetingID = UUID()
        let otherID = UUID()
        let names = [
            "\(meetingID.uuidString)-0.wav",
            "\(meetingID.uuidString)-complete.wav",
            ".\(meetingID.uuidString)-complete.wav.tmp",
            "legacy-segment.wav",
            "\(otherID.uuidString)-0.wav"
        ]
        for name in names {
            try Data("audio".utf8).write(to: dir.appendingPathComponent(name))
        }

        try MeetingAudioWriter.removeMeetingAudio(
            meetingID: meetingID,
            referencedFileNames: ["legacy-segment.wav"],
            in: dir)

        for name in names.dropLast() {
            assert(!fm.fileExists(atPath: dir.appendingPathComponent(name).path), "should delete \(name)")
        }
        assert(fm.fileExists(atPath: dir.appendingPathComponent(names.last!).path), "must preserve another meeting")

        let raceID = UUID()
        let segment = dir.appendingPathComponent("\(raceID.uuidString)-0.wav")
        var wav = Data("RIFF".utf8)
        wav.append(Data(repeating: 0, count: 4))
        wav.append(Data("WAVE".utf8))
        wav.append(Data(repeating: 0, count: 44 + 4 * 1_048_576))
        try wav.write(to: segment)
        let complete = dir.appendingPathComponent("\(raceID.uuidString)-complete.wav")
        let merge = DispatchGroup()
        merge.enter()
        DispatchQueue.global(qos: .utility).async {
            try? MeetingAudioWriter.combineWAVSegments([segment], to: complete)
            merge.leave()
        }
        try MeetingAudioWriter.removeMeetingAudio(meetingID: raceID, referencedFileNames: [], in: dir)
        merge.wait()
        assert(!fm.fileExists(atPath: segment.path), "segment must remain deleted during a concurrent merge")
        assert(!fm.fileExists(atPath: complete.path), "background merge must not recreate deleted audio")
        print("MeetingAudioDeletionSmoke: OK")
    }
}
