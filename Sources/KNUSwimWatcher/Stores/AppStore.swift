import AppKit
import Foundation
import WatcherCore

@MainActor
final class AppStore: ObservableObject {
    @Published var settings: WatcherSettings {
        didSet { persistSettings() }
    }
    @Published var passwordDraft = ""
    @Published private(set) var candidateRows: [CourseRow] = []
    @Published private(set) var selectionStatuses: [SelectionStatus] = []
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var statusMessage = "설정에서 계정과 수영반을 선택하세요."
    @Published private(set) var isBusy = false

    private let sportsClient = SportsClient()
    private let keychain = KeychainService()
    private let notifications = NotificationService()
    private let loginItem = LoginItemService()
    private let telemetry = AppTelemetry.shared
    private let defaults = UserDefaults.standard
    private var availabilityState: [String: Bool]
    private var monitorTask: Task<Void, Never>?
    private var didStart = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(WatcherSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
        availabilityState = UserDefaults.standard
            .dictionary(forKey: Self.availabilityKey) as? [String: Bool] ?? [:]
        settings.launchAtLogin = loginItem.isEnabled
        Task {
            await telemetry.info(
                "Lifecycle",
                "store_initialized",
                fields: [
                    "monitoring_enabled": String(settings.monitoringEnabled),
                    "selection_count": String(settings.selectedClasses.count)
                ]
            )
        }
        start()
        if ProcessInfo.processInfo.arguments.contains("--test-notification") {
            Task { [weak self] in
                await self?.testNotification()
            }
        }
    }

    deinit {
        monitorTask?.cancel()
    }

    var anyAvailable: Bool {
        selectionStatuses.contains { $0.availability.isAvailable }
    }

    var menuBarSymbol: String {
        if case .failed = connectionState {
            return "exclamationmark.triangle.fill"
        }
        if anyAvailable {
            return "drop.fill"
        }
        return "drop"
    }

    var lastCheckedText: String {
        guard let lastCheckedAt else { return "아직 확인하지 않음" }
        return lastCheckedAt.formatted(date: .omitted, time: .shortened)
    }

    var autoRegistrationSummary: String {
        if let result = settings.autoRegistrationResult {
            return result
        }
        if settings.autoRegistrationAttemptedCourseID != nil {
            return "신청 잠금 활성화됨"
        }
        return settings.autoRegistrationEnabled
            ? "대기 중 — 감시 목록의 위쪽 반부터 한 번만 신청"
            : "꺼짐"
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Task { await telemetry.info("Lifecycle", "monitor_started") }
        scheduleMonitoring()
        if settings.monitoringEnabled,
           !settings.account.isEmpty,
           !settings.selectedClasses.isEmpty {
            Task { await runCheck(manual: false) }
        } else if !settings.account.isEmpty,
                  settings.selectedClasses.isEmpty {
            Task { await refreshCourses() }
        }
    }

    func saveCredentials() async {
        await telemetry.info("Auth", "credentials_save_started")
        let account = settings.account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else {
            await telemetry.error("Auth", "credentials_save_rejected", fields: ["reason": "missing_account"])
            fail("아이디를 입력하세요.")
            return
        }
        guard !passwordDraft.isEmpty else {
            await telemetry.error("Auth", "credentials_save_rejected", fields: ["reason": "missing_password"])
            fail("비밀번호를 입력하세요.")
            return
        }
        do {
            try keychain.save(password: passwordDraft, account: account)
            settings.account = account
            passwordDraft = ""
            defaults.set(true, forKey: "watcher.hasConfiguredAccount")
            statusMessage = "계정 정보를 Keychain에 저장했습니다."
            await telemetry.info("Auth", "credentials_saved_to_keychain")
            await refreshCourses()
        } catch {
            await telemetry.error(
                "Auth",
                "credentials_save_failed",
                fields: ["error_type": errorType(error)]
            )
            fail(error.localizedDescription)
        }
    }

