import SwiftUI
import UIKit

struct ProfileSettingsView: View {
    @Environment(\.brandTheme) private var theme
    @EnvironmentObject private var automationCoordinator: AutomationCoordinator
    @EnvironmentObject private var availabilityStore: AIProviderAvailabilityStore
    @EnvironmentObject private var runMetricsStore: AIRunMetricsStore
    @AppStorage(BrandTheme.appearanceStorageKey) private var appearanceStyleRaw = AppearanceStyle.bk.rawValue
    @AppStorage(SharedGenerationSettings.automationEnabledKey) private var automationEnabled = false
    @AppStorage(SharedGenerationSettings.showsExternalAIBrowserKey) private var showsExternalAIBrowser = false
    @State private var loginProvider: ExternalAIProvider?
    @StateObject private var loginStatusStore = ExternalAILoginStatusStore()
    @ObservedObject private var diagnosticsStore = AIBIDiagnosticsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("자동화 사용", isOn: $automationEnabled)
                    .accessibilityHint("켜면 앱을 열 때 미디어를 고른 뒤 무작위 AI로 보내는 자동화가 시작됩니다")
            } header: {
                BrandSectionTitle(title: "자동화", systemImage: "wand.and.sparkles")
            } footer: {
                Text("끄면 앱을 열거나 15초 뒤 돌아와도 자동 미디어 선택이 시작되지 않아요. 다른 앱에서 직접 공유한 사진과 카메라 퀵 액션은 계속 사용할 수 있어요.")
            }

            Section {
                ForEach(AIProviderIdentity.allCases) { identity in
                    HStack(alignment: .top, spacing: 12) {
                        identity.tabIcon
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(identity.title).foregroundStyle(.primary)
                            Text(lastRunSubtitle(for: identity))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if identity == .device {
                            Text("항상 켜짐")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .trailing, spacing: 6) {
                                Toggle("", isOn: availabilityBinding(for: identity))
                                    .labelsHidden()
                                    .accessibilityLabel("\(identity.title) 사용, \(availabilityStore.isEnabled(identity) ? "켜짐" : "꺼짐")")
                                if let provider = identity.externalProvider {
                                    let status = loginStatusStore.status(for: provider)
                                    Button {
                                        loginProvider = provider
                                    } label: {
                                        Label(status.title, systemImage: status.iconName)
                                            .labelStyle(.titleAndIcon)
                                            .font(.footnote)
                                            .foregroundStyle(status.color)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(identity.title) 로그인, \(status.title)")
                                    .accessibilityHint(
                                        status == .loggedIn
                                            ? "\(identity.title) 계정 페이지를 앱 안에서 다시 엽니다"
                                            : "\(identity.title) 공식 로그인 페이지를 앱 안에서 엽니다"
                                    )
                                }
                            }
                        }
                    }
                }

                Divider()

                Toggle("브라우저 보기", isOn: $showsExternalAIBrowser)
                    .accessibilityHint("켜면 외부 AI가 글을 만드는 브라우저를 처음부터 보여줍니다")
            } header: {
                BrandSectionTitle(title: "AI 사용 및 로그인", systemImage: "checklist")
            } footer: {
                Text("끈 AI는 스튜디오와 자동화에서 선택할 수 없어요. 클라우드 AI를 모두 꺼도 아이폰 AI는 계속 쓸 수 있어요. 로그인 상태를 눌러 계정 페이지를 열 수 있어요. 브라우저 보기는 기본적으로 꺼져 있고, 켜면 글을 만드는 과정을 처음부터 볼 수 있어요. 한 번 로그인하면 이 기기에서는 서비스가 로그아웃시키기 전까지 기억돼요. Stargram은 비밀번호를 보거나 저장하지 않아요.")
            }

            Section {
                if let url = diagnosticsStore.exportURL {
                    ShareLink(item: url) {
                        Label("최근 진단 로그 공유", systemImage: "square.and.arrow.up")
                    }
                } else if diagnosticsStore.storageError == nil {
                    Text("AI를 실행하면 진단 로그가 생겨요.")
                        .foregroundStyle(.secondary)
                }
                if let error = diagnosticsStore.storageError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                BrandSectionTitle(title: "AI 진단 로그", systemImage: "doc.text.magnifyingglass")
            } footer: {
                Text("최근 10회 실행의 단계·소요 시간·첨부 및 전송 상태와 앱·연결 방식 버전을 기기에 보관해요. 사진, 입력한 글, AI 답변, 계정 정보는 기록하지 않아요. 직접 공유할 때만 로그 파일을 전달합니다.")
            }

            Section {
                LabeledContent("현재 버전") {
                    Text(Self.appVersionText)
                        .foregroundStyle(.secondary)
                }
                Button {
                    openAppStore()
                } label: {
                    Label("App Store에서 업데이트 확인", systemImage: "arrow.down.circle")
                }
                .accessibilityHint("App Store 앱을 열어 최신 버전이 있는지 확인합니다")
            } header: {
                BrandSectionTitle(title: "앱 업데이트 관리", systemImage: "arrow.triangle.2.circlepath.circle.fill")
            } footer: {
                Text("App Store에서 최신 버전을 확인하고 설치할 수 있어요.")
            }

            Section {
                Picker("테마", selection: $appearanceStyleRaw) {
                    ForEach(AppearanceStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                BrandSectionTitle(title: "테마 관리", systemImage: "paintbrush.pointed.fill")
            } footer: {
                Text("BK는 기본 모습, 클래식은 예전 모습, 인터스텔라는 은빛과 금빛이 도는 어두운 모습이에요.")
            }

        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        // ContentView reserves the bar's safe area for its child, but Form's scroll content
        // needs its own terminal margin to stop above the floating controls.
        .contentMargins(.bottom, 96, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(theme.canvasGradient)
        .background(
            ExternalAILoginStatusProbeView(store: loginStatusStore)
        )
        .navigationTitle("설정")
        .onAppear {
            loginStatusStore.refreshAll()
        }
        .onChange(of: appearanceStyleRaw) { _, newValue in
            updateAppIcon(for: newValue)
        }
        .onChange(of: automationEnabled) { _, isEnabled in
            automationCoordinator.setAutomationEnabled(isEnabled)
        }
        .sheet(item: $loginProvider) { provider in
            ExternalAILoginSheet(provider: provider) {
                loginStatusStore.markLoggedIn(provider)
            }
        }
    }

    private func availabilityBinding(for identity: AIProviderIdentity) -> Binding<Bool> {
        Binding(
            get: { availabilityStore.isEnabled(identity) },
            set: { availabilityStore.setEnabled($0, for: identity) }
        )
    }

    private func lastRunSubtitle(for identity: AIProviderIdentity) -> String {
        guard let metric = runMetricsStore.metric(for: identity) else { return "아직 실행 안 함" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        let elapsed = String(format: "%.1f", metric.elapsedSeconds)
        return "마지막 실행 \(formatter.string(from: metric.lastRunAt)) · \(elapsed)초 걸림"
    }

    private static var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    private func openAppStore() {
        guard let url = URL(string: "itms-apps://apps.apple.com/") else { return }
        UIApplication.shared.open(url)
    }

    private func updateAppIcon(for rawValue: String) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let iconName: String?
        switch AppearanceStyle(rawValue: rawValue) ?? .bk {
        case .bk: iconName = "AppIconBK"
        case .classic: iconName = "AppIconClassic"
        case .interstellar: iconName = nil
        }
        guard UIApplication.shared.alternateIconName != iconName else { return }
        UIApplication.shared.setAlternateIconName(iconName)
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
    }
    .environmentObject(CreatorProfileStore())
    .environmentObject(AutomationCoordinator.shared)
    .environmentObject(AIProviderAvailabilityStore())
    .environmentObject(AIRunMetricsStore())
}
