import Foundation
import CoreFoundation

public enum SportsClientError: LocalizedError {
    case invalidResponse
    case authenticationFailed
    case precheckRequired
    case pageStructureChanged
    case serverStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "홈페이지 응답을 읽을 수 없습니다."
        case .authenticationFailed:
            return "로그인에 실패했습니다. 계정 정보를 확인하세요."
        case .precheckRequired:
            return "로그인에 성공했습니다. 강좌 목록 전에 신청 사전확인이 필요합니다."
        case .pageStructureChanged:
            return "강좌 표를 찾지 못했습니다. 홈페이지 구조가 변경되었을 수 있습니다."
        case let .serverStatus(code):
            return "홈페이지가 HTTP \(code) 오류를 반환했습니다."
        }
    }

    public var diagnosticCode: String {
        switch self {
        case .invalidResponse:
            return "invalid_response"
        case .authenticationFailed:
            return "authentication_failed"
        case .precheckRequired:
            return "precheck_required"
        case .pageStructureChanged:
            return "page_structure_changed"
        case let .serverStatus(code):
            return "server_status_\(code)"
        }
    }
}

public actor SportsClient {
    private let baseURL = URL(string: "https://sports.knu.ac.kr")!
    private let telemetry = AppTelemetry.shared

    public init() {}

    public func fetchCourseRows(
        account: String,
        password: String,
        courseIDs: Set<String>? = nil
    ) async throws -> [CourseRow] {
        let context = try await authenticatedApplication(
            account: account,
            password: password
        )
        let session = context.session
        let applicationURL = context.applicationURL
        defer { session.invalidateAndCancel() }

        let rows = try await fetchSwimApplicationRows(
            session: session,
            referer: applicationURL,
            courseIDs: courseIDs
        )
        let candidates = Self.candidateRows(from: rows)
        let knownCapacity = candidates.filter {
            if case .unknown = Self.availability(of: $0) { return false }
            return true
        }.count
        let parseFields = [
            "candidate_count": String(candidates.count),
            "capacity_known_count": String(knownCapacity),
            "row_count": String(rows.count)
        ]
        await telemetry.info(
            "Parsing",
            "application_courses_parsed",
            fields: parseFields
        )
        return rows
    }

    private struct AuthenticatedApplication {
        let session: URLSession
        let applicationURL: URL
    }

    private struct RegistrationCandidate {
        let detailID: String
        let lectureID: String
        let lectureName: String
        let month: [String: Any]
    }

    public func attemptRegistration(
        account: String,
        password: String,
        courseID: String
    ) async throws -> RegistrationAttemptResult {
        let context = try await authenticatedApplication(
            account: account,
            password: password
        )
        defer { context.session.invalidateAndCancel() }
        guard let candidate = try await registrationCandidate(
            courseID: courseID,
            session: context.session,
            referer: context.applicationURL
        ) else {
            return .noLongerAvailable
        }

        let confirmation = try await confirmationHTML(
            candidate: candidate,
            session: context.session,
            referer: context.applicationURL
        )
        guard confirmation.contains("/pages/register/virtual_bank_proc.php"),
              Self.hiddenInputFields(in: confirmation)["lect_sqno"] == courseID else {
            await telemetry.error("Registration", "confirmation_page_rejected")
            throw SportsClientError.pageStructureChanged
        }

        var finalFields = Self.hiddenInputFields(in: confirmation)
        finalFields["pay_type"] = "V"
        await telemetry.info("Registration", "final_submission_started")
        let resultHTML: String
        do {
            resultHTML = try await postForm(
                to: baseURL.appending(path: "pages/register/virtual_bank_proc.php"),
                fields: finalFields,
                session: context.session,
                referer: baseURL.appending(path: "doc/class_info5_confirm.php")
            )
        } catch {
            await telemetry.error(
                "Registration",
                "final_submission_outcome_unknown",
                fields: ["error_type": String(describing: type(of: error))]
            )
            return .submittedUnverified
        }

        let resultState = Self.classifyRegistrationResult(resultHTML)
        var historyContainsCourse = false
        if let history = try? await fetchFollowingScriptRedirects(
            from: baseURL.appending(path: "doc/class_confirm.php"),
            session: context.session,
            referer: baseURL.appending(path: "pages/register/virtual_bank_proc.php")
        ).2 {
            historyContainsCourse = history.contains(courseID)
                || history.normalizedWhitespace.contains(candidate.lectureName.normalizedWhitespace)
        }
        if resultState == "success" || historyContainsCourse {
            await telemetry.info("Registration", "final_submission_confirmed")
            return .submittedConfirmed
        }
        await telemetry.error(
            "Registration",
            "final_submission_unverified",
            fields: ["response_classification": resultState]
        )
        return .submittedUnverified
    }

    private func authenticatedApplication(
        account: String,
        password: String
    ) async throws -> AuthenticatedApplication {
        await telemetry.info("Auth", "login_flow_started")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 25
        configuration.httpAdditionalHeaders = [
            "User-Agent": "KNUSwimWatcher/1.0 (personal low-frequency vacancy monitor)",
            "Accept": "text/html,application/xhtml+xml",
            "Cache-Control": "no-cache"
        ]
        let session = URLSession(configuration: configuration)

        do {
            var preflightRequest = URLRequest(
                url: baseURL.appending(path: "pages/member/login.php")
            )
            preflightRequest.setValue(
                baseURL.absoluteString + "/",
                forHTTPHeaderField: "Referer"
            )
            let (preflightData, preflightResponse) = try await session.data(for: preflightRequest)
            try validate(response: preflightResponse)
            await telemetry.info(
                "Auth",
                "login_preflight_completed",
                fields: responseFields(response: preflightResponse, data: preflightData)
            )

            var loginRequest = URLRequest(
                url: baseURL.appending(path: "pages/member/login_process.php")
            )
            loginRequest.httpMethod = "POST"
            loginRequest.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
            loginRequest.setValue(
                baseURL.appending(path: "pages/member/login.php").absoluteString,
                forHTTPHeaderField: "Referer"
            )
            loginRequest.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "redirect_url", value: ""),
                URLQueryItem(name: "re_act", value: ""),
                URLQueryItem(name: "id", value: account),
                URLQueryItem(name: "password", value: password)
            ]
            loginRequest.httpBody = components.percentEncodedQuery?.data(using: .utf8)

            let (loginData, loginResponse) = try await session.data(for: loginRequest)
            try validate(response: loginResponse)
            let loginHTML = decodeHTML(loginData) ?? ""
            await telemetry.info(
                "Auth",
                "login_post_completed",
                fields: responseFields(response: loginResponse, data: loginData)
                    .merging(
                        ["classification": Self.classifyLoginResponse(loginHTML)]
                            .merging(
                                Self.structuralResponseFields(loginHTML),
                                uniquingKeysWith: { _, new in new }
                            ),
                        uniquingKeysWith: { _, new in new }
                    )
            )

            let applicationURL = baseURL.appending(path: "doc/class_info5.php")
            var (data, response, html) = try await fetchFollowingScriptRedirects(
                from: applicationURL,
                session: session,
                referer: baseURL.appending(path: "pages/member/login.php")
            )
            let authenticationState = Self.classifyCoursePage(html)
            await telemetry.info(
                "Auth",
                "course_page_received",
                fields: responseFields(response: response, data: data)
                    .merging(
                        ["authentication": authenticationState]
                            .merging(
                                Self.structuralResponseFields(html),
                                uniquingKeysWith: { _, new in new }
                            ),
                        uniquingKeysWith: { _, new in new }
                    )
            )
            if authenticationState == "unauthenticated" {
                await telemetry.error("Auth", "session_not_established")
                throw SportsClientError.authenticationFailed
            }
            var formFields = Self.formStructureFields(html)
            if formFields["form_actions"]?.contains("class_info5.php") == true,
               formFields["input_names"]?.contains("agree") == true {
                await telemetry.info("Auth", "course_precheck_detected", fields: formFields)
                (data, response, html) = try await submitPrecheck(
                    html: html,
                    pageURL: baseURL.appending(path: "doc/class_pre_check.php"),
                    session: session
                )
                await telemetry.info(
                    "Auth",
                    "course_precheck_submitted",
                    fields: responseFields(response: response, data: data)
                )
                let remainingForm = Self.formStructureFields(html)
                if remainingForm["form_actions"]?.contains("class_info5.php") == true,
                   remainingForm["input_names"]?.contains("agree") == true {
                    await telemetry.error("Auth", "course_precheck_not_accepted")
                    throw SportsClientError.precheckRequired
                }
                formFields = remainingForm
            }

            guard formFields["input_names"]?.contains("type_sqno") == true,
                  formFields["input_names"]?.contains("lect_sqno") == true else {
                await telemetry.error(
                    "Parsing",
                    "application_selector_missing",
                    fields: formFields
                )
                throw SportsClientError.pageStructureChanged
            }
            return AuthenticatedApplication(
                session: session,
                applicationURL: applicationURL
            )
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    private func fetchSwimApplicationRows(
        session: URLSession,
        referer: URL,
        courseIDs: Set<String>?
    ) async throws -> [CourseRow] {
        let details = try await lectureJSON(
            ["mode": "LECTURE", "type_sqno": "18"],
            session: session,
            referer: referer
        )
        await telemetry.info(
            "Network",
            "swim_detail_options_received",
            fields: ["count": String(details.count)]
        )

        var rows: [CourseRow] = []
        for detail in details {
            guard let detailID = Self.jsonString(detail["TYPE_DETL_SQNO"]),
                  !detailID.isEmpty else { continue }
            let detailName = Self.jsonString(detail["TYPE_DETL_SQNO_NM"]) ?? "수영"
            let lectures = try await lectureJSON(
                [
                    "mode": "LECTURE_TIME",
                    "type_sqno": "18",
                    "type_detl_sqno": detailID
                ],
                session: session,
                referer: referer
            )
            for lecture in lectures {
                guard let lectureID = Self.jsonString(lecture["LECT_SQNO"]),
                      !lectureID.isEmpty else { continue }
                if let courseIDs, !courseIDs.contains(lectureID) {
                    continue
                }
                let lectureName = Self.jsonString(lecture["LECT_NM"]) ?? "강좌 \(lectureID)"
                let serverAvailable = (Self.jsonInt(lecture["AVAIL"]) ?? 0) > 0
                let months = try await lectureJSON(
                    ["mode": "LECTURE_MONTH", "lect_sqno": lectureID],
                    session: session,
                    referer: referer
                )

                let month = months.last
                let maximum = month.flatMap { Self.jsonInt($0["MNCP_CNT"]) }
                let nominalMonths = month.flatMap { Self.jsonString($0["NOMN"]) }
                var current: Int?
                if let nominalMonths {
                    let counts = try await lectureJSON(
                        [
                            "mode": "LECTURE_RCNT",
                            "lect_sqno": lectureID,
                            "lect_amt_sqno": "\(nominalMonths)개월"
                        ],
                        session: session,
                        referer: referer
                    )
                    current = counts.last.flatMap { Self.jsonInt($0["CNT"]) }
                }

                var cells = Self.courseIdentityCells(
                    lectureName: lectureName,
                    detailName: detailName
                )
                var actions: [String] = []
                if let maximum, let current {
                    let clampedCurrent = min(max(current, 0), maximum)
                    let remaining = max(maximum - clampedCurrent, 0)
                    cells += [
                        "현재 \(clampedCurrent)명 / 정원 \(maximum)명",
                        "잔여 \(remaining)명"
                    ]
                    actions = remaining > 0 && serverAvailable ? ["신청 가능"] : ["마감"]
                } else {
                    cells.append(serverAvailable ? "신청 가능" : "마감")
                    actions = serverAvailable ? ["신청 가능"] : ["마감"]
                }
                rows.append(
                    CourseRow(
                        id: "lecture:\(lectureID)",
                        cells: cells,
                        actions: actions,
                        hrefs: []
                    )
                )
            }
        }
        return rows
    }

    private func registrationCandidate(
        courseID: String,
        session: URLSession,
        referer: URL
    ) async throws -> RegistrationCandidate? {
        let details = try await lectureJSON(
            ["mode": "LECTURE", "type_sqno": "18"],
            session: session,
            referer: referer
        )
        for detail in details {
            guard let detailID = Self.jsonString(detail["TYPE_DETL_SQNO"]) else {
                continue
            }
            let lectures = try await lectureJSON(
                [
                    "mode": "LECTURE_TIME",
                    "type_sqno": "18",
                    "type_detl_sqno": detailID
                ],
                session: session,
                referer: referer
            )
            guard let lecture = lectures.first(where: {
                Self.jsonString($0["LECT_SQNO"]) == courseID
            }) else {
                continue
            }
            guard (Self.jsonInt(lecture["AVAIL"]) ?? 0) > 0 else {
                return nil
            }
            let months = try await lectureJSON(
                ["mode": "LECTURE_MONTH", "lect_sqno": courseID],
                session: session,
                referer: referer
            )
            guard let month = months.last,
                  let maximum = Self.jsonInt(month["MNCP_CNT"]),
                  let nominalMonths = Self.jsonString(month["NOMN"]) else {
                return nil
            }
            let counts = try await lectureJSON(
                [
                    "mode": "LECTURE_RCNT",
                    "lect_sqno": courseID,
                    "lect_amt_sqno": "\(nominalMonths)개월"
                ],
                session: session,
                referer: referer
            )
            guard let current = counts.last.flatMap({ Self.jsonInt($0["CNT"]) }),
                  current < maximum else {
                return nil
            }
            return RegistrationCandidate(
                detailID: detailID,
                lectureID: courseID,
                lectureName: Self.jsonString(lecture["LECT_NM"]) ?? "",
                month: month
            )
        }
        return nil
    }

    private func confirmationHTML(
        candidate: RegistrationCandidate,
        session: URLSession,
        referer: URL
    ) async throws -> String {
        let detailID = candidate.detailID
        let lectureID = candidate.lectureID
        let month = candidate.month
        guard let monthID = Self.jsonString(month["LECT_AMT_SQNO"]),
              let nominalMonths = Self.jsonString(month["NOMN"]) else {
            throw SportsClientError.pageStructureChanged
        }
        let amountRows = try await lectureJSON(
            [
                "mode": "LECTURE_AMT",
                "lect_sqno": lectureID,
                "lect_amt_sqno": monthID,
                "memb_kind_cd": "1"
            ],
            session: session,
            referer: referer
        )
        guard let amount = amountRows.last,
              let amountValue = Self.jsonString(amount["AMT"]),
              let immediate = Self.jsonString(amount["IMDY_ATLC_YN"]) else {
            throw SportsClientError.pageStructureChanged
        }
        let fields = [
            "LECT_AMT": amountValue,
            "LECT_MONTH": nominalMonths,
            "LCTN_DVCD": "1",
            "mode": "LECTURE",
            "CUR_URL": "/doc/class_info5.php",
            "NEXT_URL": "/pages/register/register_result.php",
            "PG_LECT_NM": "",
            "LECT_PERIOD": Self.lecturePeriod(
                nominalMonths: Int(nominalMonths) ?? 1,
                immediate: immediate == "Y"
            ),
            "IMDY_ATLC_YN": immediate,
            "memb_kind_cd": "1",
            "q1": "N",
            "q2": "N",
            "agree2": "Y",
            "type_sqno": "18",
            "type_detl_sqno": detailID,
            "lect_sqno": lectureID,
            "lect_time_sqno": "",
            "lect_amt_sqno": monthID
        ]
        let html = try await postForm(
            to: baseURL.appending(path: "doc/class_info5_confirm.php"),
            fields: fields,
            session: session,
            referer: referer
        )
        return html
    }

    private func postForm(
        to url: URL,
        fields: [String: String],
        session: URLSession,
        referer: URL
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        guard let html = decodeHTML(data) else {
            throw SportsClientError.invalidResponse
        }
        return html
    }

    private func lectureJSON(
        _ fields: [String: String],
        session: URLSession,
        referer: URL
    ) async throws -> [[String: Any]] {
        let endpoint = baseURL.appending(path: "application/util/ajax/getLecture.php")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        guard !data.isEmpty else { return [] }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionaries = object as? [[String: Any]] {
            return dictionaries
        }
        guard let decoded = decodeHTML(data),
              let normalized = decoded.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: normalized),
              let dictionaries = object as? [[String: Any]] else {
            await telemetry.error(
                "Parsing",
                "lecture_json_invalid",
                fields: [
                    "bytes": String(data.count),
                    "mode": fields["mode"] ?? "unknown"
                ]
            )
            throw SportsClientError.pageStructureChanged
        }
        return dictionaries
    }

    private func submitPrecheck(
        html: String,
        pageURL: URL,
        session: URLSession
    ) async throws -> (Data, URLResponse, String) {
        guard let fields = Self.precheckSubmissionFields(html),
              let action = Self.firstFormAction(in: html),
              let rawActionURL = URL(string: action, relativeTo: pageURL)?.absoluteURL,
              rawActionURL.host == baseURL.host else {
            await telemetry.error("Auth", "course_precheck_mapping_failed")
            throw SportsClientError.precheckRequired
        }

        let method = Self.firstFormMethod(in: html)
        var actionURL = rawActionURL
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        if method == "GET" {
            var urlComponents = URLComponents(url: rawActionURL, resolvingAgainstBaseURL: true)
            let existingItems = urlComponents?.queryItems ?? []
            urlComponents?.queryItems = existingItems + (components.queryItems ?? [])
            guard let getURL = urlComponents?.url else {
                throw SportsClientError.invalidResponse
            }
            actionURL = getURL
        }

        var request = URLRequest(url: actionURL)
        request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        if method == "POST" {
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        }

        await telemetry.info(
            "Auth",
            "course_precheck_submission_started",
            fields: [
                "field_count": String(fields.count),
                "method": method
            ]
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        guard let responseHTML = decodeHTML(data) else {
            throw SportsClientError.invalidResponse
        }
        guard let target = Self.scriptRedirectTarget(in: responseHTML),
              let nextURL = URL(string: target, relativeTo: actionURL)?.absoluteURL,
              nextURL.host == baseURL.host else {
            return (data, response, responseHTML)
        }
        return try await fetchFollowingScriptRedirects(
            from: nextURL,
            session: session,
            referer: actionURL
        )
    }

    private func fetchFollowingScriptRedirects(
        from initialURL: URL,
        session: URLSession,
        referer: URL,
        maximumRedirects: Int = 5
    ) async throws -> (Data, URLResponse, String) {
        var currentURL = initialURL
        var currentReferer = referer

        for step in 0...maximumRedirects {
            var request = URLRequest(url: currentURL)
            request.setValue(currentReferer.absoluteString, forHTTPHeaderField: "Referer")
            let (data, response) = try await session.data(for: request)
            try validate(response: response)
            guard let html = decodeHTML(data) else {
                await telemetry.error("Auth", "course_page_decode_failed")
                throw SportsClientError.invalidResponse
            }
            guard step < maximumRedirects,
                  let target = Self.scriptRedirectTarget(in: html),
                  let nextURL = URL(string: target, relativeTo: currentURL)?.absoluteURL,
                  nextURL.host == baseURL.host else {
                return (data, response, html)
            }

            await telemetry.info(
                "Network",
                "script_redirect_followed",
                fields: [
                    "destination": nextURL.path,
                    "step": String(step + 1)
                ]
            )
            currentReferer = currentURL
            currentURL = nextURL
        }
        throw SportsClientError.pageStructureChanged
    }

    public nonisolated static func classifyLoginResponse(_ html: String) -> String {
        let normalized = html.normalizedWhitespace
        if [
            "비밀번호가 일치하지", "아이디가 일치하지",
            "로그인 정보가 올바르지", "로그인에 실패",
            "아이디 또는 비밀번호", "회원정보가 없습니다"
        ]
            .contains(where: normalized.contains) {
            return "rejected"
        }
        if normalized.contains("로그아웃")
            || normalized.contains("로그인 되었습니다")
            || normalized.contains("로그인되었습니다") {
            return "accepted"
        }
        if normalized.localizedCaseInsensitiveContains("history.back") {
            return "rejected"
        }
        return "unknown"
    }

    public nonisolated static func classifyCoursePage(_ html: String) -> String {
        let normalized = html.normalizedWhitespace
        if normalized.contains("로그인 후 이용해 주세요")
            || normalized.contains("로그인후 이용해 주세요")
            || normalized.contains("로그인 후 이용")
            || normalized.contains("로그인후 이용")
            || (
                normalized.count < 512
                    && (
                        normalized.localizedCaseInsensitiveContains("/member/login")
                            || normalized.localizedCaseInsensitiveContains("login.php")
                    )
            )
            || html.range(
                of: #"<(?:input|textarea)\b[^>]*name=["']password["']"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
            return "unauthenticated"
        }
        return "authenticated"
    }

    public nonisolated static func structuralResponseFields(
        _ html: String
    ) -> [String: String] {
        let folded = html.lowercased()
        var fields = [
            "has_alert": String(folded.contains("alert(")),
            "has_back": String(folded.contains("history.back")),
            "has_location": String(folded.contains("location")),
            "has_login_path": String(
                folded.contains("/member/login") || folded.contains("login.php")
            )
        ]
        if let target = firstCapture(
            #"location(?:\.href)?\s*=\s*["']([^"'?]+)"#,
            in: html
        ) {
            fields["redirect_path"] = String(target.prefix(160))
        }
        return fields
    }

    public nonisolated static func hiddenInputFields(
        in html: String
    ) -> [String: String] {
        let tags = captures(
            pattern: #"(<input\b[^>]*>)"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        var fields: [String: String] = [:]
        for tag in tags {
            guard tag.range(
                of: #"\btype\s*=\s*["']hidden["']"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil,
            let name = firstCapture(
                #"\bname\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
                in: tag
            ) else {
                continue
            }
            let value = firstCapture(
                #"\bvalue\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
                in: tag
            ) ?? ""
            fields[name] = decodeAttributeEntities(value)
        }
        return fields
    }

    public nonisolated static func classifyRegistrationResult(
        _ html: String
    ) -> String {
        let text = plainText(html)
        if [
            "신청이 완료되었습니다", "접수가 완료되었습니다",
            "등록이 완료되었습니다", "강좌신청 완료"
        ].contains(where: text.contains) {
            return "success"
        }
        if [
            "마감", "신청할 수 없", "이미 신청", "중복",
            "오류", "실패", "정원"
        ].contains(where: text.contains) {
            return "rejected"
        }
        return "unknown"
    }

    public nonisolated static func scriptRedirectTarget(in html: String) -> String? {
        firstCapture(
            #"(?:window\.)?location(?:\.href)?\s*=\s*["']([^"']+)["']"#,
            in: html
        )
    }

    public nonisolated static func formStructureFields(_ html: String) -> [String: String] {
        let actions = captures(
            pattern: #"<form\b[^>]*action=["']([^"']*)["']"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let names = captures(
            pattern: #"<(?:input|button|select)\b[^>]*name=["']([^"']+)["']"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        return [
            "form_actions": unique(actions).joined(separator: ",").prefix(300).description,
            "input_names": unique(names).joined(separator: ",").prefix(300).description
        ]
    }

    public nonisolated static func firstFormAction(in html: String) -> String? {
        firstCapture(
            #"(?is)<form\b[^>]*action=["']([^"']*)["']"#,
            in: html
        )
    }

    public nonisolated static func firstFormMethod(in html: String) -> String {
        let value = firstCapture(
            #"(?is)<form\b[^>]*\bmethod\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
            in: html
        )?.uppercased()
        return value == "POST" ? "POST" : "GET"
    }

    public nonisolated static func precheckSubmissionFields(
        _ html: String
    ) -> [String: String]? {
        let choices: [(name: String, affirmative: Bool)] = [
            ("q1", false),
            ("q2", false),
            ("agree", true),
            ("agree2", true)
        ]
        var fields: [String: String] = [:]
        for choice in choices {
            guard let value = preferredInputValue(
                name: choice.name,
                affirmative: choice.affirmative,
                html: html
            ) else {
                return nil
            }
            fields[choice.name] = value
        }
        return fields
    }

    public nonisolated static func swimProgramSelectionFields(
        _ html: String
    ) -> [String: String]? {
        guard let swimValue = selectOptionValue(
            name: "PG_LECT_NM",
            labelContaining: "수영",
            html: html
        ) else {
            return nil
        }
        var fields = ["PG_LECT_NM": swimValue]
        for name in ["LECT_MONTH", "LCTN_DVCD"] {
            if let value = selectedOrFirstOptionValue(name: name, html: html) {
                fields[name] = value
            }
        }
        let hiddenNames = ["mode", "CUR_URL", "NEXT_URL", "memb_kind_cd"]
        for name in hiddenNames {
            if let value = inputValue(name: name, html: html), !value.isEmpty {
                fields[name] = value
            }
        }
        return fields
    }

    public nonisolated static func swimNavigationPath(
        from rows: [CourseRow]
    ) -> String? {
        rows.first { row in
            row.searchable.contains("수영")
                && row.hrefs.contains { $0.contains("/doc/class1.html") }
        }?.hrefs.first { $0.contains("/doc/class1.html") }
    }

    public nonisolated static func swimNavigationPath(in html: String) -> String? {
        let anchors = captures(
            pattern: #"(<a\b[^>]*href=["'][^"']+["'][^>]*>.*?</a>)"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        guard let anchor = anchors.first(where: { plainText($0).contains("수영") }) else {
            return nil
        }
        return firstCapture(
            #"(?i)\bhref=["']([^"']+)["']"#,
            in: anchor
        )
    }

    private nonisolated static func selectOptionValue(
        name: String,
        labelContaining term: String,
        html: String
    ) -> String? {
        optionTags(name: name, html: html).first { tag in
            plainText(tag).localizedCaseInsensitiveContains(term)
        }.flatMap(optionValue)
    }

    private nonisolated static func selectedOrFirstOptionValue(
        name: String,
        html: String
    ) -> String? {
        let tags = optionTags(name: name, html: html)
        let selected = tags.first {
            $0.range(of: #"\bselected\b"#, options: [.regularExpression, .caseInsensitive])
                != nil
        }
        if let value = selected.flatMap(optionValue), !value.isEmpty {
            return value
        }
        return tags.compactMap(optionValue).first { !$0.isEmpty }
    }

    private nonisolated static func optionTags(
        name: String,
        html: String
    ) -> [String] {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let block = firstCapture(
            #"(?is)<select\b[^>]*\bname=["']\#(escapedName)["'][^>]*>(.*?)</select>"#,
            in: html
        ) else {
            return []
        }
        return captures(
            pattern: #"(<option\b[^>]*>.*?</option>)"#,
            in: block,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
    }

    private nonisolated static func optionValue(_ tag: String) -> String? {
        firstCapture(
            #"(?i)\bvalue\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
            in: tag
        )
    }

    private nonisolated static func inputValue(
        name: String,
        html: String
    ) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let tag = firstCapture(
            #"(?is)(<input\b[^>]*\bname=["']\#(escapedName)["'][^>]*>)"#,
            in: html
        ) else {
            return nil
        }
        return firstCapture(
            #"(?i)\bvalue\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
            in: tag
        )
    }

    private nonisolated static func preferredInputValue(
        name: String,
        affirmative: Bool,
        html: String
    ) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let tags = captures(
            pattern: #"(<input\b[^>]*\bname=["']\#(escapedName)["'][^>]*>)"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let values = tags.map {
            firstCapture(
                #"(?i)\bvalue\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
                in: $0
            ) ?? "on"
        }
        guard !values.isEmpty else { return nil }

        let preferred = affirmative
            ? ["y", "yes", "1", "true", "on", "agree"]
            : ["n", "no", "0", "2", "false", "none"]
        if let match = values.first(where: { preferred.contains($0.lowercased()) }) {
            return match
        }
        return affirmative ? values.first : values.last
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SportsClientError.invalidResponse
        }
        guard (200..<400).contains(http.statusCode) else {
            throw SportsClientError.serverStatus(http.statusCode)
        }
    }

    private func decodeHTML(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let eucKR = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
            )
        )
        if let korean = String(data: data, encoding: eucKR) {
            return korean
        }
        let dosKorean = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
            )
        )
        if let korean = String(data: data, encoding: dosKorean) {
            return korean
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private func responseFields(response: URLResponse, data: Data) -> [String: String] {
        let http = response as? HTTPURLResponse
        return [
            "bytes": String(data.count),
            "http_status": String(http?.statusCode ?? 0)
        ]
    }

    public nonisolated static func parseRows(_ html: String) -> [CourseRow] {
        let cleaned = removingBlocks(html, tags: ["script", "style", "noscript"])
        let rowBodies = captures(
            pattern: #"<tr\b[^>]*>(.*?)</tr>"#,
            in: cleaned,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        return rowBodies.enumerated().compactMap { index, rowHTML in
            let cellBodies = captures(
                pattern: #"<(?:td|th)\b[^>]*>(.*?)</(?:td|th)>"#,
                in: rowHTML,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
            let cells = cellBodies.map(plainText).filter { !$0.isEmpty }

            var actions = captures(
                pattern: #"<(?:input|button)\b[^>]*(?:value|alt|title)=["']([^"']+)["'][^>]*>"#,
                in: rowHTML,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ).map(plainText)
            actions += captures(
                pattern: #"<button\b[^>]*>(.*?)</button>"#,
                in: rowHTML,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ).map(plainText)
            actions += captures(
                pattern: #"<a\b[^>]*>(.*?)</a>"#,
                in: rowHTML,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ).map(plainText)

            let hrefs = captures(
                pattern: #"<a\b[^>]*href=["']([^"']+)["'][^>]*>"#,
                in: rowHTML,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ).map(plainText)

            let uniqueActions = unique(actions.filter { !$0.isEmpty })
            let uniqueHrefs = unique(hrefs.filter { !$0.isEmpty })
            guard !cells.isEmpty || !uniqueActions.isEmpty || !uniqueHrefs.isEmpty else {
                return nil
            }
            let seed = ([cells.joined(separator: "|")] + uniqueActions + uniqueHrefs)
                .joined(separator: "|")
            return CourseRow(
                id: "\(index)-\(seed)",
                cells: cells,
                actions: uniqueActions,
                hrefs: uniqueHrefs
            )
        }
    }

    public nonisolated static func candidateRows(from rows: [CourseRow]) -> [CourseRow] {
        rows.filter { row in
            if row.id.hasPrefix("lecture:") {
                return true
            }
            let text = row.searchable
            let hasTime = firstMatch(#"\b\d{1,2}:\d{2}\b"#, in: text) != nil
            let hasSwimStage = [
                "수영", "초급", "중급", "상급", "고급",
                "교정", "연수", "선수", "마스터즈", "어린이"
            ].contains { text.contains($0) }
            return hasTime && hasSwimStage
        }
    }

    public nonisolated static func isWeekdayCourse(_ row: CourseRow) -> Bool {
        guard row.id.hasPrefix("lecture:"), row.cells.count >= 3 else {
            return false
        }
        let schedule = row.cells[2]
        let weekdays = ["월", "화", "수", "목", "금"]
        return weekdays.allSatisfy(schedule.contains)
            && !schedule.contains("토")
            && !schedule.contains("일")
    }

    public nonisolated static func isMorningCourse(_ row: CourseRow) -> Bool {
        guard row.id.hasPrefix("lecture:"),
              let time = row.cells.first,
              let values = captureGroups(#"^(\d{1,2}):(\d{2})"#, in: time),
              values.count == 2,
              let hour = Int(values[0]),
              let minute = Int(values[1]) else {
            return false
        }
        return hour * 60 + minute < 12 * 60
    }

    private nonisolated static func jsonString(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value.normalizedWhitespace
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private nonisolated static func jsonInt(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.replacingOccurrences(of: ",", with: "").normalizedWhitespace)
        default:
            return nil
        }
    }

    public nonisolated static func rowStructureFields(
        _ rows: [CourseRow],
        sourceHTML: String? = nil
    ) -> [String: String] {
        let withTime = rows.filter {
            firstMatch(#"\b\d{1,2}:\d{2}\b"#, in: $0.searchable) != nil
        }.count
        let withSwim = rows.filter { row in
            ["수영", "초급", "중급", "상급", "고급", "교정", "연수", "마스터즈"]
                .contains { term in row.searchable.contains(term) }
        }.count
        let withApplyAction = rows.filter { row in
            row.actions.contains { $0.contains("신청") || $0.contains("등록") }
                || row.hrefs.contains { $0.contains("apply") || $0.contains("class") }
        }.count
        let swimRows = rows.filter { $0.searchable.contains("수영") }
        let swimHrefs = unique(swimRows.flatMap(\.hrefs))
            .joined(separator: ",")
            .prefix(400)
            .description
        let swimActions = unique(swimRows.flatMap(\.actions))
            .joined(separator: ",")
            .prefix(200)
            .description
        var fields = [
            "max_cell_count": String(rows.map(\.cells.count).max() ?? 0),
            "rows_with_apply": String(withApplyAction),
            "rows_with_swim": String(withSwim),
            "rows_with_time": String(withTime),
            "swim_actions": swimActions,
            "swim_hrefs": swimHrefs
        ]
        fields.merge(
            swimElementStructureFields(in: rows, sourceHTML: sourceHTML),
            uniquingKeysWith: { _, new in new }
        )
        return fields
    }

    public nonisolated static func swimElementStructureFields(
        in rows: [CourseRow],
        sourceHTML: String?
    ) -> [String: String] {
        guard let sourceHTML,
              let range = sourceHTML.range(of: "수영") else {
            return [:]
        }
        let prefixStart = sourceHTML.index(
            range.lowerBound,
            offsetBy: -min(700, sourceHTML.distance(from: sourceHTML.startIndex, to: range.lowerBound))
        )
        let prefix = String(sourceHTML[prefixStart..<range.lowerBound])
        let regex = try! NSRegularExpression(
            pattern: #"<[A-Za-z][^>]{0,350}>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let tags = regex.matches(
            in: prefix,
            range: NSRange(prefix.startIndex..., in: prefix)
        ).compactMap { match -> String? in
            guard let tagRange = Range(match.range, in: prefix) else { return nil }
            return String(prefix[tagRange]).normalizedWhitespace
        }
        return [
            "swim_opening_tags": tags.suffix(4)
                .joined(separator: " | ")
                .prefix(700)
                .description
        ]
    }

    public nonisolated static func suggestedKeywords(for row: CourseRow) -> [String] {
        let stages = [
            "초급", "중급", "상급", "고급", "교정", "교정1",
            "교정2", "연수", "선수", "마스터즈", "어린이", "자유이용"
        ]
        var result: [String] = []
        for cell in row.cells {
            let value = cell.normalizedWhitespace
            if value.isEmpty || value.count > 60 {
                continue
            }
            if ["잔여", "정원", "신청인원", "등록인원", "마감"].contains(where: value.contains) {
                continue
            }
            let useful = firstMatch(#"\b\d{1,2}:\d{2}\b"#, in: value) != nil
                || stages.contains(where: { value == $0 })
                || firstMatch(
                    #"(?:^|[\s,~])(?:월|화|수|목|금|토|일)(?:$|[\s,~])"#,
                    in: value
                ) != nil
                || value.contains("수영")
            if useful && !result.contains(value) {
                result.append(value)
            }
        }
        if result.isEmpty {
            result = Array(row.cells.prefix(3))
        }
        return Array(result.prefix(5))
    }

    public nonisolated static func matches(_ row: CourseRow, selection: WatchSelection) -> Bool {
        if let courseID = selection.courseID {
            return row.id == "lecture:\(courseID)"
        }
        let haystack = row.searchable.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return selection.keywords.allSatisfy { keyword in
            haystack.contains(
                keyword.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
            )
        }
    }

    public nonisolated static func courseIdentityCells(
        lectureName: String,
        detailName: String
    ) -> [String] {
        let time = firstCapture(
            #"\[(\d{1,2}:\d{2}\s*[-~]\s*\d{1,2}:\d{2})\]"#,
            in: lectureName
        )?.replacingOccurrences(of: " ", with: "") ?? "시간 미표기"
        let className = firstCapture(
            #"수영\s+([^,/]*?반)(?:\s|/|,)"#,
            in: lectureName
        )?.normalizedWhitespace
            ?? detailName.components(separatedBy: " 강습").first?.normalizedWhitespace
            ?? detailName
        let beforeFirstTime = lectureName.components(separatedBy: "[").first ?? lectureName
        let days = captureGroups(
            #"((?:월|화|수|목|금|토|일)(?:\s*,\s*(?:월|화|수|목|금|토|일))*)\s*$"#,
            in: beforeFirstTime
        )?.first?.replacingOccurrences(of: " ", with: "")
        let frequency = firstCapture(#"(주\s*\d+\s*회)"#, in: detailName)?
            .replacingOccurrences(of: " ", with: "")
        let schedule = [frequency, days]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return [time, className, schedule.isEmpty ? detailName : schedule]
    }

    public nonisolated static func lecturePeriod(
        nominalMonths: Int,
        immediate: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let months = max(nominalMonths, 1)
        let start: Date
        if immediate {
            start = now
        } else {
            let components = calendar.dateComponents([.year, .month], from: now)
            let firstOfThisMonth = calendar.date(from: components) ?? now
            start = calendar.date(byAdding: .month, value: 1, to: firstOfThisMonth) ?? now
        }
        let endExclusive = calendar.date(byAdding: .month, value: months, to: start) ?? start
        let end = calendar.date(byAdding: .day, value: -1, to: endExclusive) ?? endExclusive
        func formatted(_ date: Date) -> String {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            return String(
                format: "%04d년%02d월%02d일",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
        }
        return "\(formatted(start)) 부터 \(formatted(end)) 까지"
    }

    public nonisolated static func availability(of row: CourseRow) -> CourseAvailability {
        let text = row.searchable
        if ["마감", "신청불가", "등록불가", "종료", "폐강"].contains(where: text.contains) {
            return .unavailable(reason: "마감")
        }

        let seatPatterns = [
            #"(?:잔여(?:인원)?|남은\s*인원)\s*[:：]?\s*(\d+)"#,
            #"(\d+)\s*명\s*(?:잔여|가능)"#
        ]
        for pattern in seatPatterns {
            if let value = firstCapture(pattern, in: text).flatMap(Int.init) {
                return value > 0
                    ? .available(seats: value, reason: "잔여 \(value)명")
                    : .unavailable(reason: "잔여 0명")
            }
        }

        if let values = captureGroups(
            #"(?:신청|등록)?\s*(\d+)\s*/\s*(\d+)\s*(?:명)?"#,
            in: text
        ), values.count == 2,
           let used = Int(values[0]), let limit = Int(values[1]), limit >= used {
            let seats = limit - used
            return seats > 0
                ? .available(seats: seats, reason: "\(used)/\(limit)명")
                : .unavailable(reason: "\(used)/\(limit)명")
        }

        if let values = captureGroups(
            #"정원\s*[:：]?\s*(\d+).*?(?:신청|등록)(?:인원)?\s*[:：]?\s*(\d+)"#,
            in: text
        ), values.count == 2,
           let limit = Int(values[0]), let used = Int(values[1]) {
            let seats = max(limit - used, 0)
            return seats > 0
                ? .available(seats: seats, reason: "\(used)/\(limit)명")
                : .unavailable(reason: "\(used)/\(limit)명")
        }

        let actionText = row.actions.joined(separator: " ")
        if actionText.contains("신청") {
            return .available(seats: nil, reason: "신청 가능")
        }
        return .unknown(reason: "확인 불가")
    }

    private nonisolated static func removingBlocks(_ html: String, tags: [String]) -> String {
        tags.reduce(html) { partial, tag in
            partial.replacingOccurrences(
                of: #"<\#(tag)\b[^>]*>.*?</\#(tag)>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    private nonisolated static func plainText(_ html: String) -> String {
        var value = html
            .replacingOccurrences(
                of: #"<br\s*/?>"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<[^>]+>"#,
                with: " ",
                options: .regularExpression
            )
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<",
            "&gt;": ">", "&quot;": "\"", "&#39;": "'"
        ]
        for (entity, decoded) in entities {
            value = value.replacingOccurrences(of: entity, with: decoded)
        }
        value = decodeNumericEntities(value)
        return value.normalizedWhitespace
    }

    private nonisolated static func decodeNumericEntities(_ value: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"&#(?:x([0-9A-Fa-f]+)|([0-9]+));"#)
        var result = value
        for match in regex.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ).reversed() {
            guard let whole = Range(match.range(at: 0), in: result) else { continue }
            let hex = match.range(at: 1)
            let decimal = match.range(at: 2)
            let number: UInt32?
            if hex.location != NSNotFound,
               let range = Range(hex, in: result) {
                number = UInt32(result[range], radix: 16)
            } else if decimal.location != NSNotFound,
                      let range = Range(decimal, in: result) {
                number = UInt32(result[range], radix: 10)
            } else {
                number = nil
            }
            if let number, let scalar = UnicodeScalar(number) {
                result.replaceSubrange(whole, with: String(scalar))
            }
        }
        return result
    }

    private nonisolated static func decodeAttributeEntities(_ value: String) -> String {
        var result = value
        for (entity, decoded) in [
            "&amp;": "&", "&quot;": "\"", "&#39;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " "
        ] {
            result = result.replacingOccurrences(of: entity, with: decoded)
        }
        return decodeNumericEntities(result)
    }

    private nonisolated static func captures(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        return regex.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private nonisolated static func captureGroups(
        _ pattern: String,
        in text: String
    ) -> [String]? {
        let regex = try! NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        guard let match = regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private nonisolated static func firstCapture(
        _ pattern: String,
        in text: String
    ) -> String? {
        captureGroups(pattern, in: text)?.first
    }

    private nonisolated static func firstMatch(
        _ pattern: String,
        in text: String
    ) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ), let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range])
    }

    private nonisolated static func unique(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}
