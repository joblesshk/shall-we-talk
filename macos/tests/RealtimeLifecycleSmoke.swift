import Foundation

@main enum RealtimeLifecycleSmoke {
    static func main() async throws {
        weak var retained: OpenAIRealtimeSession?
        autoreleasepool {
            let session = OpenAIRealtimeSession(apiKey: "unused-test", model: "unused-test") { _ in }
            retained = session
            session.cancel()
            session.cancel()
        }
        let deadline = Date().addingTimeInterval(3)
        while retained != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(retained == nil, "Cancelled session retained by URLSession delegate cycle")
        let concurrent = OpenAIRealtimeSession(apiKey: "unused-test", model: "unused-test") { _ in }
        DispatchQueue.concurrentPerform(iterations: 2000) { index in
            if index.isMultiple(of: 3) { concurrent.cancel() }
            else if index.isMultiple(of: 2) { concurrent.feed(Data([0, 0, 0, 0])) }
            else { _ = concurrent.diagnostics; _ = concurrent.firstPartialMillis }
        }
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<100 { group.addTask { try await concurrent.finish() } }
            for try await result in group { precondition(result.isEmpty) }
        }
        do {
            try await concurrent.start()
            preconditionFailure("Cancelled session must not reconnect")
        } catch is CancellationError { }
        print("PASS: concurrent cancel/feed/diagnostics, repeated finish, and cancelled start rejection")
        print("PASS: repeated cancel releases unstarted realtime session; no network request")
    }
}
