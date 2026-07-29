import SwiftUI
import WatcherCore

struct SettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        TabView {
            AccountSettingsView(store: store)
                .tabItem { Label("계정", systemImage: "person.crop.circle") }

            ClassSelectionView(store: store)
                .tabItem { Label("수영반", systemImage: "list.bullet") }

            MonitoringSettingsView(store: store)
                .tabItem { Label("감시", systemImage: "bell") }
        }
        .frame(width: 720, height: 620)
        .padding(16)
    }
}

private struct AccountSettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Form {
            Section("체육진흥센터 로그인") {
                TextField("아이디", text: $store.settings.account)
                    .textFieldStyle(.roundedBorder)
                SecureField("비밀번호", text: $store.passwordDraft)
                    .textFieldStyle(.roundedBorder)
                Text("비밀번호는 이 Mac의 Keychain에만 저장됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("저장하고 연결") {
                        Task { await store.saveCredentials() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isBusy)

                    Button("목록 다시 불러오기") {
                        Task { await store.refreshCourses() }
                    }
                    .disabled(store.isBusy || store.settings.account.isEmpty)
                }
            }

            Section("연결 상태") {
                LabeledContent("상태", value: store.connectionState.label)
                Text(store.statusMessage)
                    .foregroundStyle(.secondary)
            }

            Section("개인정보") {
                Text("앱은 빈자리 확인과 사용자가 명시적으로 켠 경우의 강좌 접수에만 로그인 정보를 사용합니다. 입금·카드 결제와 외부 개인정보 전송은 수행하지 않습니다.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ClassSelectionView: View {
    @ObservedObject var store: AppStore
    @State private var search = ""
    @AppStorage("classFilter.weekdaysOnly") private var weekdaysOnly = true
    @AppStorage("classFilter.morningOnly") private var morningOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("현재 신청 목록")
                        .font(.headline)
                    Text("감시 중 \(store.settings.selectedClasses.count)개 반")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refreshCourses() }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(store.isBusy)
            }

            HStack {
                TextField("시간·요일·반 이름 검색", text: $search)
                    .textFieldStyle(.roundedBorder)
                Toggle("월~금", isOn: $weekdaysOnly)
                    .toggleStyle(.checkbox)
                Toggle("오전", isOn: $morningOnly)
                    .toggleStyle(.checkbox)
            }

            let rows = store.filteredCandidates(
                search: search,
                weekdaysOnly: weekdaysOnly,
                morningOnly: morningOnly
            )

            HStack {
                Text("필터 결과 \(rows.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("결과 모두 감시") {
                    store.setWatching(rows, enabled: true)
                }
                .disabled(rows.isEmpty)
                Button("결과 모두 해제") {
                    store.setWatching(rows, enabled: false)
                }
                .disabled(rows.isEmpty)
            }

            GroupBox {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "조건에 맞는 수영반이 없습니다",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("필터를 끄거나 검색어를 바꿔보세요.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.displayTitle)
                                            .font(.callout)
                                            .lineLimit(2)
                                        if let capacity = row.capacityText {
                                            Text(capacity)
                                                .font(.caption)
                                                .foregroundStyle(
                                                    SportsClient.availability(of: row).isAvailable
                                                        ? .green
                                                        : .secondary
                                                )
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Toggle(
                                        "감시",
                                        isOn: Binding(
                                            get: { store.isWatching(row) },
                                            set: { store.setWatching(row, enabled: $0) }
                                        )
                                    )
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .help(
                                        store.isWatching(row)
                                            ? "감시 목록에서 해제"
                                            : "감시 목록에 추가"
                                    )
                                }
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 370)
                }
            }
        }
        .task {
            await store.ensureCandidateRowsLoaded()
        }
    }
}

private struct MonitoringSettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Form {
            Section("확인 주기") {
                Toggle("빈자리 감시 사용", isOn: $store.settings.monitoringEnabled)
                Picker("확인 간격", selection: $store.settings.intervalSeconds) {
                    Text("1분").tag(60)
                    Text("3분").tag(180)
                    Text("5분 (권장)").tag(300)
                    Text("10분").tag(600)
                }
                Toggle(
                    "매월 \(store.settings.activeFromDay)일부터만 자동 확인",
                    isOn: $store.settings.registrationWindowOnly
                )
                Label(
                    "신청 여부와 관계없이 새 빈자리가 생기면 항상 알림",
                    systemImage: "bell.badge"
                )
                .foregroundStyle(.secondary)
            }

            Section("빈자리 자동 신청") {
                Toggle(
                    "후보 중 빈자리가 생기면 하나만 자동 신청",
                    isOn: Binding(
                        get: { store.settings.autoRegistrationEnabled },
                        set: { store.setAutoRegistrationEnabled($0) }
                    )
                )
                Text(store.autoRegistrationSummary)
                    .foregroundStyle(.secondary)
                Text("감시 중인 반을 위에서부터 확인해 첫 번째 가능한 반만 가상계좌 방식으로 접수합니다. 결제는 자동으로 하지 않으며, 요청을 한 번 보내면 다른 반 신청을 영구 잠급니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("신청 성공·실패·결과 불명 이후에도 빈자리 감시와 알림은 계속됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.settings.autoRegistrationAttemptedCourseID != nil {
                    Button("다음 등록을 위해 신청 잠금 초기화") {
                        store.resetAutoRegistrationLock()
                    }
                    .disabled(store.isBusy)
                }
            }

            Section("macOS") {
                Toggle(
                    "로그인 시 자동 실행",
                    isOn: Binding(
                        get: { store.settings.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    )
                )
                Button("테스트 알림 보내기") {
                    Task { await store.testNotification() }
                }
            }

            Section("진단 로그") {
                Button("로그 폴더 열기") {
                    Task { await store.openLogFolder() }
                }
                Text("~/Library/Logs/KNUSwimWatcher/watcher.log")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("로그에는 단계, HTTP 상태, 응답 크기와 실패 유형만 기록하며 아이디·비밀번호·쿠키·페이지 원문은 저장하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("동작 원칙") {
                Label("5분 기본 간격으로 로그인 1회·목록 조회 1회", systemImage: "checkmark.shield")
                Label("빈자리 상태가 바뀔 때만 알림", systemImage: "bell.badge")
                Label("자동 신청과 결제는 수행하지 않음", systemImage: "hand.raised")
            }
        }
        .formStyle(.grouped)
    }
}
