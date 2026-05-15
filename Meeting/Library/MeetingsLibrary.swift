import Foundation
import Combine
import os

/// In-memory index of the user-configurable meetings folder
/// (`~/Documents/Meetings/` by default). Watches the parent folder with
/// `DispatchSourceFileSystemObject` so newly-completed recordings
/// appear in the Library list within ~one tick of finishing transcription.
///
/// The Meetings folder is the canonical source of truth — `transcript.json`
/// gives speakers + duration, the folder name gives the recording date.
/// Per-meeting user metadata (title, tags, starred, custom speaker names)
/// layers on top via `library.json` at
/// `~/Library/Application Support/dev.fluke.meeting/`.
@MainActor
final class MeetingsLibrary: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []
    @Published var selection: MeetingRecord.ID?
    @Published var search: String = ""

    private(set) var meetingsRoot: URL
    private let libraryFileURL: URL
    private var overrides: LibraryOverrides
    private var fileSource: DispatchSourceFileSystemObject?

    // Cross-meeting speaker identity — optional so existing tests don't need
    // to pass a store. When nil, `loadRecord` skips suggestion computation.
    private let identityStore: IdentityStore?
    private let embeddingQueue: EmbeddingExtractionQueue?
    private let matchingConfig: MatchingConfig

    init(
        meetingsRoot: URL = AppPreferences.shared.meetingsFolderURL,
        identityStore: IdentityStore? = nil,
        embeddingQueue: EmbeddingExtractionQueue? = nil,
        matchingConfig: MatchingConfig = MatchingConfig()
    ) {
        self.meetingsRoot = meetingsRoot
        self.identityStore = identityStore
        self.embeddingQueue = embeddingQueue
        self.matchingConfig = matchingConfig

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleSupport = appSupport.appendingPathComponent("dev.fluke.meeting", isDirectory: true)
        try? FileManager.default.createDirectory(at: bundleSupport, withIntermediateDirectories: true)
        self.libraryFileURL = bundleSupport.appendingPathComponent("library.json")
        self.overrides = (try? LibraryOverrides.read(from: libraryFileURL)) ?? LibraryOverrides()

        try? FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        // First scan + watcher start are deferred to the next runloop so
        // construction stays fast and unit-test runners can attach to the
        // host app without hitting disk I/O during App init.
        Task { @MainActor [weak self] in
            self?.rescan()
            self?.startWatching()
        }
    }

    deinit {
        fileSource?.cancel()
    }

    /// Re-point the library at a new on-disk root. Cancels the previous
    /// file-system watcher, ensures the new directory exists, rescans
    /// from disk, then starts a fresh watcher. No-op if the URL is
    /// unchanged. Existing recordings under the previous root stay put
    /// — moving them is left to the user.
    func setMeetingsRoot(_ newRoot: URL) {
        guard newRoot.standardizedFileURL != meetingsRoot.standardizedFileURL else { return }
        fileSource?.cancel()
        fileSource = nil
        meetingsRoot = newRoot
        try? FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        rescan()
        startWatching()
    }

    // MARK: - Public API

    /// Rescan disk and refresh `meetings`. Called on file-system events
    /// and from `AppState.stopAndTranscribe()` once transcription writes
    /// the per-meeting JSONs.
    func rescan() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: meetingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let identitiesSnapshot = identityStore?.identities ?? []
        let queue = embeddingQueue
        let config = matchingConfig
        let records = folders.compactMap { folder -> MeetingRecord? in
            var isDir: ObjCBool = false
            let path = folder.path(percentEncoded: false)
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            guard isDir.boolValue else { return nil }
            return Self.loadRecord(
                folder: folder,
                override: overrides.meetings[folder.lastPathComponent],
                identities: identitiesSnapshot,
                embeddingQueue: queue,
                matchingConfig: config
            )
        }

        meetings = records.sorted { $0.recordedAt > $1.recordedAt }

        // Drop selection if it points at a folder that no longer exists.
        if let sel = selection, !meetings.contains(where: { $0.id == sel }) {
            selection = nil
        }
    }

    /// Update user metadata for a meeting. Persists to `library.json`
    /// atomically and triggers a UI refresh.
    func update(meeting id: MeetingRecord.ID, transform: (inout MeetingOverride) -> Void) {
        var current = overrides.meetings[id] ?? MeetingOverride()
        transform(&current)
        overrides.meetings[id] = current
        do {
            try overrides.write(to: libraryFileURL)
        } catch {
            NSLog("[Meeting/Library] library.json write failed: %@",
                  String(describing: error))
        }
        rescan()
    }

    /// Replace one speaker's profile in `<meeting>/speakers.json` and
    /// rescan. The transform receives the existing profile (or a fresh
    /// default seeded from the transcript's speaker label) so callers
    /// can mutate just the field they care about — display name,
    /// attendee mapping, etc. — without clobbering the others.
    func updateSpeaker(
        meeting id: MeetingRecord.ID,
        speakerID: SpeakerID,
        transform: (inout SpeakerProfile) -> Void
    ) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        var profiles = meeting.speakerProfiles
        if let idx = profiles.firstIndex(where: { $0.id == speakerID }) {
            transform(&profiles[idx])
        } else {
            // Loader always seeds a profile per transcript speaker, so
            // this fallback only kicks in for IDs the transcript
            // doesn't know about (shouldn't happen) — append rather
            // than drop the edit.
            var seed = SpeakerProfile(id: speakerID, displayName: speakerID.rawValue)
            transform(&seed)
            profiles.append(seed)
        }
        let file = SpeakerMapFile(speakers: profiles)
        do {
            try file.write(to: meeting.folder)
        } catch {
            NSLog("[Meeting/Library] speakers.json write failed: %@",
                  String(describing: error))
        }
        rescan()
    }

    /// Drop a context item from `<meeting>/context.json` and rescan.
    /// Also deletes the backing image file when the removed item is an
    /// image so we don't accumulate orphans on disk. Used by the
    /// Transcript Viewer's per-item delete affordance — the user
    /// curates which copied items get folded into the AI summary.
    func deleteContextItem(meeting id: MeetingRecord.ID, itemID: ContextItem.ID) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        let remaining = meeting.contextItems.filter { $0.id != itemID }
        guard remaining.count != meeting.contextItems.count else { return }

        if let removed = meeting.contextItems.first(where: { $0.id == itemID }),
           removed.kind == .image, let filename = removed.imageFilename {
            let imageURL = ContextCaptureFile.imagesFolder(in: meeting.folder)
                .appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: imageURL)
        }

        do {
            try ContextCaptureFile(items: remaining).write(to: meeting.folder)
        } catch {
            NSLog("[Meeting/Library] context.json rewrite failed: %@",
                  String(describing: error))
        }
        rescan()
    }

    /// Move a meeting's folder to the Trash and drop its override entry.
    /// Falls back to a hard delete if Trash isn't available (e.g. on a
    /// volume that doesn't support it). The watcher will fire a rescan
    /// shortly after, but we rescan synchronously so the UI updates
    /// immediately.
    func delete(meeting id: MeetingRecord.ID) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        do {
            try FileManager.default.trashItem(at: meeting.folder, resultingItemURL: nil)
        } catch {
            do {
                try FileManager.default.removeItem(at: meeting.folder)
            } catch {
                NSLog("[Meeting/Library] delete meeting failed: %@",
                      String(describing: error))
                return
            }
        }
        if overrides.meetings.removeValue(forKey: id) != nil {
            do {
                try overrides.write(to: libraryFileURL)
            } catch {
                NSLog("[Meeting/Library] library.json write after delete failed: %@",
                      String(describing: error))
            }
        }
        rescan()
    }

    // MARK: - Identity matching

    /// User confirmed `speaker_N == identity X`. Updates speakers.json
    /// (displayName + identityID) and folds the speaker's embedding into the
    /// global identity centroid via running-mean weighted by sampleSeconds.
    func applyIdentitySuggestion(_ suggestion: IdentitySuggestion, meeting: MeetingRecord.ID) {
        guard let store = identityStore else { return }
        guard let m = meetings.first(where: { $0.id == meeting }) else { return }
        guard let embFile = try? MeetingEmbeddingsFile.read(from: m.folder),
              let emb = embFile.embeddings.first(where: { $0.speakerID == suggestion.speakerID })
        else { return }
        guard let identity = store.identities.first(where: { $0.id == suggestion.identityID })
        else { return }

        store.updateCentroid(
            id: identity.id,
            newCentroid: emb.centroid,
            newSampleSeconds: emb.sampleSeconds,
            meetingFolder: m.folder.lastPathComponent
        )
        updateSpeaker(meeting: meeting, speakerID: suggestion.speakerID) { profile in
            profile.displayName = identity.displayName
            profile.identityID = identity.id
            if profile.email == nil, let email = identity.emails.first {
                profile.email = email
            }
        }
    }

    /// User dismissed a suggestion. Appended to per-meeting rejection log
    /// so we won't suggest the same pairing again for this meeting.
    func rejectIdentitySuggestion(_ suggestion: IdentitySuggestion, meeting: MeetingRecord.ID) {
        guard let m = meetings.first(where: { $0.id == meeting }) else { return }
        var embFile = (try? MeetingEmbeddingsFile.read(from: m.folder)) ?? MeetingEmbeddingsFile(
            schemaVersion: 1,
            embedderModel: SpeakerEmbedder.modelTag,
            embeddings: [],
            rejectedIdentities: [],
            embeddingFailed: false
        )
        embFile.appendRejection(Rejection(
            speakerID: suggestion.speakerID,
            identityID: suggestion.identityID
        ))
        try? embFile.write(to: m.folder)
        rescan()
    }

    /// User manually maps a speaker → person (not from suggestion). When an
    /// embedding is already cached for this speaker, either reuse an existing
    /// identity (email or displayName match) and fold this sample in, or
    /// create a new identity. If no embedding is available yet, just sets
    /// displayName — identity creation will happen when the embedding lands
    /// (on next manual edit after EmbeddingExtractionQueue completes).
    func createOrReuseIdentity(
        speakerID: SpeakerID,
        displayName: String,
        email: String?,
        meeting: MeetingRecord.ID
    ) {
        guard let store = identityStore else {
            updateSpeaker(meeting: meeting, speakerID: speakerID) { p in
                p.displayName = displayName
                if let email { p.email = email }
            }
            return
        }
        guard let m = meetings.first(where: { $0.id == meeting }) else { return }
        guard let embFile = try? MeetingEmbeddingsFile.read(from: m.folder),
              let emb = embFile.embeddings.first(where: { $0.speakerID == speakerID })
        else {
            updateSpeaker(meeting: meeting, speakerID: speakerID) { p in
                p.displayName = displayName
                if let email { p.email = email }
            }
            return
        }

        let lowerName = displayName.lowercased()
        let lowerEmail = email?.lowercased()
        let existing = store.identities.first { ident in
            if let lowerEmail, ident.emails.contains(lowerEmail) { return true }
            return ident.displayName.lowercased() == lowerName
        }
        let identityID: String
        if let existing {
            store.updateCentroid(
                id: existing.id,
                newCentroid: emb.centroid,
                newSampleSeconds: emb.sampleSeconds,
                meetingFolder: m.folder.lastPathComponent
            )
            if let lowerEmail, !existing.emails.contains(lowerEmail) {
                store.addEmail(id: existing.id, email: lowerEmail)
            }
            identityID = existing.id
        } else {
            identityID = store.create(
                displayName: displayName,
                email: email,
                centroid: emb.centroid,
                sampleSeconds: emb.sampleSeconds,
                meetingFolder: m.folder.lastPathComponent
            )
        }
        updateSpeaker(meeting: meeting, speakerID: speakerID) { profile in
            profile.displayName = displayName
            profile.identityID = identityID
            if let email { profile.email = email }
        }
    }

    /// Searched meetings used by the list column.
    var visibleMeetings: [MeetingRecord] {
        let trimmed = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return meetings }
        return meetings.filter { $0.title.lowercased().contains(trimmed) }
    }

    /// Three most recent meetings — drives the popover's RECENT section.
    var recent: [MeetingRecord] {
        Array(meetings.prefix(3))
    }

    /// Selected meeting record (resolved from the id), if any.
    var selectedMeeting: MeetingRecord? {
        guard let id = selection else { return nil }
        return meetings.first { $0.id == id }
    }

    /// Approximate disk usage of the Meetings folder. Reads file sizes
    /// recursively — fine for a few-hundred-folder library.
    func storageUsage() -> StorageUsage {
        var totalUsed: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: meetingsRoot,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if let size = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                                       .totalFileAllocatedSize {
                    totalUsed += Int64(size)
                }
            }
        }

        var freeBytes: Int64 = 0
        if let values = try? meetingsRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey]) {
            freeBytes = Int64(values.volumeAvailableCapacity ?? 0)
        }

        return StorageUsage(usedBytes: totalUsed, freeBytes: freeBytes)
    }

    // MARK: - Loaders

    private static func loadRecord(
        folder: URL,
        override: MeetingOverride?,
        identities: [Identity] = [],
        embeddingQueue: EmbeddingExtractionQueue? = nil,
        matchingConfig: MatchingConfig = MatchingConfig()
    ) -> MeetingRecord? {
        let folderName = folder.lastPathComponent
        let date = MeetingFolderName.date(from: folderName)

        // Parse transcript.json for duration + raw speakers (optional —
        // not all folders have one yet).
        var duration: TimeInterval?
        var transcriptSpeakers: [Speaker] = []
        var speakerCount = 0
        var hasTranscript = false

        let transcriptURL = folder.appendingPathComponent("transcript.json")
        if let data = try? Data(contentsOf: transcriptURL),
           let merged = try? JSONDecoder().decode(MergedTranscript.self, from: data) {
            hasTranscript = true
            duration = merged.duration
            speakerCount = merged.speakers.count
            transcriptSpeakers = merged.speakers
        }

        // Layer in speakers.json — the per-meeting identity map. When
        // missing, fall through to the transcript's default speaker
        // labels (no legacy override merge: customSpeakerNames in
        // library.json was retired when this file was introduced).
        let storedMap = (try? SpeakerMapFile.read(from: folder).speakers) ?? []
        let storedByID = Dictionary(uniqueKeysWithValues: storedMap.map { ($0.id, $0) })
        let speakerProfiles: [SpeakerProfile] = transcriptSpeakers.map { spk in
            storedByID[spk.id] ?? SpeakerProfile(id: spk.id, displayName: spk.displayName)
        }
        let speakers = speakerProfiles.map { $0.asSpeaker }

        // Load cached LLM summary if previously generated (U8b).
        let summary = try? Summary.read(from: folder)

        // Load attached calendar event if the user picked one at record
        // time. Drives the title fallback chain (calendar > timestamp).
        let calendarEvent = (try? CalendarEventFile.read(from: folder).event)

        // Names captured by AX-scraping Meet's video tiles during the
        // recording — fills in the people that EventKit-only attendees
        // couldn't enumerate (group invites, late joiners, etc.).
        // Re-apply the current heuristic at read time so meetings
        // recorded with a looser earlier filter (chat fragments,
        // "<Name> joined", emoji reactions, etc.) get cleaned up
        // automatically without re-scraping.
        let meetParticipants = (MeetParticipantsFile.read(from: folder)?.participants ?? [])
            .filter { MeetParticipantsScraper.looksLikeParticipantName($0) }

        // Clipboard + browser context captured during recording. Sorted
        // chronologically so the UI can render them in capture order.
        let contextItems = (ContextCaptureFile.read(from: folder)?.items ?? [])
            .sorted { $0.offset < $1.offset }

        // Title precedence: explicit user override > calendar event title
        // > formatted folder timestamp.
        let derivedTitle = calendarEvent?.title ?? folderTitle(folderName: folderName, date: date)
        let title = override?.title ?? derivedTitle

        // Cross-meeting identity suggestions — only computed when the caller
        // passed an `identities` snapshot. Embeddings file is loaded lazily:
        // present → match against identities; missing + has transcript →
        // enqueue extraction in the background (suggestions will appear on
        // the next rescan after the queue writes embeddings.json).
        var identitySuggestions: [IdentitySuggestion] = []
        if let embFile = try? MeetingEmbeddingsFile.read(from: folder),
           !embFile.embeddings.isEmpty,
           !identities.isEmpty,
           embFile.embedderModel == SpeakerEmbedder.modelTag {
            let attendeeEmails = (calendarEvent?.attendees ?? []).compactMap { $0.email }
            let ctx = MatchContext(
                attendeeEmails: attendeeEmails,
                meetParticipantNames: meetParticipants,
                meetingFolder: folder.lastPathComponent
            )
            // Filter to speakers that haven't been user-named yet — leave
            // ones already labelled (or with identityID set) alone.
            let unmappedSpeakerIDs = Set(speakerProfiles.compactMap { profile -> SpeakerID? in
                if profile.identityID != nil { return nil }
                if profile.displayName.hasPrefix("speaker_") { return profile.id }
                return nil
            })
            let activeEmbeddings = embFile.embeddings.filter { unmappedSpeakerIDs.contains($0.speakerID) }
            identitySuggestions = IdentityMatcher.match(
                embeddings: activeEmbeddings,
                identities: identities,
                context: ctx,
                rejected: embFile.rejectedIdentities,
                config: matchingConfig,
                now: Date()
            )
        } else if hasTranscript,
                  (try? MeetingEmbeddingsFile.read(from: folder)) == nil,
                  let queue = embeddingQueue {
            // Lazy backfill — fire-and-forget; next rescan picks up suggestions.
            Task { await queue.enqueue(meetingFolder: folder) }
        }

        return MeetingRecord(
            folder: folder,
            recordedAt: date,
            title: title,
            originalTitle: override?.title == nil ? nil : derivedTitle,
            duration: duration,
            speakerCount: speakerCount,
            speakers: speakers,
            speakerProfiles: speakerProfiles,
            appName: nil,
            tags: override?.tags ?? [],
            starred: override?.starred ?? false,
            hasTranscript: hasTranscript,
            summary: summary,
            calendarEvent: calendarEvent,
            meetParticipants: meetParticipants,
            contextItems: contextItems,
            identitySuggestions: identitySuggestions
        )
    }

    private static func folderTitle(folderName: String, date: Date) -> String {
        guard date != .distantPast else { return folderName }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - File-system watcher

    private func startWatching() {
        let path = meetingsRoot.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[Meeting/Library] open(%@) failed errno=%d", path, errno)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // The source dispatches on the main queue but the type system
            // doesn't know — assume isolation so we can call back into
            // MainActor-bound state directly.
            MainActor.assumeIsolated { self?.rescan() }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.fileSource = source
    }
}

struct StorageUsage: Sendable {
    let usedBytes: Int64
    let freeBytes: Int64

    var usedFormatted: String { ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file) }
    var freeFormatted: String { ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file) }
    var usedFraction: Double {
        let total = usedBytes + freeBytes
        guard total > 0 else { return 0 }
        return min(1.0, Double(usedBytes) / Double(total))
    }
}
