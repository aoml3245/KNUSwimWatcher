import AppKit
import SwiftUI
import WatcherCore

struct MenuBarContentView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: store.menuBarSymbol)
                    .font(.title2)
                    .foregroundStyle(store.anyAvailable ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("경북대 수영 알림")
                        .font(.headline)
                    Text(store.connectionState.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Toggle("빈자리 감시", isOn: $store.settings.monitoringEnabled)
            if store.settings.autoRegistrationEnabled
                || store.settings.autoRegistrationAttemptedCourseID != nil {
                Label(
                    store.autoRegistrationSummary,
                    systemImage: store.settings.autoRegistrationAttemptedCourseID == nil
                        ? "bolt.badge.clock"
                        : "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(store.statusMessage)
                    .font(.callout)
                    .lineLimit(3)
                Text("마지막 확인: \(store.lastCheckedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

            if store.settings.selectedClasses.isEmpty {
                Label("설정에서 감시할 반을 선택하세요.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(store.selectionStatuses.prefix(4)) { status in
                        HStack {
                            Circle()
                                .fill(status.availability.isAvailable ? Color.green : Color.gray)
                                .frame(width: 7, height: 7)
                            Text(shortTitle(status.name))
                                .lineLimit(1)
                            Spacer()
                            Text(status.availability.shortText)
                                .foregroundStyle(
                                    status.availability.isAvailable ? .green : .secondary
                                )
                        }
                        .font(.caption)
                    }
                    if store.selectionStatuses.isEmpty {
                        Text("감시 중 \(store.settings.selectedClasses.count)개 반")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button {
                    Task { await store.runCheck(manual: true) }
                } label: {
                    Label("지금 확인", systemImage: "arrow.clockwise")
                }
                .disabled(store.isBusy)

                Button {
                    store.openWebsite()
                } label: {
                    Label("신청 페이지", systemImage: "safari")
                }
            }

            Divider()

            HStack {
                SettingsLink {
                    Label("설정…", systemImage: "gearshape")
                }
                Spacer()
                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .task {
            store.start()
        }
    }

    private func shortTitle(_ value: String) -> String {
        value.count <= 30 ? value : String(value.prefix(27)) + "…"
    }
}
