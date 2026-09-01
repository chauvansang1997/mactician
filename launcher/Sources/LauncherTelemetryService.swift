import AppKit
import Darwin
import Foundation
import ImageIO

enum LauncherMessageTrigger: String {
    case launcherStarted = "launcher_started"
    case gameClosed = "game_closed"
}

struct LauncherAnnouncement: Identifiable {
    let id: String
    let title: String
    let text: String
    let image: NSImage?
}

struct GameSessionTracker {
    private(set) var startedAt: Date?

    mutating func start(at date: Date = Date()) {
        guard startedAt == nil else { return }
        startedAt = date
    }

    mutating func finish(at date: Date = Date()) -> Int64? {
        guard let startedAt else { return nil }
        self.startedAt = nil
        return max(1, Int64(date.timeIntervalSince(startedAt)))
    }
}

enum LauncherTelemetryConsentState: String {
    case unknown
    case denied
    case granted
}

struct LauncherTelemetrySettings: Codable, Equatable {
    let profileID: String
    let effectsQualityID: String
    let displayWidth: Int
    let displayHeight: Int
    let displayDensity: Int
    let uiScalePercent: Int
    let guestMemoryMB: Int
    let guestCPUCores: Int

    init(
        profile: LaunchProfile,
        effectsQuality: EffectsQuality,
        uiScalePercent: Int,
        androidMemoryMB: Int,
        androidCPUCores: Int
    ) {
        profileID = profile.id
        effectsQualityID = effectsQuality.id
        displayWidth = profile.width
        displayHeight = profile.height
        displayDensity = profile.density
        self.uiScalePercent = uiScalePercent
        guestMemoryMB = androidMemoryMB
        guestCPUCores = androidCPUCores
    }

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case effectsQualityID = "effects_quality_id"
        case displayWidth = "display_width"
        case displayHeight = "display_height"
        case displayDensity = "display_density"
        case uiScalePercent = "ui_scale_percent"
        case guestMemoryMB = "guest_memory_mb"
        case guestCPUCores = "guest_cpu_cores"
    }
}

struct LauncherTelemetryDevice: Codable, Equatable {
    let modelIdentifier: String
    let macOSVersion: String
    let physicalMemoryMB: Int
    let logicalCPUCount: Int

    static func current(processInfo: ProcessInfo = .processInfo) -> LauncherTelemetryDevice {
        let version = processInfo.operatingSystemVersion
        return LauncherTelemetryDevice(
            modelIdentifier: normalizedModelIdentifier(hardwareModelIdentifier()),
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            physicalMemoryMB: Int(processInfo.physicalMemory / 1_048_576),
            logicalCPUCount: processInfo.processorCount
        )
    }

    static func normalizedModelIdentifier(_ value: String?) -> String {
        guard let value,
              value.range(
                of: #"^[0-9A-Za-z][0-9A-Za-z,_-]{0,63}$"#,
                options: .regularExpression
              ) != nil else {
            return "unknown"
        }
        return value
    }

    private static func hardwareModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0,
              size > 1,
              size <= 65 else {
            return nil
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: value)
    }

    enum CodingKeys: String, CodingKey {
        case modelIdentifier = "model_identifier"
        case macOSVersion = "macos_version"
        case physicalMemoryMB = "physical_memory_mb"
        case logicalCPUCount = "logical_cpu_count"
    }
}

final class LauncherTelemetryService {
    typealias Loader = (
        _ request: URLRequest,
        _ maximumBytes: Int,
        _ completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void
    ) -> Void

    static let currentConsentVersion = 1
    static let currentSnapshotVersion = 1