    func refreshCourses() async {
        guard !isBusy else {
            await telemetry.debug("Monitor", "course_refresh_skipped", fields: ["reason": "busy"])
            return
        }
        guard !settings.account.isEmpty else {
            await telemetry.error("Monitor", "course_refresh_rejected", fields: ["reason": "missing_account"])
            fail("먼저 계정 정보를 저장하세요.")
            return
        }
        await telemetry.info("Monitor", "course_refresh_started")
        isBusy = true
        connectionState = .checking
        statusMessage = "로그인하고 수영반 목록을 불러오는 중…"
        defer { isBusy = false }

        do {
            let password = try keychain.read(account: settings.account)
            let rows = try await sportsClient.fetchCourseRows(
                account: settings.account,
                password: password
            )
            candidateRows = SportsClient.candidateRows(from: rows)
            connectionState = .connected
            statusMessage = candidateRows.isEmpty
                ? "로그인 성공. 현재 등록 목록에 수영반이 없습니다."
                : "수영반 \(candidateRows.count)개를 반·시간별로 불러왔습니다."
            await telemetry.info(
                "Monitor",
                "course_refresh_completed",
                fields: [
                    "candidate_count": String(candidateRows.count),
                    "row_count": String(rows.count)
                ]
            )
        } catch {
            await telemetry.error(
                "Monitor",
                "course_refresh_failed",
                fields: ["error_type": errorType(error)]
            )
            fail(error.localizedDescription)
        }
    }

