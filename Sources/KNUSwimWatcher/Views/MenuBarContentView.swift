import AppKit
import SwiftUI
import WatcherCore

struct MenuBarContentView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(
                            "감시 중인 반 \(store.settings.selectedClasses.count)개",
                            systemImage: "eye"
                        )
                        .font(.caption.weight(.semibold))
                        Spacer()
                        if store.settings.selectedClasses.count > 8 {
                            Text("스크롤")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(store.settings.selectedClasses) { selection in
                                let status = status(for: selection)
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(
                                            status?.availability.isAvailable == true
                                                ? Color.green
                                                : Color.gray
                                        )
                                        .frame(width: 6, height: 6)
                                    Text(shortTitle(selection.name))
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                    Spacer(minLength: 6)
                                    Text(status?.availability.shortText ?? "확인 전")
                                        .lineLimit(1)
                                        .foregroundStyle(
                                            status?.availability.isAvailable == true
                                                ? .green
                                                : .secondary
                                        )
                                }
                                .font(.caption2)
                                .frame(height: 20)
                                .help(selection.name)
                            }
                        }
                    }
                    .frame(height: watchListHeight)
                    .scrollIndicators(
                        store.settings.selectedClasses.count > 8 ? .visible : .hidden
                    )
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
        .padding(14)
        .frame(width: 360)
        .task {
            store.start()
        }
    }

    private var watchListHeight: CGFloat {
        min(CGFloat(store.settings.selectedClasses.count) * 23, 184)
    }

    private func status(for selection: WatchSelection) -> SelectionStatus? {
        store.selectionStatuses.first { $0.id == selection.id }
    }

    private func shortTitle(_ value: String) -> String {
        value.count <= 30 ? value : String(value.prefix(27)) + "…"
    }
}