    private enum Constant {
        static let apiBaseURL = URL(string: "https://sergeinaumov.dev/mactician/api/")!
        static let firstSessionPendingKey = "telemetry.firstSession.pending.v2"
        static let firstSessionCompletedKey = "telemetry.firstSession.completed.v2"
        static let activationSnapshotPendingKey = "telemetry.activationSnapshot.pending.v1"
        static let activationSnapshotCompletedKey = "telemetry.activationSnapshot.completed.v1"
        static let dailyActivePendingEventsKey = "telemetry.dailyActive.pendingEvents.v1"
        static let dailyActiveLastCreatedDayKey = "telemetry.dailyActive.lastCreatedDay.v1"
        static let sessionSummaryPendingEventsKey = "telemetry.sessionSummary.pendingEvents.v2"
        static let noticeShownKey = "telemetry.noticeShown.v3"
        static let extendedConsentStateKey = "telemetry.extendedConsent.state.v1"
        static let extendedConsentVersionKey = "telemetry.extendedConsent.version.v1"
        static let extendedPendingEventsKey = "telemetry.extended.pendingEvents.v2"
        static let legacyPendingEventsKey = "telemetry.pendingEvents.v1"
        static let legacyInstallationIDKey = "telemetry.installationID.v1"
        static let shownMessagesKey = "telemetry.shownMessages.v1"
        static let maxExtendedPendingEvents = 16
        static let maxDailyActivePendingEvents = 8
        static let maxSessionSummaryPendingEvents = 64
        static let maxPendingBytes = 64 * 1024
        static let firstSessionLifetime: TimeInterval = 7 * 24 * 60 * 60
        static let maxShownMessages = 128
        static let maxMessageBytes = 16 * 1024
        static let maxImageBytes = 2 * 1024 * 1024
        static let maxImageDimension = 4_096
        static let maxImagePixels = 16_000_000
    }