    func ensureCandidateRowsLoaded() async {
        guard candidateRows.isEmpty else { return }
        for _ in 0..<120 where isBusy {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard candidateRows.isEmpty, !isBusy else { return }
        await refreshCourses()
    }

    func addSelection(from row: CourseRow) {
        guard let selection = makeSelection(from: row) else { return }
        if isWatching(row) {
            statusMessage = "이미 감시 중인 반입니다."
            return
        }
        settings.selectedClasses.append(selection)
        statusMessage = "감시할 반에 추가했습니다."
        Task {
            await telemetry.info(
                "Monitor",
                "watch_selection_changed",
                fields: ["enabled": "true"]
            )
        }
    }

    func isWatching(_ row: CourseRow) -> Bool {
        if row.id.hasPrefix("lecture:") {
            let courseID = String(row.id.dropFirst("lecture:".count))
            return settings.selectedClasses.contains { $0.courseID == courseID }
        }
        let keywords = SportsClient.suggestedKeywords(for: row)
        return settings.selectedClasses.contains { $0.keywords == keywords }
    }

    func setWatching(_ row: CourseRow, enabled: Bool) {
        if enabled {
            addSelection(from: row)
            return
        }
        if row.id.hasPrefix("lecture:") {
            let courseID = String(row.id.dropFirst("lecture:".count))
            let removedIDs = Set(
                settings.selectedClasses
                    .filter { $0.courseID == courseID }
                    .map(\.id)
            )
            settings.selectedClasses.removeAll { removedIDs.contains($0.id) }
            selectionStatuses.removeAll { removedIDs.contains($0.id) }
            for id in removedIDs {
                availabilityState.removeValue(forKey: id.uuidString)
            }
            persistAvailability()
        } else {
            let keywords = SportsClient.suggestedKeywords(for: row)
            let removedIDs = Set(
                settings.selectedClasses
                    .filter { $0.keywords == keywords }
                    .map(\.id)
            )
            settings.selectedClasses.removeAll { removedIDs.contains($0.id) }
            selectionStatuses.removeAll { removedIDs.contains($0.id) }
        }
        statusMessage = "감시 목록에서 해제했습니다."
        Task {
            await telemetry.info(
                "Monitor",
                "watch_selection_changed",
                fields: ["enabled": String(enabled)]
            )
        }
    }

    func setWatching(_ rows: [CourseRow], enabled: Bool) {
        if enabled {
            var added = 0
            for row in rows where !isWatching(row) {
                if let selection = makeSelection(from: row) {
                    settings.selectedClasses.append(selection)
                    added += 1
                }
            }
            statusMessage = added > 0
                ? "필터 결과에서 \(added)개 반을 감시에 추가했습니다."
                : "필터 결과가 이미 모두 감시 중입니다."
            Task {
                await telemetry.info(
                    "Monitor",
                    "filtered_watch_selection_changed",
                    fields: [
                        "added_count": String(added),
                        "enabled": "true",
                        "visible_count": String(rows.count)
                    ]
                )
            }
            return
        }

        let courseIDs = Set(
            rows.compactMap { row -> String? in
                guard row.id.hasPrefix("lecture:") else { return nil }
                return String(row.id.dropFirst("lecture:".count))
            }
        )
        let removedIDs = Set(
            settings.selectedClasses
                .filter { selection in
                    selection.courseID.map(courseIDs.contains) == true
                }
                .map(\.id)
        )
        settings.selectedClasses.removeAll { removedIDs.contains($0.id) }
        selectionStatuses.removeAll { removedIDs.contains($0.id) }
        for id in removedIDs {
            availabilityState.removeValue(forKey: id.uuidString)
        }
        persistAvailability()
        statusMessage = removedIDs.isEmpty
            ? "필터 결과에 감시 중인 반이 없습니다."
            : "필터 결과에서 \(removedIDs.count)개 반을 감시 해제했습니다."
        Task {
            await telemetry.info(
                "Monitor",
                "filtered_watch_selection_changed",
                fields: [
                    "enabled": "false",
                    "removed_count": String(removedIDs.count),
                    "visible_count": String(rows.count)
                ]
            )
        }
    }

    func removeSelection(id: UUID) {
        settings.selectedClasses.removeAll { $0.id == id }
        selectionStatuses.removeAll { $0.id == id }
        availabilityState.removeValue(forKey: id.uuidString)
        persistAvailability()
    }

    func updateSelection(_ selection: WatchSelection) {
        guard let index = settings.selectedClasses.firstIndex(where: { $0.id == selection.id }) else {
            return
        }
        settings.selectedClasses[index] = selection
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            settings.launchAtLogin = loginItem.isEnabled
            statusMessage = settings.launchAtLogin
                ? "로그인 시 자동 실행을 켰습니다."
                : "로그인 시 자동 실행을 껐습니다."
            Task {
                await telemetry.info(
                    "Lifecycle",
                    "launch_at_login_changed",
                    fields: ["enabled": String(settings.launchAtLogin)]
                )
            }
        } catch {
            settings.launchAtLogin = loginItem.isEnabled
            Task {
                await telemetry.error(
                    "Lifecycle",
                    "launch_at_login_failed",
                    fields: ["error_type": errorType(error)]
                )
            }
            fail("자동 실행 설정 실패: \(error.localizedDescription)")
        }
    }

    func setAutoRegistrationEnabled(_ enabled: Bool) {
        if enabled {
            guard !settings.selectedClasses.isEmpty else {
                fail("먼저 자동 신청 후보 반을 하나 이상 추가하세요.")
                return
            }
            guard settings.selectedClasses.allSatisfy({ $0.courseID != nil }) else {
                fail("기존 방식으로 저장된 반이 있습니다. 해당 반을 삭제하고 다시 추가하세요.")
                return
            }
            guard settings.autoRegistrationAttemptedCourseID == nil else {
                fail("이전에 신청 요청을 보낸 기록이 있어 자동 신청을 다시 켤 수 없습니다.")
                return
            }
        }
        settings.autoRegistrationEnabled = enabled
        statusMessage = enabled
            ? "자동 신청을 켰습니다. 목록의 위쪽 반부터 하나만 신청합니다."
            : "자동 신청을 껐습니다."
        Task {
            await telemetry.info(
                "Registration",
                "automatic_registration_changed",
                fields: ["enabled": String(enabled)]
            )
        }
    }

