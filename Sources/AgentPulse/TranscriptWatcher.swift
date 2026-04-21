import Foundation
import AgentPulseLib

/// Watches each active session's transcript JSONL and recomputes context %
/// on every file extension. Gives the UI sub-second updates between hook
/// events, which otherwise only fire at turn boundaries.
@MainActor
final class TranscriptWatcher {
    weak var store: SessionStore?

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var debounceItems: [String: DispatchWorkItem] = [:]
    private let projectsDir: String = {
        (NSString(string: "~/.claude/projects").expandingTildeInPath)
    }()
    private let tailBytes = 65_536
    private let debounceInterval: TimeInterval = 0.25

    // MARK: - Lifecycle

    /// Start/stop watchers to match the store's current session set.
    /// Safe to call after every SessionStore refresh.
    func sync() {
        guard let store = store else { return }
        let active = Set(store.sessions.keys)
        let current = Set(sources.keys)

        for key in active.subtracting(current) {
            startWatcher(sessionId: key)
        }
        for key in current.subtracting(active) {
            stopWatcher(sessionId: key)
        }
    }

    private func startWatcher(sessionId: String) {
        guard let path = findJsonl(sessionId: sessionId) else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .extend,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRecompute(sessionId: sessionId, path: path)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources[sessionId] = source
        // Compute once on start so we don't wait for the next write
        scheduleRecompute(sessionId: sessionId, path: path)
    }

    private func stopWatcher(sessionId: String) {
        sources[sessionId]?.cancel()
        sources.removeValue(forKey: sessionId)
        debounceItems[sessionId]?.cancel()
        debounceItems.removeValue(forKey: sessionId)
    }

    // MARK: - Debounced recompute

    private func scheduleRecompute(sessionId: String, path: String) {
        debounceItems[sessionId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.recompute(sessionId: sessionId, path: path)
            }
        }
        debounceItems[sessionId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func recompute(sessionId: String, path: String) {
        guard let (tokens, model) = tailParseLatest(path: path) else { return }
        let window = contextWindow(forModel: model)
        let pct = (Double(tokens) / Double(window)) * 100.0
        let rounded = (pct * 10).rounded() / 10
        store?.updateLiveContextPct(sessionId: sessionId, pct: rounded)
    }

    // MARK: - JSONL parsing

    private func findJsonl(sessionId: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
        for proj in entries {
            let candidate = "\(projectsDir)/\(proj)/\(sessionId).jsonl"
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func tailParseLatest(path: String) -> (tokens: Int, model: String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let end: UInt64
        do {
            end = try handle.seekToEnd()
        } catch { return nil }

        let readFrom = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        do { try handle.seek(toOffset: readFrom) } catch { return nil }
        let data = handle.availableData
        guard !data.isEmpty else { return nil }

        // Split on newlines; drop a partial first line when we seeked mid-file.
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if readFrom > 0, lines.count > 1 {
            lines.removeFirst()
        }

        var latest: (Int, String)?
        for raw in lines {
            guard let d = parseLine(raw) else { continue }
            latest = d
        }
        return latest
    }

    private func parseLine(_ raw: Data.SubSequence) -> (Int, String)? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] else { return nil }
        guard (parsed["type"] as? String) == "assistant" else { return nil }
        guard let msg = parsed["message"] as? [String: Any] else { return nil }
        guard let model = msg["model"] as? String else { return nil }
        guard let usage = msg["usage"] as? [String: Any] else { return nil }
        let input = (usage["input_tokens"] as? Int) ?? 0
        let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        return (input + cacheCreate + cacheRead, model)
    }

    /// Same rule as update_status.py — opus = 1M, everything else = 200k.
    private func contextWindow(forModel model: String) -> Int {
        return model.lowercased().contains("opus") ? 1_000_000 : 200_000
    }
}
