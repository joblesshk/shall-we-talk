import Foundation
import ApplicationServices

@main enum DirectInsertionSmoke {
    static func main() {
        for after in [nil, "old", "unrelated longer text"] as [String?] {
            guard case .directWriteIssuedUnverified = TextInserter.directWriteOutcome(
                before: "old", after: after, text: "new") else {
                fatalError("Unverified direct write must not be reported as verified")
            }
        }
        guard case .verified = TextInserter.directWriteOutcome(
            before: "old", after: "oldnew", text: "new") else {
            fatalError("Visible new text must verify")
        }
        print("PASS: direct write readback missing, unchanged, unrelated growth and verified result")
        for (valid, held, expected) in [(false, false, false), (true, true, false), (true, false, true)] {
            var issued = false
            var result: Bool?
            TextInserter.performPaste(attemptsLeft: 0, isStillValid: { valid },
                modifiersHeld: { held }, issuePaste: { issued = true; return true },
                completion: { result = $0 })
            precondition(issued == expected && result == expected)
        }
        print("PASS: changed context and held modifiers prevent paste; valid released context permits it")
        let first = AXUIElementCreateApplication(100)
        let same = AXUIElementCreateApplication(100)
        let other = AXUIElementCreateApplication(101)
        precondition(TextInserter.sameFocusIfObservable(first, same))
        precondition(!TextInserter.sameFocusIfObservable(first, other))
        precondition(!TextInserter.sameFocusIfObservable(first, nil))
        precondition(TextInserter.sameFocusIfObservable(nil, nil))
        print("PASS: changed or lost observable target blocks paste; unavailable AX permits host paste")

        var held = true
        var pasteCount = 0
        var delayedResult: Bool?
        TextInserter.performPaste(attemptsLeft: 10, isStillValid: { true },
            modifiersHeld: { held }, issuePaste: { pasteCount += 1; return true },
            completion: { delayedResult = $0 })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { held = false }
        let deadline = Date().addingTimeInterval(2)
        while delayedResult == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(delayedResult == true && pasteCount == 1)
        print("PASS: shortcut modifier release emits exactly one paste")
    }
}