    func resetAutoRegistrationLock() {
        settings.autoRegistrationEnabled = false
        settings.autoRegistrationAttemptedCourseID = nil
        settings.autoRegistrationAttemptedAt = nil
        settings.autoRegistrationResult = nil
        statusMessage = "자동 신청 잠금을 초기화했습니다. 필요하면 다시 켜세요."
        Task {
            await telemetry.info("Registration", "automatic_registration_lock_reset")
        }
    }

    func runCheck(manual: Bool) async {
        guard !isBusy else {
            await telemetry.debug("Monitor", "availability_check_skipped", fields: ["reason": "busy"])
            return
        }
        guard settings.monitoringEnabled || manual else { return }
        guard !settings.account.isEmpty else {
            if manual { fail("설정에서 계정 정보를 저장하세요.") }
            return
        }
        guard !settings.selectedClasses.isEmpty else {
            if manual { fail("감시할 수영반을 하나 이상 선택하세요.") }
            return
        }
        if !manual, settings.registrationWindowOnly,
           Calendar.current.component(.day, from: Date()) < settings.activeFromDay {
            statusMessage = "등록기간 전이라 홈페이지에 접속하지 않았습니다."
            await telemetry.info("Monitor", "availability_check_skipped", fields: ["reason": "before_window"])
            return
        }

        await telemetry.info(
            "Monitor",
            "availability_check_started",
            fields: [
                "manual": String(manual),
                "selection_count": String(settings.selectedClasses.count)
            ]
        )
        isBusy = true
        connectionState = .checking
        statusMessage = "선택한 반의 빈자리를 확인하는 중…"
        defer { isBusy = false }

        do {
            let password = try keychain.read(account: settings.account)
            let stableCourseIDs = Set(
                settings.selectedClasses.compactMap(\.courseID)
            )
            let rows = try await sportsClient.fetchCourseRows(
                account: settings.account,
                password: password,
                courseIDs: stableCourseIDs.count == settings.selectedClasses.count
                    ? stableCourseIDs
                    : nil
            )
            var newStatuses: [SelectionStatus] = []
            for selection in settings.selectedClasses {
                let matches = rows.filter { SportsClient.matches($0, selection: selection) }
                let availability: CourseAvailability
                if matches.isEmpty {
                    availability = .unknown(reason: "일치 행 없음")
                } else if matches.count > 1 {
                    availability = .unknown(reason: "키워드 모호함")
                } else {
                    availability = SportsClient.availability(of: matches[0])
                }
                newStatuses.append(
                    SelectionStatus(
                        id: selection.id,
                        name: selection.name,
                        availability: availability
                    )
                )
                await notifyIfNeeded(selection: selection, availability: availability)
                availabilityState[selection.id.uuidString] = availability.isAvailable
            }
            selectionStatuses = newStatuses
            persistAvailability()
            lastCheckedAt = Date()
            connectionState = .connected
            let availableCount = newStatuses.filter { $0.availability.isAvailable }.count
            statusMessage = availableCount > 0
                ? "빈자리가 있는 반 \(availableCount)개를 찾았습니다."
                : "현재 선택한 반에 빈자리가 없습니다."
            let unknownCount = newStatuses.filter {
                if case .unknown = $0.availability { return true }
                return false
            }.count
            await telemetry.info(
                "Monitor",
                "availability_check_completed",
                fields: [
                    "available_count": String(availableCount),
                    "unknown_count": String(unknownCount)
                ]
            )
            await attemptAutomaticRegistrationIfNeeded(
                password: password,
                statuses: newStatuses
            )
        } catch {
            await telemetry.error(
                "Monitor",
                "availability_check_failed",
                fields: ["error_type": errorType(error)]
            )
            fail(error.localizedDescription)
        }
    }

