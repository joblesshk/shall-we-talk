import Foundation

private final class RecorderHolder: @unchecked Sendable {
    let recorder = Recorder()
}

@main enum RecorderCallbackSmoke {
    static func main() {
        let holder = RecorderHolder()
        // No capture start: exercise callback ownership without microphone access.
        DispatchQueue.concurrentPerform(iterations: 5000) { index in
            if index.isMultiple(of: 2) {
                holder.recorder.onChunk = { _ in }
                holder.recorder.onLevel = { _ in }
            } else {
                holder.recorder.onChunk?(Data())
                holder.recorder.onLevel?(0)
                holder.recorder.onChunk = nil
                holder.recorder.onLevel = nil
            }
        }
        print("PASS: concurrent recorder callback replacement without microphone capture")
    }
}
