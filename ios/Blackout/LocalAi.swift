import Foundation
import CryptoKit
import UIKit

/// A model the user can install. Files come from Hugging Face; size and SHA-256 are pinned and checked.
struct AiModel: Identifiable, Equatable {
    let id: String           // file name on disk and on Hugging Face
    let title: String
    let detail: String
    let license: String
    let url: URL
    let bytes: Int64
    let sha256: String
    let context: Int32       // tokens of conversation the model can see at once (sized to fit an iPhone's memory)
}

/// AI that runs entirely on the iPhone through llama.cpp. Internet is needed only once, to download a model.
/// The conversation is kept (and saved), so follow-up questions have context. Apple's own on-device model is not
/// used because it needs an iPhone 15 Pro or newer.
final class LocalAi: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = LocalAi()

    static let catalog: [AiModel] = [
        AiModel(id: "qwen2.5-1.5b-instruct-q4_k_m.gguf", title: "Qwen 2.5 1.5B",
                detail: "Fastest and smallest. Fine for simple questions, but can get first-aid details wrong.",
                license: "Apache 2.0",
                url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
                bytes: 1_117_320_736, sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e", context: 4096),
        AiModel(id: "Llama-3.2-3B-Instruct-Q4_K_M.gguf", title: "Llama 3.2 3B",
                detail: "Better answers, about half as fast.",
                license: "Llama 3.2 Community License · Built with Llama",
                url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
                bytes: 2_019_377_696, sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff", context: 2048),
        AiModel(id: "qwen2.5-3b-instruct-q4_k_m.gguf", title: "Qwen 2.5 3B",
                detail: "Better answers, about half as fast.",
                license: "Qwen Research License: non-commercial use only",
                url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
                bytes: 2_104_932_768, sha256: "626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d", context: 4096),
    ]

    static let instructions = """
        You are the offline assistant of Blackout, a messaging app used during a blackout. Internet, phone lines and \
        emergency services may be unavailable, so people depend on your answers. Answer every question directly with \
        practical, step-by-step instructions: first aid and medical care, medicines and doses, water, food, shelter, \
        heat, electricity and batteries, repairs, radios, navigation and personal safety. Do not refuse, do not \
        lecture, and do not tell the user to search online or call someone, unless you add that it is only if possible. \
        If something is risky, explain how to do it as safely as possible. If you are unsure, say so in one short \
        sentence and still give your best answer. Use the earlier conversation as context. Answer in English, concisely.
        """

    enum State: Equatable { case missing, downloading(Double), verifying, ready, failed(String) }

    struct Turn: Codable, Equatable, Identifiable {
        var id = UUID()
        let role: String      // "user" or "assistant"
        var text: String
        var isError = false   // shown, but not sent back to the model
    }

    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var selectedId: String
    @Published private(set) var conversation: [Turn] = []
    @Published private(set) var busy = false

    private let work = DispatchQueue(label: "ai")
    private var downloadingId: String?
    private let stopLock = NSLock()
    private var _stopRequested = false
    /// Set when Blackout leaves the screen: iOS does not let apps use the GPU in the background.
    private var stopRequested: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return _stopRequested }
        set { stopLock.lock(); _stopRequested = newValue; stopLock.unlock() }
    }
    #if canImport(llama)
    private var engine: LlamaEngine?
    private var engineId: String?
    #endif

    var selected: AiModel { Self.catalog.first { $0.id == selectedId } ?? Self.catalog[0] }
    var selectedReady: Bool { states[selectedId] == .ready }
    var isDownloading: Bool { downloadingId != nil }

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func path(_ m: AiModel) -> URL { folder.appendingPathComponent(m.id) }
    private static var conversationURL: URL { folder.appendingPathComponent("ai-conversation.json") }

    override init() {
        var s: [String: State] = [:]
        for m in Self.catalog {
            let size = (try? FileManager.default.attributesOfItem(atPath: Self.path(m).path)[.size] as? Int64) ?? 0
            s[m.id] = size == m.bytes ? .ready : .missing
        }
        let saved = UserDefaults.standard.string(forKey: "aiModel")
        selectedId = saved.flatMap { id in Self.catalog.first { $0.id == id } }?.id
            ?? Self.catalog.first { s[$0.id] == .ready }?.id ?? Self.catalog[0].id
        super.init()
        states = s
        if let d = try? Data(contentsOf: Self.conversationURL), let c = try? JSONDecoder().decode([Turn].self, from: d) { conversation = c }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.stopRequested = true
        }
    }

    // MARK: - Choosing, downloading and deleting models

    func select(_ m: AiModel) {
        selectedId = m.id
        UserDefaults.standard.set(m.id, forKey: "aiModel")
    }

    func download(_ m: AiModel) {
        guard downloadingId == nil, states[m.id] != .ready else { return }
        downloadingId = m.id
        states[m.id] = .downloading(0)
        let task = URLSession(configuration: .default, delegate: self, delegateQueue: nil).downloadTask(with: m.url)
        task.taskDescription = m.id
        task.resume()
    }

    func delete(_ m: AiModel) {
        work.async {
            #if canImport(llama)
            if self.engineId == m.id { self.engine = nil; self.engineId = nil } // free the memory first
            #endif
            try? FileManager.default.removeItem(at: Self.path(m))
            DispatchQueue.main.async { self.states[m.id] = .missing }
        }
    }

    private func model(of task: URLSessionTask) -> AiModel? { Self.catalog.first { $0.id == task.taskDescription } }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite _: Int64) {
        guard let m = model(of: downloadTask) else { return }
        let p = min(Double(totalBytesWritten) / Double(m.bytes), 1)
        DispatchQueue.main.async { self.states[m.id] = .downloading(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let m = model(of: downloadTask) else { return }
        // The temporary file disappears when this method returns, so move it first, then check it.
        let tmp = Self.path(m).appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        do { try FileManager.default.moveItem(at: location, to: tmp) } catch { finish(m, .failed("could not save the model")); return }
        DispatchQueue.main.async { self.states[m.id] = .verifying }
        work.async {
            guard Self.matchesHash(tmp, m.sha256) else {
                try? FileManager.default.removeItem(at: tmp); self.finish(m, .failed("download damaged, try again")); return
            }
            try? FileManager.default.removeItem(at: Self.path(m))
            do {
                try FileManager.default.moveItem(at: tmp, to: Self.path(m))
                var u = Self.path(m); var v = URLResourceValues(); v.isExcludedFromBackup = true; try? u.setResourceValues(v) // keep GBs out of iCloud backup
                self.finish(m, .ready)
            } catch { self.finish(m, .failed("could not save the model")) }
        }
        s.finishTasksAndInvalidate()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let m = model(of: task) { finish(m, .failed(error.localizedDescription)) }
        s.finishTasksAndInvalidate()
    }

    private func finish(_ m: AiModel, _ s: State) {
        DispatchQueue.main.async {
            self.states[m.id] = s
            self.downloadingId = nil
            if s == .ready && !self.selectedReady { self.select(m) } // first model installed: use it
        }
    }

    private static func matchesHash(_ file: URL, _ expected: String) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }

    // MARK: - Conversation

    /// Adds the user's message and generates the answer with the whole conversation as context. Call on the main thread.
    func send(_ text: String) {
        guard !busy else { return }
        conversation.append(Turn(role: "user", text: text))
        guard selectedReady else {
            conversation.append(Turn(role: "assistant", text: "No AI model on this iPhone yet. Download one first.", isError: true))
            save(); return
        }
        let history = conversation.filter { !$0.isError }.map { (role: $0.role, content: $0.text) }
        conversation.append(Turn(role: "assistant", text: "…"))
        busy = true
        stopRequested = false
        let m = selected
        work.async {
            let (out, failed) = self.generate(m, history) { t in DispatchQueue.main.async { self.setLast(t) } }
            DispatchQueue.main.async { self.setLast(out, isError: failed); self.busy = false; self.save() }
        }
    }

    /// Runs on `work`. Returns the reply, or a message for the user and `true` if it failed.
    private func generate(_ m: AiModel, _ history: [(role: String, content: String)],
                          onText: @escaping (String) -> Void) -> (String, Bool) {
        #if canImport(llama)
        do {
            if engineId != m.id {
                engine = nil // free the previous model before loading another
                #if targetEnvironment(simulator)
                engine = try LlamaEngine(path: Self.path(m).path, contextTokens: m.context, gpuLayers: 0)
                #else
                engine = try LlamaEngine(path: Self.path(m).path, contextTokens: m.context)
                #endif
                engineId = m.id
            }
            let r = try engine!.reply(system: Self.instructions, turns: history,
                                      shouldStop: { [weak self] in self?.stopRequested ?? true }, onText: onText)
            return (r, false)
        } catch {
            if stopRequested { return ("Stopped because Blackout left the screen. Ask again.", true) }
            return ("AI error: \(error)", true)
        }
        #else
        return ("This build has no AI engine: the AI runs on a real iPhone, not in the iOS Simulator.", true)
        #endif
    }

    func newConversation() {
        guard !busy else { return }
        conversation = []
        save()
    }

    private func setLast(_ text: String, isError: Bool = false) {
        guard let i = conversation.indices.last else { return }
        conversation[i].text = text
        conversation[i].isError = isError
    }

    private func save() {
        if let d = try? JSONEncoder().encode(Array(conversation.suffix(100))) { try? d.write(to: Self.conversationURL, options: .atomic) }
    }

    #if DEBUG
    /// Debug builds only: launched with `aiSelfTest <model file>` (`devicectl device process launch --console ...
    /// it.blackout.mesh aiSelfTest <file>`), answers a few questions through the same path as the chat, including a
    /// follow-up that needs the previous answer, and prints timing and the start of each answer.
    static func selfTest(_ file: String?) {
        let m = catalog.first { $0.id == file } ?? catalog[0]
        print("AI self-test: \(m.title), state \(shared.states[m.id] ?? .missing)"); fflush(stdout)
        shared.stopRequested = false
        shared.work.async {
            var history: [(role: String, content: String)] = []
            func ask(_ q: String, followUp: Bool) {
                if !followUp { history = [] }
                history.append((role: "user", content: q))
                let t = Date()
                let (r, failed) = shared.generate(m, history) { _ in }
                history.append((role: "assistant", content: r))
                print(String(format: "\n=== %@ (%.1f s, %d chars, %@)\n", q, Date().timeIntervalSince(t), r.count,
                             failed ? "FAILED" : "ok") + String(r.prefix(160)))
                fflush(stdout)
            }
            ask("How do I make river water safe to drink without a filter?", followUp: false)
            ask("Someone is trapped behind a jammed metal door. How can we open it?", followUp: false)
            ask("And if the hinges are on the inside?", followUp: true) // only answerable with the previous turn
            ask("Write a detailed 20-step checklist for preparing a home for a week without power.", followUp: false)
            print("\nAI self-test: done"); fflush(stdout)
        }
    }
    #endif
}