    private func attemptAutomaticRegistrationIfNeeded(
        password: String,
        statuses: [SelectionStatus]
    ) async {
        guard settings.autoRegistrationEnabled,
              settings.autoRegistrationAttemptedCourseID == nil,
              let selection = settings.selectedClasses.first(where: { selection in
                  statuses.first(where: { $0.id == selection.id })?
                      .availability.isAvailable == true
              }),
              let courseID = selection.courseID else {
            return
        }

        settings.autoRegistrationAttemptedCourseID = courseID
        settings.autoRegistrationAttemptedAt = Date()
        settings.autoRegistrationResult = "신청 직전 재확인 중"
        statusMessage = "\(selection.name) 자동 신청을 준비하고 있습니다."
        await telemetry.info("Registration", "automatic_registration_started")

        do {
            let result = try await sportsClient.attemptRegistration(
                account: settings.account,
                password: password,
                courseID: courseID
            )
            switch result {
            case .noLongerAvailable:
                settings.autoRegistrationAttemptedCourseID = nil
                settings.autoRegistrationAttemptedAt = nil
                settings.autoRegistrationResult = "신청 직전 마감되어 계속 감시 중"
                statusMessage = "신청 직전에 자리가 사라져 등록하지 않았습니다."
                await telemetry.info(
                    "Registration",
                    "automatic_registration_aborted",
                    fields: ["reason": "no_longer_available"]
                )
            case .submittedConfirmed:
                settings.autoRegistrationEnabled = false
                settings.autoRegistrationResult = "신청 완료 확인 — 추가 신청 잠금"
                statusMessage = "\(selection.name) 신청 완료를 확인했습니다."
                await telemetry.info(
                    "Registration",
                    "automatic_registration_finished",
                    fields: [
                        "monitoring_continues": String(settings.monitoringEnabled),
                        "result": "confirmed"
                    ]
                )
                await sendRegistrationNotification(
                    title: "경북대 수영 신청 완료",
                    body: "\(selection.name) 접수가 완료되었습니다. 마이페이지에서 결제 정보를 확인하세요."
                )
            case .submittedUnverified:
                settings.autoRegistrationEnabled = false
                settings.autoRegistrationResult = "신청 요청 전송됨 · 결과 확인 필요 — 추가 신청 잠금"
                statusMessage = "신청 요청을 보냈지만 결과 확인이 필요합니다. 추가 신청은 잠갔습니다."
                await telemetry.info(
                    "Registration",
                    "automatic_registration_finished",
                    fields: [
                        "monitoring_continues": String(settings.monitoringEnabled),
                        "result": "unverified"
                    ]
                )
                await sendRegistrationNotification(
                    title: "경북대 수영 신청 결과 확인 필요",
                    body: "신청 요청은 전송됐습니다. 마이페이지에서 결과를 확인하세요."
                )
            }
        } catch {
            settings.autoRegistrationAttemptedCourseID = nil
            settings.autoRegistrationAttemptedAt = nil
            settings.autoRegistrationResult = "신청 요청 전 오류 — 계속 감시 중"
            statusMessage = "최종 신청 요청 전에 오류가 발생해 등록하지 않았습니다."
            await telemetry.error(
                "Registration",
                "automatic_registration_failed_before_submission",
                fields: ["error_type": errorType(error)]
            )
        }
    }

    private func sendRegistrationNotification(
        title: String,
        body: String
    ) async {
        do {
            _ = try await notifications.requestAuthorization()
            try await notifications.send(title: title, body: body)
            await telemetry.info("Notification", "registration_notification_sent")
        } catch {
            await telemetry.error(
                "Notification",
                "registration_notification_failed",
                fields: ["error_type": errorType(error)]
            )
        }
    }

