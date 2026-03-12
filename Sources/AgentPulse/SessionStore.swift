import Foundation
import AgentPulseLib

// MARK: - Delegate

@MainActor
protocol SessionStoreDelegate: AnyObject {
    func sessionStoreDidUpdate()
}

// MARK: - SessionStore

@MainActor
final class SessionStore {
    private(set) var sessions: [String: Session] = [:]
    var settings = Settings()

    weak var delegate: SessionStoreDelegate?

    private var dispatchSource: DispatchSourceFileSystemObject?
    private var refreshTimer: Timer?
    private var lastMtime: TimeInterval = 0

    // MARK: - Load

    func loadStatus() {
        guard FileManager.default.fileExists(atPath: Constants.statusFile) else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: Constants.statusFile))
            var decoded = try JSONDecoder().decode(StatusFile.self, from: data)

            // Backfill symbols for sessions that predate the symbol pool
            var needsPersist = false
            for (key, session) in decoded.sessions where session.symbol == nil {
                let sym: String
                if let existing = decoded.symbolPool.assigned[key] {
                    sym = existing
                } else if let next = decoded.symbolPool.available.first {
                    decoded.symbolPool.available.removeFirst()
                    decoded.symbolPool.assigned[key] = next
                    sym = next
                } else {
                    sym = "?"
                }
                decoded.sessions[key]?.symbol = sym
                needsPersist = true
            }

            // Detect status transitions for notifications
            let oldSessions = sessions
            for (key, newSession) in decoded.sessions {
                let oldStatus = oldSessions[key]?.status
                if oldStatus != newSession.status {
                    postNotificationIfNeeded(key: key, session: newSession, oldStatus: oldStatus)
                }
            }

            sessions = decoded.sessions
            settings = decoded.settings
            // Prune pinned entries that reference non-existent sessions
            settings.pinnedSessions.removeAll { !sessions.keys.contains($0) }

            if needsPersist {
                withFileLock {
                    var current = readCurrentFile()
                    current.sessions = decoded.sessions
                    current.symbolPool = decoded.symbolPool
                    writeFile(current)
                }
            }
        } catch {
            // Ignore corrupt files
        }
    }

    /// Remove done sessions that have exceeded the auto-clear TTL.
    func clearExpiredSessions() {
        let keys = AgentPulseLib.expiredSessionKeys(sessions, ttlMinutes: settings.autoClearAfterMinutes, now: Date().timeIntervalSince1970)
        guard !keys.isEmpty else { return }
        removeSessions(keys)
    }

    /// Check if sessions with stored PIDs are still alive; mark dead ones as done.
    func reapStaleSessions() {
        let reaped = AgentPulseLib.reapStaleSessions(sessions)

        // Find sessions that changed status (running/waiting → done) or were removed (done → gone)
        let markedDone = reaped.filter { $0.value.status == "done" && sessions[$0.key]?.status != "done" }
        let removed = sessions.keys.filter { reaped[$0] == nil }

        guard !markedDone.isEmpty || !removed.isEmpty else { return }

        // Record to history before removing — this is our most reliable
        // "session truly exited" signal (dead PID on a "done" session).
        // SessionEnd/"closed" is faster when it fires, but not guaranteed.
        let existingIds = Set(SessionHistory.shared.load().map(\.sessionId))

        // For sessions just marked done: record immediately if they have a real summary
        for (key, session) in markedDone {
            sessions[key] = session
            if AgentPulseLib.shouldRecordToHistory(session: session, sessionId: key, existingIds: existingIds, pidAlive: false) {
                SessionHistory.shared.addEntry(from: session, key: key)
            }
        }

        for key in removed {
            if let session = sessions[key],
               AgentPulseLib.shouldRecordToHistory(session: session, sessionId: key, existingIds: existingIds, pidAlive: false) {
                SessionHistory.shared.addEntry(from: session, key: key)
            }
            sessions.removeValue(forKey: key)
        }

        withFileLock {
            var data = readCurrentFile()
            for (key, session) in markedDone {
                data.sessions[key]?.status = "done"
                data.sessions[key]?.summary = session.summary
                data.sessions[key]?.updatedAt = session.updatedAt
            }
            for key in removed {
                data.sessions.removeValue(forKey: key)
                // Release symbol back to pool
                if let sym = data.symbolPool.assigned.removeValue(forKey: key) {
                    data.symbolPool.available.append(sym)
                }
            }
            writeFile(data)
        }
    }

    // MARK: - Save settings (read-then-write, preserving sessions)

    func saveSettings() {
        withFileLock {
            var data = readCurrentFile()
            data.settings = settings
            writeFile(data)
        }
    }

    // MARK: - Remove sessions (read-then-write, preserving others)

    func removeSessions(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        withFileLock {
            var data = readCurrentFile()
            for key in keys {
                data.sessions.removeValue(forKey: key)
                // Release symbol back to pool
                if let sym = data.symbolPool.assigned.removeValue(forKey: key) {
                    data.symbolPool.available.append(sym)
                }
            }
            let keySet = Set(keys)
            data.settings.pinnedSessions.removeAll { keySet.contains($0) }
            writeFile(data)
        }
        // Update in-memory state
        for key in keys { sessions.removeValue(forKey: key) }
        let keySet = Set(keys)
        settings.pinnedSessions.removeAll { keySet.contains($0) }
    }

    func togglePin(_ key: String) {
        withFileLock {
            var data = readCurrentFile()
            if let idx = data.settings.pinnedSessions.firstIndex(of: key) {
                data.settings.pinnedSessions.remove(at: idx)
            } else {
                data.settings.pinnedSessions.append(key)
            }
            settings.pinnedSessions = data.settings.pinnedSessions
            writeFile(data)
        }
    }

    // MARK: - File watching

    func startWatching() {
        // Watch the directory (not the file) because atomic renames change the inode
        let dirPath = Constants.claudeDir
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.checkForFileChanges()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        dispatchSource = source

        // 1-second timer as fallback + spinner/duration refresh driver
        // Use .common mode so the timer fires even while NSMenu is open
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForFileChanges()
                self?.reapStaleSessions()
                self?.clearExpiredSessions()
                self?.delegate?.sessionStoreDidUpdate()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Notifications

    private func postNotificationIfNeeded(key: String, session: Session, oldStatus: String?) {
        // Handle "closed" regardless of notification settings — history must always record
        if session.status == "closed", oldStatus != "closed" {
            // /clear fires SessionEnd+SessionStart without actually exiting.
            // Don't record to history if PID is still alive.
            let pidAlive = session.pid.map { kill(Int32($0), 0) == 0 } ?? false
            let existingIds = Set(SessionHistory.shared.load().map(\.sessionId))
            if AgentPulseLib.shouldRecordToHistory(session: session, sessionId: key, existingIds: existingIds, pidAlive: pidAlive) {
                SessionHistory.shared.addEntry(from: session, key: key)
            }
            removeSessions([key])
            return
        }

        let wantsNotification = settings.notificationsEnabled
        let wantsSound = settings.soundEnabled
        guard wantsNotification || wantsSound else { return }

        let projectName = session.name
        switch session.status {
        case "waiting" where oldStatus != "waiting":
            let sound = settings.waitingSound
            if wantsNotification {
                NotificationManager.shared.postNotification(
                    title: "Claude Waiting: \(projectName)",
                    body: session.summary ?? "Needs your permission",
                    directory: session.directory,
                    tty: session.tty,
                    soundEnabled: wantsSound,
                    soundName: sound
                )
            } else if wantsSound {
                NotificationManager.shared.playSoundOnly(sound)
            }
        case "done" where oldStatus != "done":
            let sound = settings.doneSound
            if wantsNotification {
                NotificationManager.shared.postNotification(
                    title: "Claude Done: \(projectName)",
                    body: session.summary ?? "Finished",
                    directory: session.directory,
                    tty: session.tty,
                    soundEnabled: wantsSound,
                    soundName: sound
                )
            } else if wantsSound {
                NotificationManager.shared.playSoundOnly(sound)
            }
        default:
            break
        }
    }

    // MARK: - Private

    /// Acquire the same lock file used by update_status.py for safe concurrent access.
    private func withFileLock(_ body: () -> Void) {
        let lockPath = Constants.statusFile + ".lock"
        let fd = open(lockPath, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { body(); return }
        flock(fd, LOCK_EX)
        body()
        flock(fd, LOCK_UN)
        close(fd)
    }

    private func checkForFileChanges() {
        guard FileManager.default.fileExists(atPath: Constants.statusFile) else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: Constants.statusFile)
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if mtime != lastMtime {
                lastMtime = mtime
                loadStatus()
                delegate?.sessionStoreDidUpdate()
            }
        } catch {
            // Ignore
        }
    }

    private func readCurrentFile() -> StatusFile {
        guard FileManager.default.fileExists(atPath: Constants.statusFile) else {
            return StatusFile()
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: Constants.statusFile))
            return try JSONDecoder().decode(StatusFile.self, from: data)
        } catch {
            return StatusFile()
        }
    }

    private func writeFile(_ statusFile: StatusFile) {
        let dir = Constants.claudeDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let tmpPath = Constants.statusFile + ".tmp"
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(statusFile)
            try data.write(to: URL(fileURLWithPath: tmpPath))
            // POSIX rename() works even if dest exists (unlike FileManager.moveItem)
            guard rename(tmpPath, Constants.statusFile) == 0 else { return }
        } catch {
            // Ignore
        }
    }
}