    private struct FirstSessionEvent: Codable {
        let schemaVersion: Int
        let eventID: String
        let event: String
        let occurredOn: String
        let durationBucket: String
        let launcherVersion: String
        let launcherBuild: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case eventID = "event_id"
            case event
            case occurredOn = "occurred_on"
            case durationBucket = "duration_bucket"
            case launcherVersion = "launcher_version"
            case launcherBuild = "launcher_build"
        }
    }

    private struct PendingFirstSession: Codable {
        let createdAt: Date
        let event: FirstSessionEvent

        enum CodingKeys: String, CodingKey {
            case createdAt = "created_at"
            case event
        }
    }

    private struct ActivationSnapshotEvent: Codable {
        let schemaVersion: Int
        let eventID: String
        let event: String
        let snapshotVersion: Int
        let diagnosticsConsentState: String
        let diagnosticsConsentVersion: Int
        let launcherVersion: String
        let launcherBuild: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case eventID = "event_id"
            case event
            case snapshotVersion = "snapshot_version"
            case diagnosticsConsentState = "diagnostics_consent_state"
            case diagnosticsConsentVersion = "diagnostics_consent_version"
            case launcherVersion = "launcher_version"
            case launcherBuild = "launcher_build"
        }
    }

    private struct DiagnosticsEvent: Codable {
        let schemaVersion: Int
        let eventID: String
        let event: String
        let occurredAt: Date
        let durationSeconds: Int64
        let launcherVersion: String
        let launcherBuild: String
        let consentVersion: Int
        let launcherSettings: LauncherTelemetrySettings
        let device: LauncherTelemetryDevice

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case eventID = "event_id"
            case event
            case occurredAt = "occurred_at"
            case durationSeconds = "duration_seconds"
            case launcherVersion = "launcher_version"
            case launcherBuild = "launcher_build"
            case consentVersion = "consent_version"
            case launcherSettings = "launcher_settings"
            case device
        }
    }

    private struct DailyActiveEvent: Codable {
        let schemaVersion: Int
        let eventID: String
        let event: String
        let occurredOn: String
        let launcherVersion: String
        let launcherBuild: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case eventID = "event_id"
            case event
            case occurredOn = "occurred_on"
            case launcherVersion = "launcher_version"
            case launcherBuild = "launcher_build"
        }
    }

    private struct GameSessionSummaryEvent: Codable {
        let schemaVersion: Int
        let eventID: String
        let event: String
        let durationSeconds: Int64
        let launcherVersion: String
        let launcherBuild: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case eventID = "event_id"
            case event
            case durationSeconds = "duration_seconds"
            case launcherVersion = "launcher_version"
            case launcherBuild = "launcher_build"
        }
    }

    private enum PendingEvent {
        case firstSession(PendingFirstSession)
        case activationSnapshot(ActivationSnapshotEvent)
        case dailyActive(DailyActiveEvent)
        case sessionSummary(GameSessionSummaryEvent)
        case diagnostics(DiagnosticsEvent)

        var eventID: String {
            switch self {
            case let .firstSession(pending): return pending.event.eventID
            case let .activationSnapshot(event): return event.eventID
            case let .dailyActive(event): return event.eventID
            case let .sessionSummary(event): return event.eventID
            case let .diagnostics(event): return event.eventID
            }
        }
    }

    private struct MessageResponse: Decodable {
        let schemaVersion: Int
        let id: String
        let trigger: String
        let title: String
        let text: String
        let imageURL: URL?
        let showOnce: Bool

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case id
            case trigger
            case title
            case text
            case imageURL = "image_url"
            case showOnce = "show_once"
        }
    }

    private let queue = DispatchQueue(label: "dev.sergeinaumov.mactician.telemetry")
    private let defaults: UserDefaults
    private let apiBaseURL: URL
    private let launcherVersion: String
    private let launcherBuild: String
    private let device: LauncherTelemetryDevice
    private let loader: Loader
    private var isFlushing = false

    init(
        defaults: UserDefaults = .standard,
        apiBaseURL: URL = Constant.apiBaseURL,
        bundle: Bundle = .main,
        device: LauncherTelemetryDevice = .current(),
        loader: Loader? = nil
    ) {
        self.defaults = defaults
        self.apiBaseURL = apiBaseURL
        launcherVersion = Self.safeVersion(
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            fallback: "0.0.0"
        )
        launcherBuild = Self.safeBuild(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            fallback: "local"
        )
        self.device = device
        self.loader = loader ?? { request, maximumBytes, completion in
            SafeBoundedDataLoader.load(
                request: request,
                maximumBytes: maximumBytes,
                completion: completion
            )
        }
        migrateLegacyTelemetry()
        enforceConsentVersion()
        discardExpiredFirstSession(now: Date())
        queue.async { [weak self] in
            guard let self else { return }
            self.createActivationSnapshotIfNeeded()
            if !self.shouldShowNotice {
                self.createDailyActiveIfNeeded(on: Date())
            }
            _ = self.defaults.synchronize()
            self.flushNextEvent()
        }
    }

    var shouldShowNotice: Bool {
        !defaults.bool(forKey: Constant.noticeShownKey)
    }

    var isExtendedDiagnosticsEnabled: Bool {
        consentState == .granted
            && defaults.integer(forKey: Constant.extendedConsentVersionKey)
            == Self.currentConsentVersion
    }

    func completeNotice(extendedDiagnostics: Bool) {
        queue.sync {
            setConsentState(extendedDiagnostics ? .granted : .denied)
            defaults.set(true, forKey: Constant.noticeShownKey)
            createActivationSnapshotIfNeeded()
            createDailyActiveIfNeeded(on: Date())
            _ = defaults.synchronize()
            flushNextEvent()
        }
    }

    func setExtendedDiagnosticsEnabled(_ enabled: Bool) {
        queue.sync {
            setConsentState(enabled ? .granted : .denied)
            createActivationSnapshotIfNeeded()
            _ = defaults.synchronize()
            flushNextEvent()
        }
    }

    func recordGameSession(
        durationSeconds: Int64,
        launcherSettings: LauncherTelemetrySettings,
        endedAt: Date = Date()
    ) {
        let duration = max(1, durationSeconds)
        queue.sync {
            createFirstSessionIfNeeded(durationSeconds: duration, endedAt: endedAt)
            var summaries = loadSessionSummaryEvents()
            summaries.append(GameSessionSummaryEvent(
                schemaVersion: 2,
                eventID: UUID().uuidString.lowercased(),
                event: "game_session_summary",
                durationSeconds: duration,
                launcherVersion: launcherVersion,
                launcherBuild: launcherBuild
            ))
            saveSessionSummaryEvents(
                Array(summaries.suffix(Constant.maxSessionSummaryPendingEvents))
            )
            if isExtendedDiagnosticsEnabled {
                var events = loadDiagnosticsEvents()
                events.append(DiagnosticsEvent(
                    schemaVersion: 2,
                    eventID: UUID().uuidString.lowercased(),
                    event: "game_session_diagnostics",
                    occurredAt: endedAt,
                    durationSeconds: duration,
                    launcherVersion: launcherVersion,
                    launcherBuild: launcherBuild,
                    consentVersion: Self.currentConsentVersion,
                    launcherSettings: launcherSettings,
                    device: device
                ))
                saveDiagnosticsEvents(Array(events.suffix(Constant.maxExtendedPendingEvents)))
            } else {
                defaults.removeObject(forKey: Constant.extendedPendingEventsKey)
            }
            _ = defaults.synchronize()
            flushNextEvent()
        }
    }

    func fetchAnnouncement(
        trigger: LauncherMessageTrigger,
        completion: @escaping (LauncherAnnouncement?) -> Void
    ) {
        guard let url = Self.messageURL(
            apiBaseURL: apiBaseURL,
            trigger: trigger,
            launcherVersion: launcherVersion
        ) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        SafeBoundedDataLoader.load(request: request, maximumBytes: Constant.maxMessageBytes) {
            [weak self] result in
            guard let self else { return }
            guard case let .success((data, response)) = result else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if response.statusCode == 204 {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            guard response.statusCode == 200,
                  Self.isJSON(response),
                  let message = try? JSONDecoder().decode(MessageResponse.self, from: data),
                  Self.isValid(message: message, expectedTrigger: trigger) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if let imageURL = message.imageURL, Self.isAllowedImageURL(imageURL, apiBaseURL: apiBaseURL) {
                self.loadImage(from: imageURL) { image in
                    self.deliver(message: message, image: image, completion: completion)
                }
            } else {
                self.deliver(message: message, image: nil, completion: completion)
            }
        }
    }

    static func messageURL(
        apiBaseURL: URL,
        trigger: LauncherMessageTrigger,
        launcherVersion: String
    ) -> URL? {
        let endpoint = apiBaseURL.appendingPathComponent("v1/messages", isDirectory: false)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "trigger", value: trigger.rawValue),
            URLQueryItem(name: "version", value: launcherVersion)
        ]
        return components.url
    }

    private func flushNextEvent() {
        guard !isFlushing else { return }
        discardExpiredFirstSession(now: Date())
        let pending: PendingEvent?
        if let firstSession = loadFirstSession() {
            pending = .firstSession(firstSession)
        } else if let activationSnapshot = loadActivationSnapshot() {
            pending = .activationSnapshot(activationSnapshot)
        } else if let dailyActive = loadDailyActiveEvents().first {
            pending = .dailyActive(dailyActive)
        } else if let summary = loadSessionSummaryEvents().first {
            pending = .sessionSummary(summary)
        } else if isExtendedDiagnosticsEnabled {
            pending = loadDiagnosticsEvents().first.map(PendingEvent.diagnostics)
        } else {
            defaults.removeObject(forKey: Constant.extendedPendingEventsKey)
            pending = nil
        }
        guard let pending else { return }
        let body: Data?
        switch pending {
        case let .firstSession(value):
            body = Self.eventEncoder.encodeOrNil(value.event)
        case let .activationSnapshot(value):
            body = Self.eventEncoder.encodeOrNil(value)
        case let .dailyActive(value):
            body = Self.eventEncoder.encodeOrNil(value)
        case let .sessionSummary(value):
            body = Self.eventEncoder.encodeOrNil(value)
        case let .diagnostics(value):
            body = Self.eventEncoder.encodeOrNil(value)
        }
        guard let url = URL(string: "v1/events", relativeTo: apiBaseURL)?.absoluteURL,
              let body else {
            if case .activationSnapshot = pending { return }
            removePendingEvent(pending)
            flushNextEvent()
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        isFlushing = true
        loader(request, 1_024) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                self.isFlushing = false
                guard case let .success((_, response)) = result else { return }
                let status = response.statusCode
                if (200..<300).contains(status) {
                    self.completePendingEvent(pending)
                } else if case .activationSnapshot = pending {
                    return
                } else if status == 409 {
                    self.completePendingEvent(pending)
                } else if (400..<500).contains(status), status != 408, status != 429 {
                    self.terminatePendingEvent(pending)
                } else {
                    return
                }
                _ = self.defaults.synchronize()
                self.flushNextEvent()
            }
        }
    }

    private func createFirstSessionIfNeeded(durationSeconds: Int64, endedAt: Date) {
        guard !defaults.bool(forKey: Constant.firstSessionCompletedKey) else { return }
        if loadFirstSession() != nil {
            discardExpiredFirstSession(now: Date())
            return
        }
        let pending = PendingFirstSession(
            createdAt: Date(),
            event: FirstSessionEvent(
                schemaVersion: 2,
                eventID: UUID().uuidString.lowercased(),
                event: "first_game_session",
                occurredOn: Self.utcDay(for: endedAt),
                durationBucket: Self.durationBucket(for: durationSeconds),
                launcherVersion: launcherVersion,
                launcherBuild: launcherBuild
            )
        )
        guard let data = Self.eventEncoder.encodeOrNil(pending),
              data.count <= Constant.maxPendingBytes else {
            defaults.set(true, forKey: Constant.firstSessionCompletedKey)
            return
        }
        defaults.set(data, forKey: Constant.firstSessionPendingKey)
    }

    private func loadFirstSession() -> PendingFirstSession? {
        guard let data = defaults.data(forKey: Constant.firstSessionPendingKey),
              data.count <= Constant.maxPendingBytes,
              let pending = try? Self.eventDecoder.decode(PendingFirstSession.self, from: data) else {
            defaults.removeObject(forKey: Constant.firstSessionPendingKey)
            return nil
        }
        return pending
    }

    private func createActivationSnapshotIfNeeded() {
        guard !defaults.bool(forKey: Constant.activationSnapshotCompletedKey),
              loadActivationSnapshot() == nil,
              consentState == .granted || consentState == .denied else {
            return
        }
        let event = ActivationSnapshotEvent(
            schemaVersion: 2,
            eventID: UUID().uuidString.lowercased(),
            event: "activation_snapshot",
            snapshotVersion: Self.currentSnapshotVersion,
            diagnosticsConsentState: consentState.rawValue,
            diagnosticsConsentVersion: Self.currentConsentVersion,
            launcherVersion: launcherVersion,
            launcherBuild: launcherBuild
        )
        guard let data = Self.eventEncoder.encodeOrNil(event),
              data.count <= Constant.maxPendingBytes else {
            return
        }
        defaults.set(data, forKey: Constant.activationSnapshotPendingKey)
    }

    private func loadActivationSnapshot() -> ActivationSnapshotEvent? {
        guard let data = defaults.data(forKey: Constant.activationSnapshotPendingKey),
              data.count <= Constant.maxPendingBytes,
              let event = try? Self.eventDecoder.decode(ActivationSnapshotEvent.self, from: data) else {
            defaults.removeObject(forKey: Constant.activationSnapshotPendingKey)
            return nil
        }
        return event
    }

    private func createDailyActiveIfNeeded(on date: Date) {
        let day = Self.utcDay(for: date)
        guard defaults.string(forKey: Constant.dailyActiveLastCreatedDayKey) != day else {
            return
        }
        var events = loadDailyActiveEvents()
        events.append(DailyActiveEvent(
            schemaVersion: 2,
            eventID: UUID().uuidString.lowercased(),
            event: "daily_active",
            occurredOn: day,
            launcherVersion: launcherVersion,
            launcherBuild: launcherBuild
        ))
        events = Array(events.suffix(Constant.maxDailyActivePendingEvents))
        guard let data = Self.eventEncoder.encodeOrNil(events),
              data.count <= Constant.maxPendingBytes else {
            return
        }
        defaults.set(data, forKey: Constant.dailyActivePendingEventsKey)
        defaults.set(day, forKey: Constant.dailyActiveLastCreatedDayKey)
    }

    private func loadDailyActiveEvents() -> [DailyActiveEvent] {
        guard let data = defaults.data(forKey: Constant.dailyActivePendingEventsKey),
              data.count <= Constant.maxPendingBytes,
              let events = try? Self.eventDecoder.decode([DailyActiveEvent].self, from: data) else {
            defaults.removeObject(forKey: Constant.dailyActivePendingEventsKey)
            return []
        }
        return Array(events.suffix(Constant.maxDailyActivePendingEvents))
    }

    private func saveDailyActiveEvents(_ events: [DailyActiveEvent]) {
        guard !events.isEmpty else {
            defaults.removeObject(forKey: Constant.dailyActivePendingEventsKey)
            return
        }
        guard let data = Self.eventEncoder.encodeOrNil(events),
              data.count <= Constant.maxPendingBytes else {
            defaults.removeObject(forKey: Constant.dailyActivePendingEventsKey)
            return
        }
        defaults.set(data, forKey: Constant.dailyActivePendingEventsKey)
    }

    private func loadDiagnosticsEvents() -> [DiagnosticsEvent] {
        guard isExtendedDiagnosticsEnabled,
              let data = defaults.data(forKey: Constant.extendedPendingEventsKey),
              data.count <= Constant.maxPendingBytes,
              let events = try? Self.eventDecoder.decode([DiagnosticsEvent].self, from: data) else {
            defaults.removeObject(forKey: Constant.extendedPendingEventsKey)
            return []
        }
        return Array(events.suffix(Constant.maxExtendedPendingEvents))
    }

    private func loadSessionSummaryEvents() -> [GameSessionSummaryEvent] {
        guard let data = defaults.data(forKey: Constant.sessionSummaryPendingEventsKey),
              data.count <= Constant.maxPendingBytes,
              let events = try? Self.eventDecoder.decode(
                [GameSessionSummaryEvent].self,
                from: data
              ) else {
            defaults.removeObject(forKey: Constant.sessionSummaryPendingEventsKey)
            return []
        }
        return Array(events.suffix(Constant.maxSessionSummaryPendingEvents))
    }

    private func saveSessionSummaryEvents(_ events: [GameSessionSummaryEvent]) {
        guard !events.isEmpty else {
            defaults.removeObject(forKey: Constant.sessionSummaryPendingEventsKey)
            return
        }
        guard let data = Self.eventEncoder.encodeOrNil(events),
              data.count <= Constant.maxPendingBytes else {
            defaults.removeObject(forKey: Constant.sessionSummaryPendingEventsKey)
            return
        }
        defaults.set(data, forKey: Constant.sessionSummaryPendingEventsKey)
    }

    private func saveDiagnosticsEvents(_ events: [DiagnosticsEvent]) {
        guard !events.isEmpty else {
            defaults.removeObject(forKey: Constant.extendedPendingEventsKey)
            return
        }
        guard let data = Self.eventEncoder.encodeOrNil(events),
              data.count <= Constant.maxPendingBytes else {
            defaults.removeObject(forKey: Constant.extendedPendingEventsKey)
            return
        }
        defaults.set(data, forKey: Constant.extendedPendingEventsKey)
    }

    private func completePendingEvent(_ pending: PendingEvent) {
        switch pending {
        case .firstSession:
            defaults.set(true, forKey: Constant.firstSessionCompletedKey)
            defaults.removeObject(forKey: Constant.firstSessionPendingKey)
        case .activationSnapshot:
            defaults.set(true, forKey: Constant.activationSnapshotCompletedKey)
            defaults.removeObject(forKey: Constant.activationSnapshotPendingKey)
        case .dailyActive:
            removePendingEvent(pending)
        case .sessionSummary:
            removePendingEvent(pending)
        case .diagnostics:
            removePendingEvent(pending)
        }
    }

    private func terminatePendingEvent(_ pending: PendingEvent) {
        if case .firstSession = pending {
            defaults.set(true, forKey: Constant.firstSessionCompletedKey)
        }
        removePendingEvent(pending)
    }

    private func removePendingEvent(_ pending: PendingEvent) {
        switch pending {
        case .firstSession:
            defaults.removeObject(forKey: Constant.firstSessionPendingKey)
        case .activationSnapshot:
            defaults.removeObject(forKey: Constant.activationSnapshotPendingKey)
        case .dailyActive:
            saveDailyActiveEvents(
                loadDailyActiveEvents().filter { $0.eventID != pending.eventID }
            )
        case .sessionSummary:
            saveSessionSummaryEvents(
                loadSessionSummaryEvents().filter { $0.eventID != pending.eventID }
            )
        case .diagnostics:
            saveDiagnosticsEvents(
                loadDiagnosticsEvents().filter { $0.eventID != pending.eventID }
            )
        }
    }

    private func migrateLegacyTelemetry() {
        defaults.removeObject(forKey: Constant.legacyInstallationIDKey)
        defaults.removeObject(forKey: Constant.legacyPendingEventsKey)
    }

    private var consentState: LauncherTelemetryConsentState {
        LauncherTelemetryConsentState(
            rawValue: defaults.string(forKey: Constant.extendedConsentStateKey) ?? ""
        ) ?? .unknown
    }

    private func enforceConsentVersion() {
        if consentState == .granted,
           defaults.integer(forKey: Constant.extendedConsentVersionKey)
            != Self.currentConsentVersion {
            defaults.set(
                LauncherTelemetryConsentState.unknown.rawValue,
                forKey: Constant.extendedConsentStateKey
            )
            defaults.removeObject(forKey: Constant.extendedConsentVersionKey)
            defaults.removeObject(forKey: Constant.noticeShownKey)
        }
        if consentState == .denied,
           defaults.integer(forKey: Constant.extendedConsentVersionKey)
            != Self.currentConsentVersion {
            defaults.set(Self.currentConsentVersion, forKey: Constant.extendedConsentVersionKey)
        }
        if consentState == .unknown {
            defaults.removeObject(forKey: Constant.extendedConsentVersionKey)
            defaults.removeObject(forKey: Constant.noticeShownKey)
        }
        if consentState != .granted {
            defaults.removeObject(forKey: Constant.extendedPendingEventsKey)
        }
    }

    private func setConsentState(_ state: LauncherTelemetryConsentState) {
        defaults.set(state.rawValue, forKey: Constant.extendedConsentStateKey)
        if state == .granted || state == .denied {
            defaults.set(
                Self.currentConsentVersion,
                forKey: Constant.extendedConsentVersionKey
            )
        } else {
            defaults.removeObject(forKey: Constant.extendedConsentVersionKey)
        }
        if state != .granted {
            defaults.removeObject(forKey: Constant.extendedPendingEventsKey)
        }
    }

    private func discardExpiredFirstSession(now: Date) {
        guard let pending = loadFirstSession(),
              now.timeIntervalSince(pending.createdAt) > Constant.firstSessionLifetime else {
            return
        }
        defaults.removeObject(forKey: Constant.firstSessionPendingKey)
        defaults.set(true, forKey: Constant.firstSessionCompletedKey)
    }

    static func durationBucket(for durationSeconds: Int64) -> String {
        switch max(1, durationSeconds) {
        case ..<300: return "under_5m"
        case ..<900: return "5_15m"
        case ..<1_800: return "15_30m"
        case ..<3_600: return "30_60m"
        case ..<7_200: return "60_120m"
        case ...14_400: return "120_240m"
        default: return "over_240m"
        }
    }

    private static func utcDay(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private func loadImage(from url: URL, completion: @escaping (NSImage?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("image/png, image/jpeg", forHTTPHeaderField: "Accept")
        SafeBoundedDataLoader.load(request: request, maximumBytes: Constant.maxImageBytes) { result in
            guard case let .success((data, response)) = result,
                  response.statusCode == 200,
                  Self.isAllowedImageMIME(response.mimeType),
                  let image = Self.decodeSafeImage(data) else {
                completion(nil)
                return
            }
            completion(image)
        }
    }

    private func deliver(
        message: MessageResponse,
        image: NSImage?,
        completion: @escaping (LauncherAnnouncement?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            var shown = defaults.stringArray(forKey: Constant.shownMessagesKey) ?? []
            if message.showOnce && shown.contains(message.id) {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if message.showOnce {
                shown.removeAll(where: { $0 == message.id })
                shown.append(message.id)
                shown = Array(shown.suffix(Constant.maxShownMessages))
                defaults.set(shown, forKey: Constant.shownMessagesKey)
            }
            let announcement = LauncherAnnouncement(
                id: message.id,
                title: message.title,
                text: message.text,
                image: image
            )
            DispatchQueue.main.async { completion(announcement) }
        }
    }

    private static func safeVersion(_ value: String?, fallback: String) -> String {
        guard let value,
              value.range(
                of: #"^[0-9]{1,5}(?:\.[0-9]{1,5}){0,3}(?:[-+][0-9A-Za-z.-]{1,40})?$"#,
                options: .regularExpression
              ) != nil else {
            return fallback
        }
        return value
    }

    private static func safeBuild(_ value: String?, fallback: String) -> String {
        guard let value,
              value.range(of: #"^[0-9A-Za-z][0-9A-Za-z._-]{0,31}$"#, options: .regularExpression) != nil else {
            return fallback
        }
        return value
    }

    private static func isValid(
        message: MessageResponse,
        expectedTrigger: LauncherMessageTrigger
    ) -> Bool {
        message.schemaVersion == 1
            && message.trigger == expectedTrigger.rawValue
            && message.id.range(
                of: #"^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$"#,
                options: .regularExpression
            ) != nil
            && !message.title.isEmpty
            && message.title.utf8.count <= 120
            && !message.text.isEmpty
            && message.text.utf8.count <= 4_000
    }

    private static func isJSON(_ response: HTTPURLResponse) -> Bool {
        response.mimeType?.lowercased() == "application/json"
    }

    private static func isAllowedImageMIME(_ value: String?) -> Bool {
        value?.lowercased() == "image/png" || value?.lowercased() == "image/jpeg"
    }

    private static func isAllowedImageURL(_ url: URL, apiBaseURL: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.host?.lowercased() == apiBaseURL.host?.lowercased(),
              url.port == nil || url.port == 443,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        let prefix = apiBaseURL.appendingPathComponent("v1/images", isDirectory: true).path
        return url.path.hasPrefix(prefix) && !url.path.dropFirst(prefix.count).contains("/")
    }

    private static func decodeSafeImage(_ data: Data) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        let pixelWidth = width.intValue
        let pixelHeight = height.intValue
        guard pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= Constant.maxImageDimension,
              pixelHeight <= Constant.maxImageDimension,
              pixelWidth <= Constant.maxImagePixels / pixelHeight else {
            return nil
        }
        let decodeOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions) else {
            return nil
        }
        return NSImage(
            cgImage: decoded,
            size: NSSize(width: decoded.width, height: decoded.height)
        )
    }

    private static let eventEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let eventDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private enum SafeBoundedDataLoaderError: Error {
    case invalidResponse
    case responseTooLarge
}

private final class SafeBoundedDataLoader: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    typealias ResultValue = Result<(Data, HTTPURLResponse), Error>

    private let maximumBytes: Int
    private var completion: ((ResultValue) -> Void)?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var session: URLSession?
    private var exceededLimit = false

    private init(maximumBytes: Int, completion: @escaping (ResultValue) -> Void) {
        self.maximumBytes = maximumBytes
        self.completion = completion
    }

    static func load(
        request: URLRequest,
        maximumBytes: Int,
        completion: @escaping (ResultValue) -> Void
    ) {
        let loader = SafeBoundedDataLoader(maximumBytes: maximumBytes, completion: completion)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = max(request.timeoutInterval, 8)
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 1
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: loader, delegateQueue: delegateQueue)
        loader.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(SafeBoundedDataLoaderError.invalidResponse))
            return
        }
        let expected = response.expectedContentLength
        guard expected <= Int64(maximumBytes) else {
            exceededLimit = true
            completionHandler(.cancel)
            return
        }
        self.response = response
        if expected > 0 {
            data.reserveCapacity(Int(expected))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= maximumBytes - data.count else {
            exceededLimit = true
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if exceededLimit {
            finish(.failure(SafeBoundedDataLoaderError.responseTooLarge))
        } else if let error {
            finish(.failure(error))
        } else if let response {
            finish(.success((data, response)))
        } else {
            finish(.failure(SafeBoundedDataLoaderError.invalidResponse))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func finish(_ result: ResultValue) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

private extension JSONEncoder {
    func encodeOrNil<T: Encodable>(_ value: T) -> Data? {
        try? encode(value)
    }
}