    func testNotification() async {
        await telemetry.info("Notification", "test_notification_started")
        do {
            let granted = try await notifications.requestAuthorization()
            await telemetry.info(
                "Notification",
                "test_notification_authorization_completed",
                fields: ["granted": String(granted)]
            )
            guard granted else {
                statusMessage = "알림 권한이 꺼져 있습니다. 시스템 설정 > 알림에서 허용하세요."
                await telemetry.error(
                    "Notification",
                    "test_notification_not_authorized"
                )
                return
            }
            await telemetry.info("Notification", "test_notification_send_started")
            try await notifications.send(
                title: "경북대 수영 빈자리 알림",
                body: "알림이 정상적으로 설정되었습니다."
            )
            statusMessage = "테스트 알림을 보냈습니다."
            await telemetry.info(
                "Notification",
                "test_notification_sent"
            )
        } catch {
            await telemetry.error(
                "Notification",
                "test_notification_failed",
                fields: ["error_type": errorType(error)]
            )
            statusMessage = "알림 테스트 실패: \(error.localizedDescription)"
        }
    }

    func openWebsite() {
        Task { await telemetry.info("MenuBar", "website_opened") }
        NSWorkspace.shared.open(URL(string: "https://sports.knu.ac.kr/doc/class_info5.php")!)
    }

    func openLogFolder() async {
        await telemetry.info("Diagnostics", "log_folder_opened")
        NSWorkspace.shared.open(AppTelemetry.defaultLogDirectory)
    }

    func filteredCandidates(
        search: String,
        weekdaysOnly: Bool = false,
        morningOnly: Bool = false
    ) -> [CourseRow] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidateRows.filter {
            (term.isEmpty || $0.searchable.localizedCaseInsensitiveContains(term))
                && (!weekdaysOnly || SportsClient.isWeekdayCourse($0))
                && (!morningOnly || SportsClient.isMorningCourse($0))
        }
    }

    private func makeSelection(from row: CourseRow) -> WatchSelection? {
        let keywords = SportsClient.suggestedKeywords(for: row)
        guard !keywords.isEmpty else {
            fail("이 행에서 안정적인 검색 키워드를 만들지 못했습니다.")
            return nil
        }
        let title = row.displayTitle.count > 70
            ? String(row.displayTitle.prefix(67)) + "…"
            : row.displayTitle
        return WatchSelection(
            name: title,
            keywords: keywords,
            courseID: row.id.hasPrefix("lecture:")
                ? String(row.id.dropFirst("lecture:".count))
                : nil
        )
    }

    private func scheduleMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = max(self.settings.intervalSeconds, 60)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self.runCheck(manual: false)
            }
        }
    }

    private func notifyIfNeeded(
        selection: WatchSelection,
        availability: CourseAvailability
    ) async {
        let previous = availabilityState[selection.id.uuidString]
        guard availability.isNewVacancy(comparedTo: previous) else { return }
        do {
            _ = try await notifications.requestAuthorization()
            try await notifications.send(
                title: "경북대 수영 빈자리",
                body: "\(selection.name): \(availability.shortText)"
            )
            await telemetry.info("Notification", "vacancy_notification_sent")
        } catch {
            await telemetry.error(
                "Notification",
                "vacancy_notification_failed",
                fields: ["error_type": errorType(error)]
            )
            statusMessage = "빈자리는 찾았지만 알림 전송에 실패했습니다."
        }
    }

    private func fail(_ message: String) {
        connectionState = .failed(message)
        statusMessage = message
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    private func persistAvailability() {
        defaults.set(availabilityState, forKey: Self.availabilityKey)
    }

    private func errorType(_ error: Error) -> String {
        if let sportsError = error as? SportsClientError {
            return sportsError.diagnosticCode
        }
        if let urlError = error as? URLError {
            return "url_error_\(urlError.errorCode)"
        }
        let nsError = error as NSError
        if !nsError.domain.isEmpty {
            return "ns_error_\(nsError.domain)_\(nsError.code)"
        }
        return String(describing: type(of: error))
    }

    private static let settingsKey = "watcher.settings.v1"
    private static let availabilityKey = "watcher.availability.v1"
}
