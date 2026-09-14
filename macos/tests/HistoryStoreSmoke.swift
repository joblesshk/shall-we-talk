import Foundation
import ShallWeTalkCore

// The real platform store is compiled below. Only app-directory lookup and logging
// are replaced; every test passes a temporary directory explicitly.
enum AppDataDirectory { static func url() -> URL { fatalError("Tests must supply a directory") } }
enum DiagLog { static func log(_ component: String, _ message: String) {} }

@main
enum HistoryStoreSmoke {
    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("history-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }
        func record(_ text: String, audio: String? = nil) -> DictationRecord {
            DictationRecord(id: UUID(), date: Date(), rawText: text, cleanText: text, audioFileName: audio)
        }

        let cleanupDir = base.appendingPathComponent("cleanup")
        let cleanupStore = HistoryStore(directory: cleanupDir)
        if ProcessInfo.processInfo.environment["SWT_HISTORY_BENCH"] == "1" {
            let benchmarkDirectory = base.appendingPathComponent("benchmark")
            var writeMillis = 0.0
            let measuredPersistence = HistoryPersistence<DictationRecord>(directory: benchmarkDirectory,
                write: { data, url in
                    let start = Date()
                    defer { writeMillis += Date().timeIntervalSince(start) * 1000 }
                    try data.write(to: url, options: .atomic)
                })
            let benchmarkStore = HistoryStore(directory: benchmarkDirectory, persistence: measuredPersistence)
            let fixtures = (0..<3000).map { i in record("Synthetic record \(i) " + String(repeating: "测试文字", count: 80)) }
            let start = Date()
            benchmarkStore.replaceAll(fixtures)
            let initial = Date().timeIntervalSince(start) * 1000
            for iteration in 0..<5 {
                writeMillis = 0
                let appendStart = Date()
                benchmarkStore.append(record("one new dictation \(iteration)"))
                let total = Date().timeIntervalSince(appendStart) * 1000
                print("BENCH: replace=\(initial)ms append=\(total)ms write=\(writeMillis)ms other=\(total - writeMillis)ms")
            }
            require(HistoryStore(directory: base.appendingPathComponent("benchmark")).records.count == 3005,
                    "benchmark records not durable")
        }
        #if MAC_AUDIO_ASYNC
        let noChangeDir = base.appendingPathComponent("unchanged-cloud")
        var noChangeWrites = 0
        let noChangePersistence = HistoryPersistence<DictationRecord>(directory: noChangeDir,
            write: { data, url in
                noChangeWrites += 1
                try data.write(to: url, options: .atomic)
            })
        let noChangeStore = HistoryStore(directory: noChangeDir, persistence: noChangePersistence)
        noChangeStore.append(record("durable local text"))
        let writesBeforeMerge = noChangeWrites
        _ = noChangeStore.applyCloudMerge(cloudRecords: [])
        require(noChangeWrites == writesBeforeMerge, "unchanged cloud sync rewrote local history")
        let conflictRecord = record("newer manual edit")
        cleanupStore.append(conflictRecord)
        require(!cleanupStore.pushRevisionIfUnchanged(id: conflictRecord.id, instructionRaw: "edit",
            before: "old text", after: "late model response"), "late voice edit overwrote newer text")
        require(cleanupStore.pushRevisionIfUnchanged(id: conflictRecord.id, instructionRaw: "edit",
            before: "newer manual edit", after: "accepted edit"), "unchanged voice edit rejected")
        cleanupStore.delete(id: conflictRecord.id)
        require(!cleanupStore.pushRevisionIfUnchanged(id: conflictRecord.id, instructionRaw: "edit",
            before: "accepted edit", after: "resurrected"), "late voice edit recreated deleted record")
        let audioBytes = Data(repeating: 0x42, count: 1_048_576)
        guard let audioName = await cleanupStore.saveAudioAsync(audioBytes) else {
            fatalError("background audio save failed")
        }
        let savedAudio = try Data(contentsOf: cleanupDir.appendingPathComponent("audio").appendingPathComponent(audioName))
        require(savedAudio == audioBytes, "background audio save changed bytes")
        #endif
        var failedCleanup = record("识别原文")
        failedCleanup.cleanupStatus = .failed
        failedCleanup.recordingDuration = 18
        cleanupStore.append(failedCleanup)
        require(cleanupStore.replaceCleanup(expected: failedCleanup, cleanText: "整理完成"), "cleanup retry rejected unchanged record")
        let cleanupReloaded = HistoryStore(directory: cleanupDir).records[0]
        require(cleanupReloaded.rawText == failedCleanup.rawText && cleanupReloaded.cleanText == "整理完成", "retry overwrote ASR")
        require(cleanupReloaded.cleanupStatus == .succeeded && cleanupReloaded.recordingDuration == 18, "retry metadata not durable")
        cleanupStore.updateFinalText(id: failedCleanup.id, finalText: "稍后的手动稿")
        require(!cleanupStore.replaceCleanup(expected: cleanupReloaded, cleanText: "过期结果"), "retry overwrote later edit")
        require(cleanupStore.records[0].finalText == "稍后的手动稿", "later edit lost")

        let syncDir = base.appendingPathComponent("sync")
        let store = HistoryStore(directory: syncDir)
        let first = record("initial")
        store.append(first)
        let concurrent = record("new local recording")
        store.append(concurrent)
        store.updateFinalText(id: first.id, finalText: "local edit during pull")
        let remote = CloudHistoryRecord(id: UUID(), date: Date(), rawText: "remote", cleanText: "remote")
        store.applyCloudMerge(cloudRecords: [remote])
        require(store.records.contains { $0.id == concurrent.id }, "lost local append during pull")
        require(store.records.first { $0.id == first.id }?.finalText == "local edit during pull", "lost concurrent edit")
        let firstVersion = store.records.first { $0.id == first.id }!.editVersion
        let remoteEdit = CloudHistoryRecord(id: first.id, date: first.date, rawText: first.rawText,
            cleanText: first.cleanText, finalText: "next remote edit",
            editVersion: .next(after: firstVersion, originID: "other-device"))
        store.applyCloudMerge(cloudRecords: [remoteEdit])
        require(store.records.first { $0.id == first.id }?.finalText == "next remote edit", "second edit did not sync")
        let reloaded = HistoryStore(directory: syncDir)
        require(reloaded.records.count == 3, "sync changes not durable")
        reloaded.delete(id: first.id)
        reloaded.applyCloudMerge(cloudRecords: [remoteEdit])
        require(!reloaded.records.contains { $0.id == first.id }, "deleted record resurrected")

        let failureDir = base.appendingPathComponent("failure")
        var failWrite = false
        let persistence = HistoryPersistence<DictationRecord>(directory: failureDir, write: { data, url in
            if failWrite && url.lastPathComponent == "history.json" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let failingStore = HistoryStore(directory: failureDir, persistence: persistence)
        let withAudio = record("keep audio until committed", audio: "example.wav")
        failingStore.append(withAudio)
        let audio = failureDir.appendingPathComponent("audio/example.wav")
        try Data([0, 1]).write(to: audio)
        failWrite = true
        failingStore.delete(id: withAudio.id)
        require(failingStore.hasUnsavedChanges && failingStore.persistenceError != nil, "save failure hidden")
        require(FileManager.default.fileExists(atPath: audio.path), "audio removed before commit")
        let recovered = try persistence.load()
        require(recovered.records.isEmpty && recovered.deletions[withAudio.id.uuidString] != nil, "journal lost deletion")
        failWrite = false
        require(failingStore.retryPersistence(), "retry did not succeed")
        require(!failingStore.hasUnsavedChanges && failingStore.persistenceError == nil, "retry did not clear failure")
        require(!FileManager.default.fileExists(atPath: audio.path), "committed deletion left audio")
        require(HistoryStore(directory: failureDir).records.isEmpty, "deletion did not survive restart")

        let corruptDir = base.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptFile = corruptDir.appendingPathComponent("history.json")
        let corrupt = Data("broken history".utf8)
        try corrupt.write(to: corruptFile)
        let blocked = HistoryStore(directory: corruptDir)
        let pending = record("new recording while old file is unreadable")
        blocked.append(pending)
        require(blocked.persistenceError != nil, "corrupt history should block overwrite")
        let preserved = try Data(contentsOf: corruptFile)
        require(preserved == corrupt, "corrupt history was overwritten")
        try JSONEncoder().encode([first]).write(to: corruptFile)
        require(blocked.retryPersistence(), "repaired history did not recover")
        require(Set(blocked.records.map(\.id)) == Set([first.id, pending.id]), "recovery lost pending or original records")
        print("PASS: real HistoryStore (sync timing/continuous edit/deletion/failure/retry/audio/recovery)")

        // P1 回归(2026-09-06 审查):读取受阻期间导入的旧云记录不能在恢复后覆盖磁盘上
        // 更新的本地编辑与音频关联;同一窗口内的新增/编辑/删除必须保留;恢复失败要能
        // 重试;重启后磁盘状态必须正确。
        let recoveryDir = base.appendingPathComponent("recovery")
        let seedStore = HistoryStore(directory: recoveryDir)
        let newerLocal = record("original", audio: "newer-local.wav")
        seedStore.append(newerLocal)
        seedStore.updateFinalText(id: newerLocal.id, finalText: "newer local edit")
        let newerVersion = seedStore.records.first { $0.id == newerLocal.id }!.editVersion
        require(newerVersion != nil, "seed edit did not stamp a version")

        // 磁盘暂时不可读(权限/挂载等瞬时故障,不是文件损坏)。
        var denyRead = true
        let recoveryPersistence = HistoryPersistence<DictationRecord>(directory: recoveryDir, read: { url in
            if denyRead { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        let recoveryStore = HistoryStore(directory: recoveryDir, persistence: recoveryPersistence)
        require(recoveryStore.persistenceError != nil, "blocked store should report a read error")
        require(recoveryStore.records.isEmpty, "blocked store should not fabricate records")

        // 受阻期间:云端同步导入这条记录的旧版本(editVersion 更早、finalText 是旧云端
        // 稿,且没有音频关联——云端本就不存音频)。
        let staleCloud = CloudHistoryRecord(
            id: newerLocal.id, date: newerLocal.date, rawText: newerLocal.rawText,
            cleanText: newerLocal.cleanText, finalText: "stale cloud edit",
            editVersion: HistoryEditVersion(counter: 1, updatedAt: .distantPast, originID: "other-device"))
        let deferredOutcome = recoveryStore.applyCloudMerge(cloudRecords: [staleCloud])
        require(deferredOutcome.deferred, "cloud merge should defer while blocked")
        require(recoveryStore.records.isEmpty, "deferred cloud merge must not populate records while blocked")

        // 受阻期间:唯一可能存在的本地操作是这个窗口内新录的记录(旧记录读不到,
        // 不可能被界面编辑)——新录一条并编辑它,再新录一条并把它删除。
        let duringBlockKeep = record("new recording during block")
        recoveryStore.append(duringBlockKeep)
        recoveryStore.updateFinalText(id: duringBlockKeep.id, finalText: "edited during block")
        let duringBlockDiscard = record("recorded then deleted during block")
        recoveryStore.append(duringBlockDiscard)
        recoveryStore.delete(id: duringBlockDiscard.id)

        // 恢复先失败一次:缓冲的云端数据和这些纯本地操作都不能丢。
        require(!recoveryStore.retryPersistence(), "retry should still fail while read is denied")
        require(recoveryStore.records.contains { $0.id == duringBlockKeep.id }, "pending local record lost on failed retry")
        require(!recoveryStore.records.contains { $0.id == duringBlockDiscard.id }, "deleted-during-block record reappeared")

        // 磁盘恢复可读,重试成功。
        denyRead = false
        require(recoveryStore.retryPersistence(), "retry should succeed once read is restored")

        let recoveredRecord = recoveryStore.records.first { $0.id == newerLocal.id }
        require(recoveredRecord?.finalText == "newer local edit", "stale cloud edit overwrote newer local edit")
        require(recoveredRecord?.audioFileName == "newer-local.wav", "local audio association lost during recovery")
        require(recoveredRecord?.editVersion == newerVersion, "local edit version regressed")
        require(recoveryStore.records.contains { $0.id == duringBlockKeep.id && $0.finalText == "edited during block" },
                "local edit made during block was lost")
        require(!recoveryStore.records.contains { $0.id == duringBlockDiscard.id },
                "record deleted during block was resurrected")

        // 重启后(全新实例读磁盘)状态必须一致,不是只在这次进程内存里看着对。
        let restarted = HistoryStore(directory: recoveryDir)
        require(restarted.records.first { $0.id == newerLocal.id }?.finalText == "newer local edit",
                "disk state after restart lost the newer local edit")
        require(restarted.records.first { $0.id == newerLocal.id }?.audioFileName == "newer-local.wav",
                "disk state after restart lost the audio association")
        require(restarted.records.contains { $0.id == duringBlockKeep.id },
                "disk state after restart lost the block-window recording")
        require(!restarted.records.contains { $0.id == duringBlockDiscard.id },
                "disk state after restart resurrected a deleted record")
        print("PASS: real HistoryStore recovery vs stale cloud merge, block-window ops preserved (P1 2026-09-06)")

        // P2 回归(2026-09-06 审查):重识别只应推进 recognitionVersion,不能被
        // "整条记录版本未变"的写保护挡住;之后再做一次语音修改并撤销,finalText/
        // recognitionVersion 两个维度要各自独立、互不干扰。CloudHistorySync.push 依赖
        // 真实 iCloud 容器,不在这个沙盒环境里测——字段级合并的纯函数版本见
        // CloudHistoryRecordTests(mergeForPush)；这里只测 HistoryStore 本身的落盘状态。
        let recognitionDir = base.appendingPathComponent("recognition")
        let recognitionStore = HistoryStore(directory: recognitionDir)
        let recognized = record("original raw", audio: "recognition.wav")
        recognitionStore.append(recognized)

        recognitionStore.replaceRecognition(id: recognized.id, rawText: "corrected raw", cleanText: "corrected clean")
        let afterReRecognition = recognitionStore.records.first { $0.id == recognized.id }!
        require(afterReRecognition.recognitionVersion != nil, "replaceRecognition did not stamp a recognition version")
        require(afterReRecognition.finalText == nil, "re-recognition must not touch an unedited finalText")

        recognitionStore.pushRevision(id: recognized.id, instructionRaw: "改一下语气",
                                      before: "corrected clean", after: "revised by voice edit")
        let afterRevision = recognitionStore.records.first { $0.id == recognized.id }!
        require(afterRevision.finalText == "revised by voice edit", "voice revision did not update finalText")
        require(afterRevision.recognitionVersion == afterReRecognition.recognitionVersion,
                "voice revision must not touch recognitionVersion")

        recognitionStore.undoLastRevision(id: recognized.id)
        let afterUndo = recognitionStore.records.first { $0.id == recognized.id }!
        require(afterUndo.finalText == nil, "undo did not fall back to cleanText")
        require(afterUndo.cleanText == "corrected clean", "undo lost the re-recognized clean text")
        require(afterUndo.recognitionVersion == afterReRecognition.recognitionVersion,
                "undo must not touch recognitionVersion")

        let restartedRecognition = HistoryStore(directory: recognitionDir)
        let finalOnDisk = restartedRecognition.records.first { $0.id == recognized.id }!
        require(finalOnDisk.rawText == "corrected raw" && finalOnDisk.cleanText == "corrected clean",
                "disk state lost the re-recognized text")
        require(finalOnDisk.finalText == nil, "disk state lost the undo back to clean text")
        print("PASS: real HistoryStore re-recognition + voice revision + undo, recognitionVersion isolated (P2 2026-09-06)")
        recognitionStore.updateFinalText(id: recognized.id, finalText: "manual before")
        recognitionStore.pushRevision(id: recognized.id, instructionRaw: "edit", before: "manual before", after: "voice after")
        require(recognitionStore.undoLastRevision(id: recognized.id), "undo should apply")
        require(HistoryStore(directory: recognitionDir).records.first?.finalText == "manual before", "undo lost manual before")
        recognitionStore.pushRevision(id: recognized.id, instructionRaw: "edit", before: "manual before", after: "voice after")
        recognitionStore.updateFinalText(id: recognized.id, finalText: "later manual")
        require(!recognitionStore.undoLastRevision(id: recognized.id), "stale undo should be refused")
        require(HistoryStore(directory: recognitionDir).records.first?.finalText == "later manual", "stale undo lost latest edit")
        print("PASS: undo preserves manual edits before and after voice revisions")
    }
}
