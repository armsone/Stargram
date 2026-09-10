import SwiftUI
import WebKit

enum ExternalAIProvider: String, CaseIterable, Identifiable, Sendable, Hashable {
    case openAI
    case gemini
    case grok
    case claude

    /// 사용자에게 제공하는 외부 AI 목록. Grok은 결과에 서비스 UI 문구가 반복해서
    /// 섞이는 문제가 있어 생성 및 로그인 관리 화면에서 제외한다.
    static let allCases: [ExternalAIProvider] = [.gemini, .openAI, .claude]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "ChatGPT"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .claude: "Claude"
        }
    }
}

enum ExternalAIFallbackReason: String, Identifiable, Sendable {
    case login
    case captcha
    case interaction
    case timeout
    case navigation

    var id: String { rawValue }

    var userMessage: String {
        switch self {
        case .login: "로그인이 필요해요"
        case .captcha: "보안 확인이 필요해요"
        case .interaction: "화면 확인이 필요해요"
        case .timeout: "입력창을 찾지 못했어요"
        case .navigation: "다른 페이지로 이동했어요"
        }
    }

    var detailMessage: String {
        switch self {
        case .login: "서비스에 로그인하면 자동으로 글을 이어서 써요."
        case .captcha: "보안 확인을 마치면 자동으로 글을 이어서 써요."
        case .interaction: "화면을 직접 확인하고 필요한 버튼을 눌러 주세요."
        case .timeout: "화면에서 로그인이나 입력을 직접 확인해 주세요."
        case .navigation: "원래 대화 화면으로 돌아가거나 직접 확인해 주세요."
        }
    }

    var iconName: String {
        switch self {
        case .login: "person.crop.circle.badge.exclamationmark"
        case .captcha: "shield.lefthalf.filled"
        case .interaction: "hand.tap.fill"
        case .timeout: "clock.badge.exclamationmark"
        case .navigation: "arrow.triangle.turn.up.right.diamond.fill"
        }
    }
}

struct ExternalAIBrowserContext: Identifiable, Sendable, Equatable {
    let id = UUID()
    let provider: ExternalAIProvider
    let fallbackReason: ExternalAIFallbackReason?

    init(provider: ExternalAIProvider, fallbackReason: ExternalAIFallbackReason? = nil) {
        self.provider = provider
        self.fallbackReason = fallbackReason
    }
}

/// 백그라운드에서 실행되는 숨겨진 자동화 뷰.
/// 화면에 직접 보이지 않고 DOM 자동 입력을 수행하며,
/// 로그인·캡차 등의 사용자 개입이 필요한 경우 즉시 폴백을 요청한다.
struct ExternalAIHiddenAutomatorView: View {
    let provider: ExternalAIProvider
    let prompt: String
    var attachments: [AIBIMediaAttachment] = []
    let generationID: UUID?
    var onSubmitted: ((Date) -> Void)? = nil
    let onSuccess: (String) -> Void
    let onFallback: (ExternalAIFallbackReason) -> Void
    let onError: (String) -> Void

    @StateObject private var bridge = ExternalAIBrowserBridge()
    @State private var hasSubmitted = false
    @State private var hasImported = false
    @State private var hasTriggeredFallback = false
    @State private var hasAttemptedAttach = false
    @State private var attachConfirmed = false
    @State private var hasPreparedFreshComposer = false

    var body: some View {
        ExternalAIWebView(provider: provider, bridge: bridge)
            .id(generationID)
            .frame(width: 375, height: 667)
            .task(id: bridge.navigationGeneration) {
                await handleNavigationUpdate()
            }
            .onChange(of: generationID) { _, _ in
                hasSubmitted = false
                hasImported = false
                hasTriggeredFallback = false
                hasAttemptedAttach = false
                attachConfirmed = false
                hasPreparedFreshComposer = false
            }
            .onChange(of: bridge.isAnswerStable) { _, stable in
                guard stable, !bridge.latestAnswer.isEmpty, !hasImported, !hasTriggeredFallback else { return }
                hasImported = true
                let cleaned = ExternalAIBrowserSheet.cleanedImportedAnswer(bridge.latestAnswer, provider: provider)
                if !cleaned.isEmpty {
                    UIPasteboard.general.string = cleaned
                    onSuccess(cleaned)
                }
            }
            .onChange(of: bridge.isGenerating) { _, isGen in
                if isGen, !hasSubmitted {
                    hasSubmitted = true
                    onSubmitted?(Date())
                }
            }
            .onChange(of: bridge.interactionReason) { _, reason in
                guard let reason, !hasImported, !hasTriggeredFallback else { return }
                hasTriggeredFallback = true
                onFallback(reason)
            }
            .onChange(of: bridge.detectedError) { _, error in
                guard let error, !error.isEmpty, !hasImported, !hasTriggeredFallback else { return }
                hasTriggeredFallback = true
                let sanitized = ExternalAIBrowserBridge.sanitizeErrorMessage(error, provider: provider)
                onError(sanitized)
            }
    }

    private func handleNavigationUpdate() async {
        guard !hasSubmitted, !hasImported, !hasTriggeredFallback else { return }
        let deadline = Date().addingTimeInterval(35)
        var checkCount = 0

        while !Task.isCancelled, Date() < deadline, !hasSubmitted, !hasImported, !hasTriggeredFallback {
            if let error = bridge.detectedError, !error.isEmpty {
                hasTriggeredFallback = true
                let sanitized = ExternalAIBrowserBridge.sanitizeErrorMessage(error, provider: provider)
                onError(sanitized)
                return
            }

            if let reason = bridge.interactionReason {
                hasTriggeredFallback = true
                onFallback(reason)
                return
            }

            // 제공사 웹앱이 이전 실패 초안과 첨부 카드를 로컬 세션에 복원할 수 있다.
            // 이번 자동화 입력을 넣기 전에 반드시 깨끗한 작성창으로 만든다.
            if bridge.isPageReady, !hasPreparedFreshComposer {
                var prepared = false
                for _ in 0..<8 where !prepared {
                    prepared = await bridge.prepareFreshComposer(for: provider)
                    if !prepared { try? await Task.sleep(nanoseconds: 300_000_000) }
                }
                guard prepared else {
                    hasTriggeredFallback = true
                    onFallback(.interaction)
                    return
                }
                hasPreparedFreshComposer = true
            }

            // 선택한 사진 전부를 원자적으로 첨부하지 못하면 사진을 빼고 글만 보내지 않는다.
            if !attachments.isEmpty, !attachConfirmed, bridge.isPageReady {
                if !hasAttemptedAttach {
                    hasAttemptedAttach = true
                    attachConfirmed = await bridge.attachPhotos(attachments, provider: provider)
                    if !attachConfirmed {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        attachConfirmed = await bridge.isAttachmentCountConfirmed(attachments.count)
                    }
                }
                if !attachConfirmed {
                    hasTriggeredFallback = true
                    onFallback(.interaction)
                    return
                }
            }

            if bridge.isPageReady, attachments.isEmpty || attachConfirmed {
                checkCount += 1
                // 숨은 자동화 브라우저는 사용자 편집 화면이 아니므로 이전 초안이 있더라도
                // 이번 요청의 정확한 문구로 교체한다.
                let filled = await bridge.fillPrompt(prompt, force: true)
                if filled {
                    if await submitPromptWhenReady() {
                        return
                    }
                    if bridge.hasAttemptedSubmission {
                        hasTriggeredFallback = true
                        onError("전송 뒤 응답 시작을 확인하지 못했어요. 설정의 AI 진단 로그를 공유해 주세요.")
                        return
                    }
                } else if checkCount >= 12 { // 약 8초 동안 입력창 미발견 시 로그인/개입 필요 판단
                    if let reason = bridge.interactionReason {
                        hasTriggeredFallback = true
                        onFallback(reason)
                    } else {
                        hasTriggeredFallback = true
                        onFallback(.login)
                    }
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }

        if !Task.isCancelled, !hasSubmitted, !hasImported, !hasTriggeredFallback {
            hasTriggeredFallback = true
            onFallback(.timeout)
        }
    }

    private func submitPromptWhenReady() async -> Bool {
        guard !hasSubmitted else { return true }
        let deadline = Date().addingTimeInterval(15)
        while !Task.isCancelled, Date() < deadline, !hasSubmitted, !hasTriggeredFallback {
            if await bridge.submitPrompt() {
                hasSubmitted = true
                onSubmitted?(Date())
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !Task.isCancelled, !hasSubmitted { bridge.log("send_timeout") }
        return hasSubmitted
    }
}

/// ChatGPT·Gemini·Claude 웹사이트를 앱 안에서 열어 프롬프트를 채워 넣고,
/// 완성된 답변을 감지해 가져올 수 있게 해 주는 화면.
/// 사용자 개입이 필요한 경우 상단에 안내 배너를 함께 표시한다.
struct ExternalAIBrowserSheet: View {
    let provider: ExternalAIProvider
    let prompt: String
    var attachments: [AIBIMediaAttachment] = []
    var fallbackReason: ExternalAIFallbackReason? = nil
    var onSubmitted: ((Date) -> Void)? = nil
    var onError: ((String) -> Void)? = nil
    let onImport: (String) -> Void
    let onManualCopyFallback: () -> Void
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = ExternalAIBrowserBridge()
    @State private var hasFilledPrompt = false
    @State private var fillFailed = false
    @State private var hasImported = false
    @State private var isAutoFilling = false
    @State private var hasSubmittedPrompt = false
    @State private var submitFailed = false
    @State private var submittedAt: Date?
    @State private var elapsedSeconds = 0
    @State private var detectedErrorMessage: String?
    @State private var hasAttemptedAttach = false
    @State private var attachConfirmed = false
    @State private var needsManualAttach = false
    @State private var refillTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let reason = fallbackReason {
                    fallbackBanner(reason)
                }
                if needsManualAttach, !attachConfirmed {
                    manualAttachBanner
                }
                if let detectedErrorMessage {
                    errorBanner(detectedErrorMessage)
                }
                if submittedAt != nil, !hasImported, detectedErrorMessage == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("답변을 기다리는 중")
                            Spacer()
                            Text("남은 시간 \(Self.formatCountdown(remainingSeconds))")
                        }
                        .font(.caption.weight(.semibold))
                        ProgressView(value: Double(remainingSeconds), total: Double(Self.generationTimeoutSeconds))
                            .progressViewStyle(.linear)
                            .tint(BrandTheme.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground))
                }
                ExternalAIWebView(provider: provider, bridge: bridge)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        refillTask?.cancel()
                        onDismiss?()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("\(provider.title)에서 만들기")
                            .font(.subheadline.weight(.semibold))
                        Label(statusText, systemImage: statusIcon)
                            .font(.caption2)
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if !bridge.latestAnswer.isEmpty, !hasImported {
                        Button {
                            importAnswer(bridge.latestAnswer)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel("지금 가져오기")
                        .accessibilityHint("지금 보이는 답변을 바로 게시물로 가져옵니다")
                    }
                    Menu {
                        Button {
                            refillTask?.cancel()
                            refillTask = Task {
                                guard await attachPhotoIfNeeded() else { return }
                                if await fillPrompt(force: true) {
                                    await submitPromptWhenReady()
                                }
                            }
                        } label: {
                            Label("다시 넣기", systemImage: "text.cursor")
                        }
                        .disabled(!bridge.isPageReady)

                        Button {
                            UIPasteboard.general.string = prompt
                            onManualCopyFallback()
                        } label: {
                            Label("문구 복사", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("추가 옵션")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .task(id: bridge.navigationGeneration) {
                await autoFillWhenReady()
            }
            .onDisappear {
                refillTask?.cancel()
                refillTask = nil
            }
            .onChange(of: bridge.isAnswerStable) { _, stable in
                guard stable, !bridge.latestAnswer.isEmpty, !hasImported else { return }
                importAnswer(bridge.latestAnswer)
            }
            .onChange(of: bridge.isGenerating) { _, isGenerating in
                guard isGenerating, submittedAt == nil else { return }
                hasSubmittedPrompt = true
                markSubmitted()
            }
            .onChange(of: bridge.detectedError) { _, error in
                guard let error, !error.isEmpty else { return }
                let sanitized = ExternalAIBrowserBridge.sanitizeErrorMessage(error, provider: provider)
                detectedErrorMessage = sanitized
                onError?(sanitized)
            }
            .task(id: submittedAt) {
                guard let submittedAt else {
                    elapsedSeconds = 0
                    return
                }
                while !Task.isCancelled, !hasImported, detectedErrorMessage == nil {
                    elapsedSeconds = max(0, Int(Date().timeIntervalSince(submittedAt)))
                    if elapsedSeconds >= Self.generationTimeoutSeconds {
                        let message = "1분 59초 동안 답변이 없어서 중단했어요. 다시 시도해 주세요."
                        detectedErrorMessage = message
                        onError?(message)
                        dismiss()
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))
    }

    private var manualAttachBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "photo.badge.plus")
                .font(.headline)
                .foregroundStyle(BrandTheme.accent)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("선택한 사진을 모두 첨부해 주세요")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text("화면의 첨부 버튼으로 사진 \(attachments.count)장을 모두 추가하면 이어서 자동으로 진행돼요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func fallbackBanner(_ reason: ExternalAIFallbackReason) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: reason.iconName)
                .font(.headline)
                .foregroundStyle(BrandTheme.accent)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(reason.userMessage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(reason.detailMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func importAnswer(_ text: String) {
        guard !hasImported else { return }
        let cleanedText = Self.cleanedImportedAnswer(text, provider: provider)
        guard !cleanedText.isEmpty else { return }
        hasImported = true
        UIPasteboard.general.string = cleanedText
        dismiss()
        onImport(cleanedText)
    }

    static func cleanedImportedAnswer(_ text: String, provider: ExternalAIProvider) -> String {
        var normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .grok {
            normalizedText = removingGrokWorkDurationPrefix(from: normalizedText)
        }

        var lines = normalizedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)

        if provider == .grok,
           let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           isGrokWorkDurationHeader(first) {
            lines.removeFirst()
        }

        let removableHeaders: Set<String> = ["글", "본문", "답변", "결과", "text", "plaintext", "markdown"]
        if lines.count > 1,
           let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           removableHeaders.contains(first.lowercased()) {
            lines.removeFirst()
        }

        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
            lines.removeLast()
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isGrokWorkDurationHeader(_ text: String) -> Bool {
        let patterns = [
            #"^\d+\s*(?:s|m|h|초|분|시간)\s*(?:동안\s*)?(?:작업함|생각함)$"#,
            #"^(?:worked|thought)\s+for\s+\d+\s*(?:s|m|h|seconds?|minutes?|hours?)$"#
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func removingGrokWorkDurationPrefix(from text: String) -> String {
        // Grok의 작업시간 UI에는 일반 공백처럼 보이는 format 문자나 U+2028/U+2029가
        // 섞일 수 있어 줄 단위 비교만으로는 제거되지 않는다. 응답 맨 앞의 UI 문구를
        // 보이지 않는 문자까지 포함해 직접 잘라 낸다.
        let patterns = [
            #"^[\s\p{Cf}]*\d+[\s\p{Cf}]*(?:s|m|h|초|분|시간)[\s\p{Cf}]*(?:동안)?[\s\p{Cf}]*(?:작업함|생각함)[\s\p{Cf}]*"#,
            #"^[\s\p{Cf}]*(?:worked|thought)[\s\p{Cf}]+for[\s\p{Cf}]+\d+[\s\p{Cf}]*(?:s|m|h|seconds?|minutes?|hours?)[\s\p{Cf}]*"#
        ]
        var result = text
        for pattern in patterns {
            if let range = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                result.removeSubrange(range)
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 각 메인 프레임 내비게이션이 끝날 때마다(로그인 리디렉션 포함) 호출되어,
    /// 입력창이 나타날 때까지 정해진 시간(45초) 동안 재시도한다.
    /// `.task(id:)`가 새 내비게이션 세대마다 이전 시도를 자동으로 취소해 준다.
    /// 첨부가 필요 없으면 즉시 통과하고, 필요하면 한 번 자동 첨부를 시도한 뒤 첨부 확인
    /// 여부를 돌려준다. 자동 첨부가 실패하면 배너로 사용자에게 직접 첨부를 안내하고,
    /// 이후 호출에서 사용자가 직접 첨부했는지를 다시 확인한다.
    private func attachPhotoIfNeeded() async -> Bool {
        guard !attachments.isEmpty else { return true }
        if attachConfirmed { return true }
        if !hasAttemptedAttach {
            hasAttemptedAttach = true
            attachConfirmed = await bridge.attachPhotos(attachments, provider: provider)
            if !attachConfirmed {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        if !attachConfirmed {
            attachConfirmed = await bridge.isAttachmentCountConfirmed(attachments.count)
        }
        needsManualAttach = !attachConfirmed
        return attachConfirmed
    }

    private func autoFillWhenReady() async {
        guard !hasSubmittedPrompt else { return }
        isAutoFilling = true
        defer { isAutoFilling = false }
        let deadline = Date().addingTimeInterval(45)
        while !Task.isCancelled, Date() < deadline, !hasSubmittedPrompt {
            if bridge.isPageReady, await attachPhotoIfNeeded() {
                // 새 요청의 스냅샷은 기존 대화창 초안이나 iOS의 클립보드 제안보다
                // 항상 우선한다. 사용자가 이미 적어 둔 웹 입력은 이 자동 실행 전에
                // 만든 내용이므로 이번 요청으로 섞어 보내지 않는다.
                if await fillPrompt(force: true) {
                    if await submitPromptWhenReady() {
                        return
                    }
                    if bridge.hasAttemptedSubmission {
                        let message = "전송 뒤 응답 시작을 확인하지 못했어요. 설정의 AI 진단 로그를 공유해 주세요."
                        detectedErrorMessage = message
                        onError?(message)
                        return
                    }
                    // ChatGPT가 초기 화면을 늦게 다시 그리면 방금 채운 입력창이 교체되어
                    // 문구가 사라질 수 있다. 전송이 확인되지 않은 경우 입력 완료 상태를
                    // 되돌려 같은 내비게이션 안에서도 다시 채우고 전송한다.
                    hasFilledPrompt = false
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        if !Task.isCancelled, !hasSubmittedPrompt {
            fillFailed = true
            let message = "45초 동안 AI 입력창을 준비하지 못했어요. 다시 시도해 주세요."
            detectedErrorMessage = message
            onError?(message)
            dismiss()
        }
    }

    @discardableResult
    private func submitPromptWhenReady() async -> Bool {
        guard !hasSubmittedPrompt else { return true }
        submitFailed = false
        let deadline = Date().addingTimeInterval(15)
        while !Task.isCancelled, Date() < deadline, !hasSubmittedPrompt {
            if await bridge.submitPrompt() {
                hasSubmittedPrompt = true
                markSubmitted()
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !Task.isCancelled, !hasSubmittedPrompt {
            submitFailed = true
            bridge.log("send_timeout")
        }
        return hasSubmittedPrompt
    }

    @discardableResult
    private func fillPrompt(force: Bool) async -> Bool {
        let success = await bridge.fillPrompt(prompt, force: force)
        if success {
            hasFilledPrompt = true
            fillFailed = false
        } else if force {
            fillFailed = true
        }
        return success
    }

    private var statusText: String {
        if let detectedErrorMessage { return detectedErrorMessage }
        if hasImported {
            return "답변을 가져왔어요"
        }
        if bridge.isGenerating || hasSubmittedPrompt {
            return "남은 시간 \(Self.formatCountdown(remainingSeconds))"
        }
        if !bridge.latestAnswer.isEmpty {
            return "답변이 끝나가는 중이에요…"
        }
        if !bridge.isPageReady {
            return "페이지를 불러오는 중…"
        }
        if hasFilledPrompt {
            if submitFailed { return "자동 전송 실패 · 보내기 버튼을 눌러 주세요" }
            if hasSubmittedPrompt { return "답변을 기다리는 중…" }
            return "자동으로 보내는 중…"
        }
        if isAutoFilling {
            return "입력창에 자동으로 채우는 중…"
        }
        if fillFailed {
            return "채우기 실패 · ⋯ 메뉴에서 다시 넣기나 문구 복사를 써 주세요"
        }
        return "입력창을 기다리는 중…"
    }

    private static let generationTimeoutSeconds = 119

    private var remainingSeconds: Int {
        max(0, Self.generationTimeoutSeconds - elapsedSeconds)
    }

    private var statusIcon: String {
        if detectedErrorMessage != nil { return "exclamationmark.triangle.fill" }
        if hasImported { return "checkmark.circle.fill" }
        if fillFailed { return "exclamationmark.triangle.fill" }
        return "info.circle"
    }

    private var statusColor: Color {
        if detectedErrorMessage != nil { return .red }
        if hasImported { return .green }
        if fillFailed { return .orange }
        return .secondary
    }

    private func markSubmitted() {
        guard submittedAt == nil else { return }
        let date = Date()
        submittedAt = date
        elapsedSeconds = 0
        onSubmitted?(date)
    }

    private static func formatCountdown(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// 설정 화면에서 하나의 AI 서비스 로그인 상태를 나타내는 세 가지 값.
/// 쿠키 존재 여부나 로그인 버튼의 부재만으로는 판단하지 않고, 계정 메뉴 등
/// 실제 로그인 후에만 나타나는 DOM 요소를 근거로 판단한다.
enum ExternalAILoginStatus: Equatable, Sendable {
    case checking
    case loggedIn
    case needsLogin

    var title: String {
        switch self {
        case .checking: "확인 중"
        case .loggedIn: "로그인됨"
        case .needsLogin: "로그인 필요"
        }
    }

    var iconName: String {
        switch self {
        case .checking: "ellipsis.circle"
        case .loggedIn: "checkmark.circle.fill"
        case .needsLogin: "exclamationmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .checking: .secondary
        case .loggedIn: .green
        case .needsLogin: .orange
        }
    }
}

/// 설정 화면에 표시할 제공사별 로그인 상태를 보관한다.
/// 실제 확인은 `ExternalAILoginStatusProbeView`가 웹뷰를 한 번에 하나씩만 띄워 순차적으로 수행한다.
@MainActor
final class ExternalAILoginStatusStore: ObservableObject {
    @Published private(set) var statuses: [ExternalAIProvider: ExternalAILoginStatus] = [:]
    @Published fileprivate var refreshToken = 0

    func status(for provider: ExternalAIProvider) -> ExternalAILoginStatus {
        statuses[provider] ?? .checking
    }

    func refreshAll() {
        for provider in ExternalAIProvider.allCases {
            statuses[provider] = .checking
        }
        refreshToken += 1
    }

    func markLoggedIn(_ provider: ExternalAIProvider) {
        statuses[provider] = .loggedIn
    }

    fileprivate func setStatus(_ status: ExternalAILoginStatus, for provider: ExternalAIProvider) {
        if statuses[provider] == .loggedIn && status == .checking {
            return
        }
        statuses[provider] = status
    }
}

/// 화면에 보이지 않는 웹뷰 하나로 제공사를 순서대로 방문해 로그인 상태를 확인한다.
/// 세 개의 무거운 브라우저 뷰를 동시에 띄워 두지 않도록, 한 제공사 확인이 끝나야 다음으로 넘어간다.
struct ExternalAILoginStatusProbeView: View {
    @ObservedObject var store: ExternalAILoginStatusStore
    @State private var currentIndex = 0

    var body: some View {
        ZStack {
            if currentIndex < ExternalAIProvider.allCases.count {
                let provider = ExternalAIProvider.allCases[currentIndex]
                ExternalAILoginStatusSingleProbe(provider: provider) { status in
                    store.setStatus(status, for: provider)
                    currentIndex += 1
                }
                .id("\(store.refreshToken)-\(currentIndex)")
                .frame(width: 375, height: 667)
                .offset(x: -10_000, y: -10_000)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0.001)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: store.refreshToken) { _, _ in
            currentIndex = 0
        }
    }
}

private struct ExternalAILoginStatusSingleProbe: View {
    let provider: ExternalAIProvider
    let onFinished: (ExternalAILoginStatus) -> Void

    @StateObject private var bridge = ExternalAILoginProbeBridge()
    @State private var hasFinished = false

    var body: some View {
        ExternalAILoginProbeWebView(provider: provider, bridge: bridge)
            .task {
                await runProbe()
            }
    }

    private func runProbe() async {
        let deadline = Date().addingTimeInterval(8)
        while !Task.isCancelled, Date() < deadline, !hasFinished {
            if bridge.loginOriginDetected {
                finish(.needsLogin)
                return
            }
            if bridge.isPageReady, !bridge.challengeOriginDetected {
                let result = await bridge.checkAuthStatus(provider: provider)
                guard !Task.isCancelled else { return }
                if result.authenticated {
                    finish(.loggedIn)
                    return
                }
                if result.hasLogin {
                    finish(.needsLogin)
                    return
                }
                if result.hasChallenge {
                    finish(.checking)
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        guard !Task.isCancelled else { return }
        // 네트워크 오류, 챌린지, 늦은 페이지 구성처럼 확실한 증거가 없는 경우에는
        // 사용자가 로그인하지 않았다고 추측하지 않는다.
        finish(.checking)
    }

    private func finish(_ status: ExternalAILoginStatus) {
        guard !hasFinished else { return }
        hasFinished = true
        onFinished(status)
    }
}

/// 설정 화면에서 로그인만 하기 위해 여는 가벼운 브라우저.
/// 프롬프트를 채우거나 답변을 읽지 않고, 제공사의 공식 로그인 페이지만 보여준다.
/// 이미 로그인된 세션이면 DOM 상 계정 메뉴 등장을 감지해 성공을 짧게 알리고 자동으로 닫는다.
struct ExternalAILoginSheet: View {
    let provider: ExternalAIProvider
    var onLoginConfirmed: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = ExternalAILoginProbeBridge()
    @State private var didConfirmLogin = false
    @State private var hasDismissed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if didConfirmLogin {
                    confirmedBanner
                }
                ExternalAILoginProbeWebView(provider: provider, bridge: bridge)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("\(provider.title) 로그인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismissOnce() }
                }
            }
        }
        .task(id: provider) {
            await pollLoginStatus()
        }
    }

    private func dismissOnce() {
        guard !hasDismissed else { return }
        hasDismissed = true
        dismiss()
    }

    private var confirmedBanner: some View {
        Label("로그인을 확인했어요", systemImage: "checkmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))
    }

    private func pollLoginStatus() async {
        while !Task.isCancelled, !didConfirmLogin {
            if bridge.isPageReady,
               !bridge.loginOriginDetected,
               !bridge.challengeOriginDetected {
                let result = await bridge.checkAuthStatus(provider: provider)
                if result.authenticated {
                    confirmLogin()
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }

    private func confirmLogin() {
        guard !didConfirmLogin else { return }
        didConfirmLogin = true
        Task {
            // 새로 발급된 세션 쿠키가 같은 WKWebsiteDataStore.default()를 공유하는
            // 다른 웹뷰(상태 확인 프로브, 숨겨진 자동화 뷰)에도 즉시 반영되도록
            // 커밋을 강제한 뒤에 로그인 확정을 알린다.
            await Self.flushSharedWebsiteDataStore()
            onLoginConfirmed?()
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismissOnce()
        }
    }

    private static func flushSharedWebsiteDataStore() async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { _ in
                continuation.resume()
            }
        }
    }
}

struct ExternalAIAuthProbeResult: Sendable {
    let authenticated: Bool
    let hasLogin: Bool
    let hasChallenge: Bool
}

/// 로그인 상태 확인에 쓰는 최소한의 웹뷰 브릿지.
/// 프롬프트 자동 입력이나 답변 읽기는 하지 않고, 내비게이션 상태와 로그인 판별만 담당한다.
@MainActor
final class ExternalAILoginProbeBridge: ObservableObject {
    @Published fileprivate(set) var isPageReady = false
    @Published fileprivate(set) var loginOriginDetected = false
    @Published fileprivate(set) var challengeOriginDetected = false

    fileprivate weak var webView: WKWebView?

    fileprivate func didStartNavigation() {
        isPageReady = false
    }

    fileprivate func checkURL(_ urlString: String) {
        loginOriginDetected = ExternalAIBrowserBridge.isLoginURL(urlString)
        challengeOriginDetected = ExternalAIBrowserBridge.isChallengeURL(urlString)
    }

    fileprivate func markNavigationFinished() {
        isPageReady = true
    }

    func checkAuthStatus(provider: ExternalAIProvider) async -> ExternalAIAuthProbeResult {
        guard let webView else {
            return ExternalAIAuthProbeResult(authenticated: false, hasLogin: false, hasChallenge: false)
        }
        if let url = webView.url?.absoluteString {
            checkURL(url)
        }
        let script = ExternalAIBrowserScripts.authStatusProbeScript(for: provider)
        do {
            let result = try await webView.evaluateJavaScript(script)
            return Self.parseAuthProbeResult(result)
        } catch {
            return ExternalAIAuthProbeResult(authenticated: false, hasLogin: false, hasChallenge: false)
        }
    }

    private static func parseAuthProbeResult(_ raw: Any?) -> ExternalAIAuthProbeResult {
        if let dict = raw as? [String: Any] {
            let authenticated = (dict["authenticated"] as? Bool) ?? false
            let hasLogin = (dict["hasLogin"] as? Bool) ?? false
            let hasChallenge = (dict["hasChallenge"] as? Bool) ?? false
            return ExternalAIAuthProbeResult(authenticated: authenticated, hasLogin: hasLogin, hasChallenge: hasChallenge)
        }
        if let string = raw as? String,
           let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let authenticated = (json["authenticated"] as? Bool) ?? false
            let hasLogin = (json["hasLogin"] as? Bool) ?? false
            let hasChallenge = (json["hasChallenge"] as? Bool) ?? false
            return ExternalAIAuthProbeResult(authenticated: authenticated, hasLogin: hasLogin, hasChallenge: hasChallenge)
        }
        return ExternalAIAuthProbeResult(authenticated: false, hasLogin: false, hasChallenge: false)
    }
}

private struct ExternalAILoginProbeWebView: UIViewRepresentable {
    let provider: ExternalAIProvider
    @ObservedObject var bridge: ExternalAILoginProbeBridge

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 앱 안에서만 쓰는 영구 저장소. Composer의 AI 브라우저와 이 저장소를 공유해 로그인이
        // 이어지지만, 사파리의 쿠키 저장소와는 별개이며 제공사가 세션을 만료시키면 다시 로그인해야 한다.
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        bridge.webView = webView
        webView.load(URLRequest(url: provider.chatURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let bridge: ExternalAILoginProbeBridge

        init(bridge: ExternalAILoginProbeBridge) {
            self.bridge = bridge
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            bridge.didStartNavigation()
            if let url = webView.url?.absoluteString {
                bridge.checkURL(url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url?.absoluteString {
                bridge.checkURL(url)
            }
            bridge.markNavigationFinished()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url?.absoluteString {
                bridge.checkURL(url)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            bridge.markNavigationFinished()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            bridge.markNavigationFinished()
        }
    }
}

/// WKWebView 안 상태(페이지 준비, 생성 중, 답변 안정 여부, 오류 감지)를 SwiftUI로 전달하는 저장소.
@MainActor
final class ExternalAIBrowserBridge: ObservableObject {
    @Published fileprivate(set) var isPageReady = false
    @Published fileprivate(set) var isGenerating = false
    @Published fileprivate(set) var isAnswerStable = false
    @Published fileprivate(set) var latestAnswer = ""
    /// 메인 프레임 내비게이션이 끝날 때마다 증가한다. SwiftUI가 이 값을 `.task(id:)`로 관찰해
    /// 로그인 리디렉션 이후에도 자동 채우기 시도를 다시 시작할 수 있게 한다.
    @Published fileprivate(set) var navigationGeneration = 0
    @Published fileprivate(set) var interactionReason: ExternalAIFallbackReason?
    @Published fileprivate(set) var detectedError: String?

    fileprivate weak var webView: WKWebView?
    fileprivate var pendingAttachmentURLs: [URL] = []
    fileprivate var nativeUploadPanelHandled = false
    private(set) var hasAttemptedSubmission = false
    private var expectedAttachmentCount = 0
    fileprivate var diagnosticRunID: UUID?
    private var lastDiagnosticSnapshot: [String: Int] = [:]

    fileprivate func log(_ event: String, _ metrics: [String: Int] = [:]) {
        guard let diagnosticRunID else { return }
        if event == "bridge_snapshot" {
            guard metrics != lastDiagnosticSnapshot else { return }
            lastDiagnosticSnapshot = metrics
        }
        AIBIDiagnosticsStore.shared.record(runID: diagnosticRunID, event: event, metrics: metrics)
    }

    func checkURLForInteraction(_ urlString: String) {
        if Self.isLoginURL(urlString) {
            interactionReason = .login
        } else if Self.isChallengeURL(urlString) {
            interactionReason = .captcha
        }
    }

    static func isLoginURL(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return lower.contains("accounts.google.com") || lower.contains("auth.openai.com") || lower.contains("claude.ai/login") || lower.contains("/login") || lower.contains("/signin") || lower.contains("/signup") || lower.contains("auth0")
    }

    static func isChallengeURL(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return lower.contains("challenge") || lower.contains("checkpoint") || lower.contains("cloudflare") || lower.contains("turnstile") || lower.contains("recaptcha")
    }

    static func isLoginOrChallengeURL(_ urlString: String) -> Bool {
        isLoginURL(urlString) || isChallengeURL(urlString)
    }

    /// 입력창에 프롬프트를 채운다. 자동으로 보내지는 않는다.
    /// `force`가 false면 사용자가 이미 다른 내용을 입력해 둔 경우 덮어쓰지 않는다.
    /// JavaScript가 실제로 입력창을 채웠는지 여부를 그대로 돌려준다.
    @discardableResult
    func fillPrompt(_ prompt: String, force: Bool) async -> Bool {
        guard !Task.isCancelled, let webView, !hasAttemptedSubmission else { return false }
        let literal = ExternalAIBrowserScripts.jsStringLiteral(prompt)
        let script = "window.__starManagerFillPrompt && window.__starManagerFillPrompt(\(literal), \(force));"
        do {
            let result = try await webView.evaluateJavaScript(script)
            let success = Self.boolean(from: result)
            if success {
                log("prompt_inserted", ["prompt_length": prompt.count])
                isAnswerStable = false
                latestAnswer = ""
            }
            return success
        } catch {
            return false
        }
    }

    /// 선택한 1~8장의 정규화 사본을 한 배치로 연결하고, 미리보기 수가 정확히
    /// 그만큼 늘어난 경우에만 성공한다. 일부 사진만 올라간 상태에서는 전송하지 않는다.
    func attachPhotos(_ attachments: [AIBIMediaAttachment], provider: ExternalAIProvider) async -> Bool {
        guard !Task.isCancelled, let webView, (1...8).contains(attachments.count) else { return false }
        expectedAttachmentCount = attachments.count
        log("attachment_started", ["expected_count": attachments.count])
        let ordered = attachments.sorted { $0.sourceIndex < $1.sourceIndex }
        guard ordered.map(\.sourceIndex) == Array(0..<ordered.count) else { return false }
        let baseline = await attachmentPreviewCount() ?? 0
        let expectedCount = baseline + ordered.count

        if #available(iOS 18.4, *) {
            do {
                pendingAttachmentURLs = try makeTemporaryAttachmentFiles(ordered)
                nativeUploadPanelHandled = false
                for _ in 0..<4 where !nativeUploadPanelHandled {
                    guard !Task.isCancelled else { return false }
                    _ = try? await webView.evaluateJavaScript(
                        ExternalAIBrowserScripts.advancePhotoPanelScript(for: provider)
                    )
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
                if nativeUploadPanelHandled,
                   await waitForAttachmentCount(expectedCount) {
                    // 미리보기가 생긴 뒤에도 제공사가 파일 URL을 읽어 실제 업로드를 계속하므로
                    // 전송 확인 전에는 임시 파일을 지우지 않는다.
                    return true
                }
                guard !Task.isCancelled else { return false }
                clearPendingAttachmentFiles()
            } catch {
                clearPendingAttachmentFiles()
                nativeUploadPanelHandled = false
            }
        }

        guard !Task.isCancelled else { return false }
        do {
            let began = try await webView.evaluateJavaScript(
                "window.__starManagerBeginAttachmentBatch && window.__starManagerBeginAttachmentBatch(\(ordered.count));"
            )
            guard Self.boolean(from: began) else { return false }
            for (index, attachment) in ordered.enumerated() {
                guard !Task.isCancelled else { return false }
                let result = try await webView.callAsyncJavaScript(
                    "return window.__starManagerStageAttachment && window.__starManagerStageAttachment(dataURL, mime, index);",
                    arguments: [
                        "dataURL": attachment.dataURL,
                        "mime": attachment.mimeType,
                        "index": index
                    ],
                    in: nil,
                    contentWorld: .page
                )
                guard Self.boolean(from: result) else {
                    _ = try? await webView.evaluateJavaScript("window.__starManagerClearAttachmentBatch && window.__starManagerClearAttachmentBatch();")
                    return false
                }
            }
            guard !Task.isCancelled else { return false }
            let committed = try await webView.evaluateJavaScript(
                "window.__starManagerCommitAttachmentBatch && window.__starManagerCommitAttachmentBatch();"
            )
            guard Self.boolean(from: committed) else { return false }
            return await waitForAttachmentCount(expectedCount)
        } catch {
            _ = try? await webView.evaluateJavaScript("window.__starManagerClearAttachmentBatch && window.__starManagerClearAttachmentBatch();")
            return false
        }
    }

    private func makeTemporaryAttachmentFiles(_ attachments: [AIBIMediaAttachment]) throws -> [URL] {
        clearPendingAttachmentFiles()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIBIUploads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            return try attachments.map { attachment in
                let fileURL = directory.appendingPathComponent(attachment.filename)
                try attachment.data.write(to: fileURL, options: .atomic)
                return fileURL
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    fileprivate func clearPendingAttachmentFiles() {
        let directories = Set(pendingAttachmentURLs.map { $0.deletingLastPathComponent() })
        pendingAttachmentURLs = []
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func waitForAttachmentCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<240 {
            if Task.isCancelled { return false }
            if await attachmentPreviewCount() == expectedCount {
                log("attachment_ready", ["attached_count": expectedCount])
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        log("attachment_timeout", ["expected_count": expectedCount])
        return false
    }

    func isAttachmentCountConfirmed(_ expectedCount: Int) async -> Bool {
        await attachmentPreviewCount() == expectedCount
    }

    /// 이전 자동화에서 남은 문구와 실패/대기 첨부 카드를 제거한다.
    func prepareFreshComposer(for provider: ExternalAIProvider) async -> Bool {
        guard let webView else { return false }
        _ = try? await webView.evaluateJavaScript(
            ExternalAIBrowserScripts.resetComposerScript(for: provider)
        )
        try? await Task.sleep(nanoseconds: 180_000_000)
        return await attachmentPreviewCount() == 0
    }

    private func attachmentPreviewCount() async -> Int? {
        guard let webView else { return nil }
        do {
            let result = try await webView.evaluateJavaScript(
                "window.__starManagerAttachmentCount ? window.__starManagerAttachmentCount() : -1;"
            )
            if let number = result as? NSNumber { return number.intValue }
            return result as? Int
        } catch {
            return nil
        }
    }

    func submitPrompt() async -> Bool {
        guard !Task.isCancelled, let webView else { return false }
        do {
            if !hasAttemptedSubmission {
                let attachmentsReady = expectedAttachmentCount == 0 ? true : await isAttachmentCountConfirmed(expectedAttachmentCount)
                guard attachmentsReady else {
                    log("send_blocked", ["expected_count": expectedAttachmentCount, "attachment_verified": 0])
                    return false
                }
                guard !Task.isCancelled else { return false }
                let attempted = try await webView.evaluateJavaScript(
                    "window.__starManagerSendPrompt && window.__starManagerSendPrompt();"
                )
                guard Self.boolean(from: attempted) else { return false }
                hasAttemptedSubmission = true
                log("send_attempted", ["attempt": 1])
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            let verified = try await webView.evaluateJavaScript(
                "window.__starManagerDidSubmit && window.__starManagerDidSubmit();"
            )
            let didSubmit = Self.boolean(from: verified)
            if didSubmit {
                log("send_observed")
                // 자동 입력 뒤 웹 입력창이 첫 응답자로 남으면 전체 화면 위에 iOS의
                // 이전/다음/완료 입력 보조 막대가 나타난다. 전송 확인 직후 포커스를 끊는다.
                _ = try? await webView.evaluateJavaScript(
                    "document.activeElement && document.activeElement.blur(); window.getSelection && window.getSelection().removeAllRanges(); true;"
                )
                webView.endEditing(true)
                webView.resignFirstResponder()
            }
            return didSubmit
        } catch {
            log("bridge_failed")
            return false
        }
    }

    private static func boolean(from value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return (value as? Bool) ?? false
    }

    fileprivate func resetForNewNavigation() {
        // ChatGPT can create the conversation URL before it has finished reading the selected
        // files. The coordinator releases these files only when this task's WebView ends.
        nativeUploadPanelHandled = false
        isPageReady = false
        isGenerating = false
        isAnswerStable = false
        latestAnswer = ""
        detectedError = nil
    }

    fileprivate func markNavigationFinished() {
        log("browser_loaded")
        isPageReady = true
        navigationGeneration += 1
    }

    fileprivate func receive(text: String, stable: Bool, generating: Bool, interaction: String = "none", error: String = "") {
        if generating && !isGenerating { log("generation_started") }
        if stable && !text.isEmpty && !isAnswerStable { log("generation_completed", ["response_length": text.count]) }
        if !error.isEmpty && detectedError == nil { log("generation_failed") }
        isGenerating = generating
        if !text.isEmpty { latestAnswer = text }
        isAnswerStable = stable && !text.isEmpty
        if !error.isEmpty && detectedError == nil {
            detectedError = error
        }
        if interactionReason == nil {
            if interaction == "login" {
                interactionReason = .login
            } else if interaction == "captcha" {
                interactionReason = .captcha
            }
        }
    }

    static func sanitizeErrorMessage(_ raw: String, provider: ExternalAIProvider) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let filteredLines = text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let lower = trimmed.lowercased()
            if lower.hasPrefix("at ") || lower.contains("traceback") || lower.contains("stack trace") || lower.contains("eval(") || lower.contains("function()") {
                return false
            }
            return true
        }
        text = filteredLines.joined(separator: " ")
        let secretPatterns = [
            #"(?i)(?:bearer|token|key|secret|password|auth)[\s:=]+[A-Za-z0-9_\-\.]{8,}"#,
            #"https?://\S+"#
        ]
        for pattern in secretPatterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count > 80 {
            text = String(text.prefix(79)) + "…"
        }

        if text.isEmpty {
            return "\(provider.title) 서비스에서 오류가 발생했어요."
        }
        return "\(provider.title) 오류: \(text)"
    }
}

private struct ExternalAIWebView: UIViewRepresentable {
    let provider: ExternalAIProvider
    @ObservedObject var bridge: ExternalAIBrowserBridge

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 앱 안에서만 쓰는 영구 저장소. 이 저장소를 로그인 전용 브라우저와 공유해 로그인 상태를
        // 유지하지만, 사파리의 쿠키 저장소와는 별개이며 제공사가 세션을 만료시키면 다시 로그인해야 한다.
        configuration.websiteDataStore = .default()

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "starManagerBridge")
        bridge.diagnosticRunID = AIBIDiagnosticsStore.shared.currentRunID
            ?? AIBIDiagnosticsStore.shared.start(provider: provider.rawValue)
        controller.addUserScript(WKUserScript(source: ExternalAIBrowserScripts.uploadDiagnostics, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: ExternalAIBrowserScripts.observerScript(for: provider),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        bridge.webView = webView
        webView.load(URLRequest(url: provider.chatURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "starManagerBridge")
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        coordinator.releasePendingAttachmentFiles()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let bridge: ExternalAIBrowserBridge

        init(bridge: ExternalAIBrowserBridge) {
            self.bridge = bridge
        }

        func releasePendingAttachmentFiles() {
            bridge.clearPendingAttachmentFiles()
        }

        @available(iOS 18.4, *)
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
        ) {
            let fileURLs = bridge.pendingAttachmentURLs
            guard !fileURLs.isEmpty,
                  fileURLs.count == 1 || parameters.allowsMultipleSelection else {
                completionHandler(nil)
                return
            }
            bridge.nativeUploadPanelHandled = true
            bridge.log("attachment_dispatched", ["attached_count": fileURLs.count])
            completionHandler(fileURLs)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            bridge.resetForNewNavigation()
            if let url = webView.url?.absoluteString {
                bridge.checkURLForInteraction(url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url?.absoluteString {
                bridge.checkURLForInteraction(url)
            }
            bridge.markNavigationFinished()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url?.absoluteString {
                bridge.checkURLForInteraction(url)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled {
                bridge.detectedError = error.localizedDescription
            }
            bridge.markNavigationFinished()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled {
                bridge.detectedError = error.localizedDescription
            }
            bridge.markNavigationFinished()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "starManagerBridge", let body = message.body as? [String: Any] else { return }
            if let event = body["diagnosticEvent"] as? String {
                let metrics = (body["metrics"] as? [String: Int]) ?? [:]
                bridge.log(event, metrics)
                return
            }
            let text = (body["text"] as? String) ?? ""
            let stable = (body["stable"] as? Bool) ?? false
            let generating = (body["generating"] as? Bool) ?? false
            let interaction = (body["interaction"] as? String) ?? "none"
            let error = (body["error"] as? String) ?? ""
            bridge.receive(text: text, stable: stable, generating: generating, interaction: interaction, error: error)
        }
    }
}

private extension ExternalAIProvider {
    var chatURL: URL {
        switch self {
        case .openAI: URL(string: "https://chatgpt.com/")!
        case .gemini: URL(string: "https://gemini.google.com/app")!
        case .grok: URL(string: "https://grok.com/")!
        case .claude: URL(string: "https://claude.ai/new")!
        }
    }
}

/// 제공사별 DOM 구조가 바뀌어도 최대한 버티도록 여러 선택자를 순서대로 시도하는 주입/감시 스크립트.
private enum ExternalAIBrowserScripts {
    static let uploadDiagnostics = """
    (() => {
      if (location.hostname !== 'chatgpt.com') return;
      const emit = (event, metrics) => {
        try { window.webkit.messageHandlers.starManagerBridge.postMessage({diagnosticEvent:event, metrics:metrics}); } catch (_) {}
      };
      const category = value => {
        try {
          const u = new URL(typeof value === 'string' || value instanceof URL ? value : value.url, location.href);
          if (/conversation/.test(u.pathname)) return 2;
          if (/upload|files|estuary/.test(u.pathname) || /oaiusercontent|blob.core/.test(u.hostname)) return 1;
        } catch (_) {}
        return 0;
      };
      const original = window.fetch;
      let requestSequence = 0;
      window.fetch = async function(resource, options) {
        const kind = category(resource);
        const requestID = kind ? Math.min(1000, ++requestSequence) : 0;
        if (kind) {
          let imageCount = 0;
          let hasMessages = 0;
          if (typeof options?.body === 'string') {
            try {
              const body = JSON.parse(options.body);
              hasMessages = Array.isArray(body.messages) ? 1 : 0;
              const walk = (x, depth) => {
                if (!x || typeof x !== 'object' || depth > 12) return;
                if (x.content_type === 'image_asset_pointer') imageCount++;
                for (const value of Object.values(x)) if (value && typeof value === 'object') walk(value, depth + 1);
              };
              walk(body, 0);
            } catch (_) {}
          }
          emit('request_started', {request_id:requestID,request_kind:kind,request_has_messages:hasMessages,image_count:Math.min(100,imageCount)});
        }
        try {
          const response = await original.apply(this, arguments);
          if (kind) emit('request_response', {request_id:requestID,request_kind:kind,http_status:response.status});
          return response;
        } catch(error) {
          if (kind) emit('request_failed', {request_id:requestID,request_kind:kind,failure_kind:error?.name === 'AbortError' ? 1 : error?.name === 'TypeError' ? 2 : 3});
          throw error;
        }
      };
    })();
    """
    static func jsStringLiteral(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    static func resetComposerScript(for provider: ExternalAIProvider) -> String {
        let config = selectors(for: provider)
        return """
        (function() {
          const inputSelectors = \(jsArray(config.input));
          const attachmentSelectors = \(jsArray(config.attachmentConfirmed));

          function first(selectors) {
            for (const selector of selectors) {
              try {
                const element = document.querySelector(selector);
                if (element) return element;
              } catch (e) {}
            }
            return null;
          }

          const input = first(inputSelectors);
          if (input) {
            input.focus();
            if (input.tagName === 'TEXTAREA' || input.tagName === 'INPUT') {
              const proto = input.tagName === 'TEXTAREA'
                ? window.HTMLTextAreaElement.prototype
                : window.HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
              if (setter) setter.call(input, ''); else input.value = '';
            } else if (input.isContentEditable) {
              input.replaceChildren(document.createElement('p'));
            }
            input.dispatchEvent(new InputEvent('input', {
              bubbles: true,
              composed: true,
              inputType: 'deleteContentBackward',
              data: null
            }));
            input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
            input.blur();
          }

          const tiles = [];
          for (const selector of attachmentSelectors) {
            try {
              for (const tile of document.querySelectorAll(selector)) {
                if (!tiles.includes(tile)) tiles.push(tile);
              }
            } catch (e) {}
          }
          for (const tile of tiles) {
            const buttons = Array.from(tile.querySelectorAll('button, [role="button"]'));
            const remove = buttons.find(function(button) {
              const label = [
                button.getAttribute('aria-label'),
                button.getAttribute('title'),
                button.textContent
              ].filter(Boolean).join(' ').toLocaleLowerCase();
              return /remove|delete|close|dismiss|삭제|제거|닫기/.test(label);
            }) || buttons[buttons.length - 1];
            if (remove) remove.click();
          }
          return true;
        })();
        """
    }

    static func openPhotoPanelScript(for provider: ExternalAIProvider) -> String {
        let config = selectors(for: provider)
        return """
        (function() {
          const selectors = \(jsArray(config.fileInput));
          const candidates = [];
          for (const selector of selectors) {
            try {
              for (const input of document.querySelectorAll(selector)) {
                if (!candidates.includes(input) && !input.disabled) candidates.push(input);
              }
            } catch (e) {}
          }
          const input = candidates.find(function(item) { return !!item.closest('form'); })
            || candidates[candidates.length - 1];
          if (!input) return false;
          input.click();
          return true;
        })();
        """
    }

    /// Gemini mobile처럼 `업로드 및 도구 → 파일 → 파일 입력`의 중첩 메뉴를 쓰는
    /// 제공자도 한 단계씩 전진시킨다. 실제 파일 URL은 WKUIDelegate가 전달한다.
    static func advancePhotoPanelScript(for provider: ExternalAIProvider) -> String {
        let config = selectors(for: provider)
        let menuSelectors: [String]
        let menuTexts: [String]
        switch provider {
        case .openAI:
            // ChatGPT의 현재 모바일 웹 작성기는 + 버튼을 누른 뒤
            // `Add photos & files` 메뉴를 한 번 더 선택해야 파일 입력창을 연다.
            // 이전에는 Gemini만 이 중첩 메뉴를 처리해서 ChatGPT에서는 + 메뉴만
            // 열리고 사진 선택 패널까지 도달하지 못했다.
            menuSelectors = [
                "button[data-testid='upload-file-button']",
                "[data-testid='upload-file-button']",
                "button[data-testid*='upload-file']",
                "[role='menuitem'][data-testid*='upload-file']",
                "button[aria-label*='Add photos & files' i]",
                "[role='menuitem'][aria-label*='Add photos & files' i]",
                "button[aria-label*='사진 및 파일' i]",
                "[role='menuitem'][aria-label*='사진 및 파일' i]"
            ]
            menuTexts = [
                "Add photos & files",
                "Upload files",
                "Upload from device",
                "사진 및 파일 추가",
                "사진과 파일 추가",
                // 현재 한국어 ChatGPT iPhone 작성기 메뉴의 실제 항목은 단순히
                // `사진`이다. 이 항목을 놓치면 + 메뉴만 열린 채 업로드 패널로
                // 진행하지 못한다.
                "사진",
                "사진 추가",
                "Photos",
                "파일 업로드"
            ]
        case .gemini:
            menuSelectors = [
                "button[aria-label='파일']",
                "[role='menuitem'][aria-label='파일']",
                "button[aria-label='Files']",
                "[role='menuitem'][aria-label='Files']",
                "button[data-test-id*='upload-file']",
                "[data-test-id*='upload-file'][role='menuitem']"
            ]
            menuTexts = ["파일", "Files", "Upload files", "Upload from device"]
        default:
            menuSelectors = []
            menuTexts = []
        }
        return """
        (function() {
          const fileSelectors = \(jsArray(config.fileInput));
          const triggerSelectors = \(jsArray(config.attachTrigger));
          const menuSelectors = \(jsArray(menuSelectors));
          const requiresAttachmentMenu = \(provider == .openAI ? "true" : "false");
          const menuTexts = new Set(\(jsArray(menuTexts)).map(function(value) {
            return value.trim().toLocaleLowerCase();
          }));

          function visible(element) {
            if (!element) return false;
            const style = window.getComputedStyle(element);
            return style.display !== 'none' && style.visibility !== 'hidden' &&
              style.opacity !== '0' && element.getClientRects().length > 0;
          }
          function first(selectors, requireVisible) {
            for (const selector of selectors) {
              try {
                for (const element of document.querySelectorAll(selector)) {
                  if (!element.disabled && (!requireVisible || visible(element))) return element;
                }
              } catch (e) {}
            }
            return null;
          }

          function menuAction() {
            let action = first(menuSelectors, true);
            if (action || menuTexts.size === 0) return action;
            const candidates = document.querySelectorAll(
              "button, [role='menuitem'], [role='option'], [mat-menu-item], [data-test-id]"
            );
            return Array.from(candidates).find(function(element) {
              if (!visible(element)) return false;
              const values = [
                element.getAttribute('aria-label'),
                element.getAttribute('title'),
                element.innerText,
                element.textContent
              ];
              return values.some(function(value) {
                if (!value) return false;
                const normalized = value.trim().toLocaleLowerCase();
                return Array.from(menuTexts).some(function(menuText) {
                  return normalized === menuText || normalized.includes(menuText);
                });
              });
            }) || null;
          }

          // ChatGPT는 숨겨진 file input을 먼저 누르면 iOS WKWebView가 선택 패널을
          // 열지 않는 경우가 있다. 공식 흐름 그대로 + → Add photos & files를 먼저
          // 진행한 뒤, 그 메뉴가 만든 file input을 누른다.
          if (requiresAttachmentMenu) {
            const action = menuAction();
            if (action) { action.click(); return 'menu-action'; }
            const trigger = first(triggerSelectors, true);
            if (trigger) { trigger.click(); return 'trigger'; }
          }

          const input = first(fileSelectors, false);
          if (input) { input.click(); return 'input'; }

          const action = menuAction();
          if (action) { action.click(); return 'menu-action'; }

          const trigger = first(triggerSelectors, true);
          if (trigger) { trigger.click(); return 'trigger'; }
          return 'missing';
        })();
        """
    }

    static func observerScript(for provider: ExternalAIProvider) -> String {
        let config = selectors(for: provider)
        return """
        (function() {
          if (window.__starManagerInstalled) { return; }
          window.__starManagerInstalled = true;

          const inputSelectors = \(jsArray(config.input));
          const assistantSelectors = \(jsArray(config.assistant));
          const generatingSelectors = \(jsArray(config.generating));
          const sendSelectors = \(jsArray(config.send));
          const fileInputSelectors = \(jsArray(config.fileInput));
          const attachTriggerSelectors = \(jsArray(config.attachTrigger));
          const attachmentConfirmedSelectors = \(jsArray(config.attachmentConfirmed));

          function queryFirst(selectors) {
            for (const sel of selectors) {
              try {
                const el = document.querySelector(sel);
                if (el) return el;
              } catch (e) {}
            }
            return null;
          }

          function queryFileInput() {
            const candidates = [];
            for (const selector of fileInputSelectors) {
              try {
                for (const input of document.querySelectorAll(selector)) {
                  if (!candidates.includes(input) && !input.disabled) candidates.push(input);
                }
              } catch (e) {}
            }
            return candidates.find(function(item) { return !!item.closest('form'); })
              || candidates[candidates.length - 1]
              || null;
          }

          function queryAll(selectors) {
            for (const sel of selectors) {
              try {
                const list = document.querySelectorAll(sel);
                if (list && list.length > 0) return Array.from(list);
              } catch (e) {}
            }
            return [];
          }

          function isVisible(element) {
            if (!element) return false;
            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            return element.getClientRects().length > 0;
          }

          function isGeneratingNow() {
            return generatingSelectors.some(function(selector) {
              try { return Array.from(document.querySelectorAll(selector)).some(isVisible); } catch (_) { return false; }
            });
          }

          function composerScope() {
            const input = queryFirst(inputSelectors);
            return input && (input.closest('form') || input.parentElement?.parentElement?.parentElement);
          }

          function sendButton() {
            const scope = composerScope();
            if (!scope) return null;
            for (const selector of sendSelectors) {
              for (const button of scope.querySelectorAll(selector)) {
                const meaning = ((button.getAttribute('aria-label') || '') + ' ' + (button.getAttribute('data-testid') || '')).toLowerCase();
                if (/stop|중지|정지|voice|음성/.test(meaning)) continue;
                if (isVisible(button)) return button;
              }
            }
            return null;
          }

          function extractAnswerText(element) {
            // ChatGPT 등의 코드 블록 상단에는 `글`, `text` 같은 UI 머리말과 복사 버튼이 있다.
            // 전체 innerText 대신 실제 code 요소만 읽어 그 머리말이 게시물에 섞이지 않게 한다.
            const codeBlocks = Array.from(element.querySelectorAll('pre code'))
              .map(function(code) { return (code.innerText || code.textContent || '').trim(); })
              .filter(Boolean);
            if (codeBlocks.length > 0) return codeBlocks.join('\\n\\n');
            return (element.innerText || element.textContent || '').trim();
          }

          function attachmentCount() {
            const scope = composerScope();
            if (!scope) return 0;
            for (const selector of attachmentConfirmedSelectors) {
              const matches = Array.from(scope.querySelectorAll(selector)).filter(isVisible);
              if (matches.length) return matches.length;
            }
            return 0;
          }

          function fileFromDataURL(dataURL, mime, filename) {
            var comma = dataURL.indexOf(',');
            if (comma < 0) throw new Error('INVALID_DATA_URL');
            var header = dataURL.slice(0, comma);
            var payload = dataURL.slice(comma + 1);
            var binary = /;base64/i.test(header) ? atob(payload) : decodeURIComponent(payload);
            var bytes = new Uint8Array(binary.length);
            for (var b = 0; b < binary.length; b++) bytes[b] = binary.charCodeAt(b);
            return new File([bytes], filename, { type: mime });
          }

          // 각 사진은 브리지 용량을 제한하기 위해 한 장씩 스테이징하지만, 제공사 입력에는
          // 선택 순서가 보존된 단일 DataTransfer 배치로 한 번만 연결한다.
          window.__starManagerBeginAttachmentBatch = function(expectedCount) {
            if (!Number.isInteger(expectedCount) || expectedCount < 1 || expectedCount > 8) return false;
            window.__starManagerAttachmentBatch = { expectedCount: expectedCount, files: [] };
            return true;
          };

          window.__starManagerStageAttachment = function(dataURL, mime, index) {
            try {
              var batch = window.__starManagerAttachmentBatch;
              if (!batch || index !== batch.files.length || index >= batch.expectedCount) return false;
              var filename = 'aibi-' + String(index + 1).padStart(2, '0') + '.jpg';
              batch.files.push(fileFromDataURL(dataURL, mime, filename));
              return true;
            } catch (e) {
              window.__starManagerAttachmentBatch = null;
              return false;
            }
          };

          window.__starManagerCommitAttachmentBatch = function() {
            try {
              var batch = window.__starManagerAttachmentBatch;
              if (!batch || batch.files.length !== batch.expectedCount) return false;
              var input = queryFileInput();
              if (!input) {
                var trigger = queryFirst(attachTriggerSelectors);
                if (trigger) { trigger.focus(); trigger.click(); }
                input = queryFileInput();
              }
              if (!input || (batch.files.length > 1 && !input.multiple)) return false;
              var dt = new DataTransfer();
              batch.files.forEach(function(file) { dt.items.add(file); });
              input.files = dt.files;
              input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
              input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
              window.__starManagerAttachmentBatch = null;
              return true;
            } catch (e) {
              window.__starManagerAttachmentBatch = null;
              return false;
            }
          };

          window.__starManagerClearAttachmentBatch = function() {
            window.__starManagerAttachmentBatch = null;
            return true;
          };

          window.__starManagerAttachmentCount = attachmentCount;

          // force가 false일 때는 사용자가 우리가 넣은 것과 다른 내용을 이미 입력해 두었다면
          // 덮어쓰지 않는다(자동 채우기가 사용자 편집을 방해하지 않도록).
          window.__starManagerFillPrompt = function(text, force) {
            if (window.__starManagerSubmitDispatched) return false;
            const el = queryFirst(inputSelectors);
            if (!el) return false;
            const isTextField = el.tagName === 'TEXTAREA' || el.tagName === 'INPUT';
            const current = (isTextField ? el.value : (el.innerText || el.textContent || '')).trim();
            // 이전 시도에서 같은 문구가 입력창에 남아 있는 경우에도 준비 완료로 인정한다.
            // 이 경로가 없으면 재실행 시 사용자 입력으로 오인해 전송 단계로 넘어가지 못한다.
            if (current === text.trim()) {
              window.__starManagerLastFilled = text;
              return true;
            }
            if (!force && current.length > 0 && current !== window.__starManagerLastFilled) {
              return false;
            }
            el.focus();
            if (isTextField) {
              const proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
              setter.call(el, text);
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            } else if (el.isContentEditable) {
              const selection = window.getSelection();
              const range = document.createRange();
              range.selectNodeContents(el);
              selection.removeAllRanges();
              selection.addRange(range);
              const inserted = document.execCommand('insertText', false, text);
              if (!inserted) {
                el.replaceChildren(document.createTextNode(text));
                el.dispatchEvent(new InputEvent('input', {
                  bubbles: true,
                  inputType: 'insertText',
                  data: text
                }));
              }
              el.dispatchEvent(new Event('change', { bubbles: true }));
            } else {
              return false;
            }
            window.__starManagerLastFilled = text;
            return true;
          };

          window.__starManagerSendPrompt = function() {
            // The same DOM button may become Stop after the first click. Never click it
            // again while waiting for proof, and never turn a consumed image request into text-only.
            if (window.__starManagerSubmitDispatched) return true;
            if (isGeneratingNow()) return false;
            const input = queryFirst(inputSelectors);
            const button = sendButton();
            if (!input || !button || button.disabled || button.getAttribute('aria-disabled') === 'true') return false;
            const normalize = value => value.replace(/\\s+/g, ' ').trim();
            const current = normalize(input.value || input.innerText || input.textContent || '');
            if (!current || current !== normalize(window.__starManagerLastFilled || '')) return false;
            const rect = button.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return false;

            window.__starManagerSubmitAttempts = (window.__starManagerSubmitAttempts || 0) + 1;
            const attempt = window.__starManagerSubmitAttempts;
            if (!window.__starManagerBaselineCapturedForSubmit) {
              window.__starManagerCaptureBaseline();
              window.__starManagerBaselineCapturedForSubmit = true;
            }
            window.__starManagerSubmitDispatched = true;
            input.focus();
            button.focus();
            button.click();
            return true;
          };

          window.__starManagerDidSubmit = function() {
            // A consumed composer is only pending, not evidence that the service began
            // answering. The caller observes this state without another click or refill.
            const answerStarted = queryAll(assistantSelectors).length > baselineCount;
            const generating = isGeneratingNow();
            return answerStarted || generating;
          };

          function detectInteraction() {
            try {
              const url = (window.location.href || '').toLowerCase();
              if (url.includes('accounts.google.com') || url.includes('auth.openai.com') || url.includes('claude.ai/login') || url.includes('/login') || url.includes('/signin') || url.includes('/signup') || url.includes('auth0')) {
                return 'login';
              }
              if (url.includes('challenge') || url.includes('checkpoint') || url.includes('cloudflare') || document.querySelector('#challenge-form, .cf-turnstile, iframe[src*="turnstile"], iframe[src*="recaptcha"]')) {
                return 'captcha';
              }
            } catch (e) {}
            return 'none';
          }

          function detectError() {
            try {
              const errorEls = queryAll([
                "[role='alert']",
                "[data-testid*='error']",
                "[data-testid*='toast-error']",
                "div[class*='error-message']",
                "div[class*='errorMessage']",
                "div[class*='alert-danger']",
                ".snack-bar",
                "simple-snack-bar",
                "div.model-response-error"
              ]);
              for (const el of errorEls) {
                if (!isVisible(el)) continue;
                const t = (el.innerText || el.textContent || '').trim();
                if (!t || t.length < 2) continue;
                const lower = t.toLowerCase();
                if (lower.includes('error') || lower.includes('failed') || lower.includes('unavailable') ||
                    lower.includes('rate limit') || lower.includes('too many') || lower.includes('limit reached') ||
                    lower.includes('try again') || lower.includes('오류') || lower.includes('실패') ||
                    lower.includes('한도') || lower.includes('잠시 후') || lower.includes('문제') ||
                    el.getAttribute('role') === 'alert') {
                  return t.slice(0, 150);
                }
              }
            } catch (e) {}
            return '';
          }

          // 감시 시작 시점의 답변 개수를 기준으로 삼아, 이전 대화 답변이나 사용자가 입력한 프롬프트를
          // 새 답변으로 잘못 가져오지 않도록 한다.
          const baselineItems = queryAll(assistantSelectors);
          let baselineCount = baselineItems.length;
          const baselineLatest = baselineItems.length > 0 ? baselineItems[baselineItems.length - 1] : null;
          let baselineText = baselineLatest ? extractAnswerText(baselineLatest) : '';
          let baselineKey = baselineLatest
            ? (baselineLatest.getAttribute('data-message-id') || baselineLatest.getAttribute('data-testid') || baselineLatest.id || '')
            : '';
          window.__starManagerCaptureBaseline = function() {
            const items = queryAll(assistantSelectors);
            baselineCount = items.length;
            const latest = items.length > 0 ? items[items.length - 1] : null;
            baselineText = latest ? extractAnswerText(latest) : '';
            baselineKey = latest
              ? (latest.getAttribute('data-message-id') || latest.getAttribute('data-testid') || latest.id || '')
              : '';
            lastText = '';
            stableTicks = 0;
          };
          let lastText = '';
          let stableTicks = 0;

          setInterval(function() {
            const editor = queryFirst(inputSelectors);
            const scope = composerScope();
            const send = sendButton();
            window.webkit.messageHandlers.starManagerBridge.postMessage({diagnosticEvent:'bridge_snapshot', metrics: {
              preview_count: attachmentCount(), input_count: document.querySelectorAll('input[type=file]').length,
              uploading_count: scope ? Array.from(scope.querySelectorAll('[role=progressbar], [aria-busy=true], .animate-spin')).filter(isVisible).length : 0,
              composer_present: editor ? 1 : 0, send_present: send ? 1 : 0,
              send_enabled: send && !send.disabled && send.getAttribute('aria-disabled') !== 'true' ? 1 : 0,
              prompt_length: editor ? (editor.value || editor.textContent || '').length : 0,
              user_message_present: document.querySelector('[data-message-author-role=user]') ? 1 : 0,
              assistant_message_present: queryAll(assistantSelectors).length ? 1 : 0,
              generation_active: isGeneratingNow() ? 1 : 0,
              stop_present: isGeneratingNow() ? 1 : 0
            }});
            const items = queryAll(assistantSelectors);
            // Gemini는 답변 완료 뒤에도 숨겨진 mat-progress-spinner를 DOM에 남겨 둔다.
            // 실제로 보이는 생성 표시만 검사해야 완료된 응답을 정상적으로 가져올 수 있다.
            const generating = isGeneratingNow();
            const interaction = detectInteraction();
            const errorText = detectError();

            if (errorText) {
              window.webkit.messageHandlers.starManagerBridge.postMessage({
                text: '',
                stable: false,
                generating: false,
                interaction: 'none',
                error: errorText
              });
              return;
            }

            if (items.length === 0) {
              window.webkit.messageHandlers.starManagerBridge.postMessage({
                text: '',
                stable: false,
                generating: generating,
                interaction: interaction,
                error: ''
              });
              return;
            }
            const latest = items[items.length - 1];
            const text = extractAnswerText(latest);
            const latestKey = latest.getAttribute('data-message-id') || latest.getAttribute('data-testid') || latest.id || '';
            const hasNewAnswer = items.length > baselineCount ||
              (text.length > 0 && (text !== baselineText || (latestKey.length > 0 && latestKey !== baselineKey)));
            if (!hasNewAnswer) {
              window.webkit.messageHandlers.starManagerBridge.postMessage({
                text: '',
                stable: false,
                generating: generating,
                interaction: interaction,
                error: ''
              });
              return;
            }
            if (text.length > 0 && text === lastText && !generating) {
              stableTicks += 1;
            } else {
              stableTicks = 0;
            }
            lastText = text;
            // 스트리밍 중 잠깐 멈춘 순간을 완성으로 착각하지 않도록, 변화 없는 상태가
            // 약 1.4초(0.7초 주기 x 2회) 이어지고 생성이 끝났을 때 안정된 답변으로 판단한다.
            const stable = stableTicks >= 2 && text.length > 0 && !generating;
            window.webkit.messageHandlers.starManagerBridge.postMessage({
              text: text,
              stable: stable,
              generating: generating,
              interaction: interaction,
              error: ''
            });
          }, 700);
        })();
        """
    }

    private static func jsArray(_ values: [String]) -> String {
        let items = values.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ", ")
        return "[\(items)]"
    }

    private struct Selectors {
        let input: [String]
        let assistant: [String]
        let generating: [String]
        let send: [String]
        let authenticated: [String]
        let login: [String]
        let challenge: [String]
        let fileInput: [String]
        let attachTrigger: [String]
        let attachmentConfirmed: [String]
    }

    static func authStatusProbeScript(for provider: ExternalAIProvider) -> String {
        let config = selectors(for: provider)
        return """
        (function() {
          try {
            const authMarkerSelectors = \(jsArray(config.authenticated));
            const loginSelectors = \(jsArray(config.login));
            const challengeSelectors = \(jsArray(config.challenge));

            function isVisible(el) {
              if (!el) return false;
              const style = window.getComputedStyle(el);
              if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
              return el.offsetWidth > 0 || el.offsetHeight > 0 || el.getClientRects().length > 0;
            }

            function queryFirstVisible(selectors) {
              for (const sel of selectors) {
                try {
                  const els = document.querySelectorAll(sel);
                  for (const el of els) {
                    if (isVisible(el)) return el;
                  }
                } catch (e) {}
              }
              return null;
            }

            // 1. 보안 챌린지 검사
            const challengeEl = queryFirstVisible(challengeSelectors);
            if (challengeEl) {
              return JSON.stringify({ authenticated: false, hasLogin: false, hasChallenge: true });
            }

            // 2. 긍정적 인증 증거 검사. 채우기용 입력창 선택자(config.input)는 로그아웃
            // 상태의 공개 랜딩 페이지에도 등장하는 범용 contenteditable 폴백을 포함하므로
            // 인증 판정에는 쓰지 않는다. 제공사별로 실제 로그인 후에만 나타나는
            // 계정 메뉴·전용 에디터 클래스 등 신뢰 가능한 마커만 근거로 삼는다.
            const authMarkerEl = queryFirstVisible(authMarkerSelectors);
            if (authMarkerEl) {
              return JSON.stringify({ authenticated: true, hasLogin: false, hasChallenge: false });
            }

            // 3. 로그인 화면/버튼 검사 (제공사별 선택자 + 일반 로그인 링크/버튼)
            const loginEl = queryFirstVisible(loginSelectors);
            if (loginEl) {
              return JSON.stringify({ authenticated: false, hasLogin: true, hasChallenge: false });
            }

            const controls = Array.from(document.querySelectorAll('a, button'));
            for (const el of controls) {
              if (!isVisible(el)) continue;
              const href = String(el.getAttribute('href') || '').toLowerCase();
              if (href.includes('/login') || href.includes('/signin') || href.includes('accounts.google.com') || href.includes('auth.openai.com')) {
                return JSON.stringify({ authenticated: false, hasLogin: true, hasChallenge: false });
              }
              const text = String(el.innerText || el.getAttribute('aria-label') || '').trim().toLowerCase();
              if (text === '로그인' || text === '로그인하기' || text === 'log in' || text === 'login' || text === 'sign in') {
                return JSON.stringify({ authenticated: false, hasLogin: true, hasChallenge: false });
              }
            }

            // 4. 아직 렌더링/하이드레이션 대기 중
            return JSON.stringify({ authenticated: false, hasLogin: false, hasChallenge: false });
          } catch (e) {
            return JSON.stringify({ authenticated: false, hasLogin: false, hasChallenge: false, error: e.message || String(e) });
          }
        })();
        """
    }

    private static func selectors(for provider: ExternalAIProvider) -> Selectors {
        switch provider {
        case .openAI:
            Selectors(
                input: [
                    "#prompt-textarea",
                    "textarea[data-id='root']",
                    "div[contenteditable='true']#prompt-textarea",
                    "div#prompt-textarea",
                    "form div[contenteditable='true']",
                    "div[role='textbox']",
                    "textarea[data-testid]"
                ],
                assistant: [
                    "[data-message-author-role='assistant']",
                    "div.agent-turn",
                    "div[data-testid*='conversation-turn'] .markdown"
                ],
                generating: [
                    "button[data-testid='stop-button']",
                    "button[aria-label*='Stop']",
                    "button[aria-label*='중지']"
                ],
                send: [
                    "#composer-submit-button",
                    "button[data-testid='send-button']",
                    "form button[type='submit']",
                    "button[aria-label*='프롬프트 보내기']",
                    "button[aria-label*='Send']",
                    "button[aria-label*='보내기']",
                    "button:has(svg[data-icon='arrow-up'])"
                ],
                authenticated: [
                    "#prompt-textarea",
                    "div#prompt-textarea",
                    "button[data-testid='profile-button']",
                    "button[data-testid='user-menu-button']",
                    "button[data-testid='composer-speech-button']",
                    "nav a[href*='/c/']",
                    "nav[aria-label='Chat history']",
                    "a[href='/settings/general']"
                ],
                login: [
                    "button[data-testid='login-button']",
                    "a[href*='/auth/login']",
                    "a[href*='/login']",
                    "button[data-testid='signup-button']",
                    "a[href*='/signup']",
                    "button[data-testid='welcome-login-button']"
                ],
                challenge: [
                    "#cf-challenge-running",
                    "iframe[src*='challenges.cloudflare.com']",
                    "#challenge-form",
                    ".cf-turnstile",
                    "iframe[src*='turnstile']"
                ],
                fileInput: [
                    "input[type='file'][accept*='image']",
                    "input[type='file'][accept*='.jpg']",
                    "input[type='file'][accept*='.jpeg']",
                    "input[type='file'][accept*='.png']",
                    "input[type='file']"
                ],
                attachTrigger: [
                    "button[aria-label*='Attach']",
                    "button[aria-label*='첨부']",
                    "button[data-testid='composer-plus-btn']",
                    "button[aria-label*='Add photos']",
                    "button[aria-label*='사진']"
                ],
                attachmentConfirmed: [
                    "div[data-testid*='attachment']",
                    "img[alt='Uploaded image']",
                    "button[aria-label*='uploaded image' i]",
                    "button[aria-label*='업로드한 이미지']",
                    "img[src*='/backend-api/estuary/content']",
                    "div[class*='attachment-tile']"
                ]
            )
        case .gemini:
            Selectors(
                input: [
                    "div.ql-editor[contenteditable='true']",
                    "rich-textarea div[contenteditable='true']",
                    "rich-textarea p",
                    "div[aria-label*='프롬프트']",
                    "div[aria-label*='prompt']",
                    "div[contenteditable='true']",
                    "div[role='textbox']",
                    "textarea"
                ],
                assistant: [
                    "model-response .markdown",
                    "message-content .markdown",
                    "div.model-response-text",
                    "div[data-test-id='model-response']",
                    "message-content",
                    "model-response",
                    ".response-container-content"
                ],
                generating: [
                    "button[aria-label*='Stop']",
                    "button[aria-label*='중지']",
                    "button.stop-generating-button"
                ],
                send: [
                    "button.send-button",
                    "button[aria-label*='Send']",
                    "button[aria-label*='보내기']",
                    "button[mat-icon-button][aria-label*='send']",
                    "button[type='submit']"
                ],
                authenticated: [
                    "a[aria-label*='Google Account']",
                    "a[aria-label*='Google 계정']",
                    "button[aria-label*='Google Account']",
                    "button[aria-label*='Google 계정']",
                    "img.gbii",
                    "img[alt*='Google Account']",
                    "bard-mode-switcher",
                    "div.ql-editor",
                    "rich-textarea"
                ],
                login: [
                    "a[href*='accounts.google.com/ServiceLogin']",
                    "a[aria-label*='Sign in']",
                    "button[aria-label*='Sign in']",
                    "button[aria-label*='로그인']",
                    "a[aria-label*='로그인']",
                    "a[href*='/signin']",
                    "a[href*='accounts.google.com']",
                    "button[data-testid*='login']"
                ],
                challenge: [
                    "iframe[src*='recaptcha']",
                    "div.g-recaptcha",
                    "#challenge-stage"
                ],
                fileInput: [
                    "input[type='file'][accept*='image']",
                    "input[type='file'][accept*='.jpg']",
                    "input[type='file'][accept*='.jpeg']",
                    "input[type='file'][accept*='.png']",
                    "input[type='file']"
                ],
                attachTrigger: [
                    "button[aria-label*='Add files']",
                    "button[aria-label*='Upload']",
                    "button[aria-label*='업로드 및 도구']",
                    "gem-icon-button[arialabel*='업로드']",
                    "button[aria-label*='이미지']",
                    "button[aria-label*='사진']",
                    "button[aria-label*='파일 추가']"
                ],
                attachmentConfirmed: [
                    "button[aria-label='첨부파일 닫기']",
                    "button[aria-label='Remove attachment']",
                    "button[aria-label='Remove file']",
                    "div[data-test-id*='file-preview']",
                    "div.file-preview-container",
                    "div[class*='uploader-file']"
                ]
            )
        case .grok:
            Selectors(
                input: [
                    "textarea",
                    "div[contenteditable='true']",
                    "div[role='textbox']"
                ],
                assistant: [
                    "[data-testid='grok-response']",
                    "div.response-body",
                    "div.message-bubble",
                    "div[class*='message'][class*='assistant']"
                ],
                generating: [
                    "button[aria-label*='Stop']",
                    "button[data-testid='stop-button']"
                ],
                send: [
                    "button[aria-label*='Send']",
                    "button[aria-label*='보내기']",
                    "button[type='submit']"
                ],
                authenticated: [
                    "textarea",
                    "button[data-testid='user-menu-button']"
                ],
                login: [
                    "a[href*='/login']",
                    "button[data-testid*='login']",
                    "a[href*='/signin']"
                ],
                challenge: [
                    "iframe[src*='challenges']"
                ],
                fileInput: [
                    "input[type='file'][accept*='image']",
                    "input[type='file'][accept*='.jpg']",
                    "input[type='file'][accept*='.jpeg']",
                    "input[type='file'][accept*='.png']",
                    "input[type='file']"
                ],
                attachTrigger: [
                    "button[aria-label*='Attach']"
                ],
                attachmentConfirmed: [
                    "div[data-testid*='attachment']"
                ]
            )
        case .claude:
            Selectors(
                input: [
                    "div.ProseMirror[contenteditable='true']",
                    "div[contenteditable='true'][data-placeholder]",
                    "div[contenteditable='true'][role='textbox']",
                    "fieldset div[contenteditable='true']",
                    "div[contenteditable='true']"
                ],
                assistant: [
                    ".font-claude-response .standard-markdown",
                    "[data-testid='transcript-row'] [data-is-streaming] .standard-markdown",
                    "[data-is-streaming] .font-claude-response-body",
                    ".font-claude-response-body",
                    "div.font-claude-message",
                    "div[data-testid*='assistant']",
                    "div[data-testid='assistant-message']",
                    ".standard-grid .font-user-message + div"
                ],
                generating: [
                    "button[aria-label*='Stop']",
                    "button[aria-label*='중단']",
                    "button[aria-label*='중지']",
                    "button[aria-label*='Stop generating']",
                    "div[data-is-streaming='true']"
                ],
                send: [
                    "button[aria-label='Send Message']",
                    "button[aria-label*='Send']",
                    "button[aria-label*='전송']",
                    "button[aria-label*='보내기']",
                    "button:has(svg[data-icon='paper-plane'])",
                    "fieldset button[type='button']:not([disabled])",
                    "button[type='submit']"
                ],
                authenticated: [
                    "div.ProseMirror[contenteditable='true']",
                    "button[data-testid='user-menu-button']",
                    "button[data-testid='chat-input-send-button']",
                    "button[aria-label*='account menu']",
                    "a[href='/settings/profile']"
                ],
                login: [
                    "input[type='email'][name='email']",
                    "a[href*='/login']",
                    "button[data-testid*='login']",
                    "a[href*='/signup']",
                    "button[data-testid*='signup']"
                ],
                challenge: [
                    "iframe[src*='cloudflare']",
                    "div#challenge-stage",
                    "iframe[src*='turnstile']"
                ],
                fileInput: [
                    "input[type='file'][accept*='image']",
                    "input[type='file'][accept*='.jpg']",
                    "input[type='file'][accept*='.jpeg']",
                    "input[type='file'][accept*='.png']",
                    "input[type='file']"
                ],
                attachTrigger: [
                    "button[aria-label*='Attach']",
                    "button[aria-label*='파일']",
                    "button[aria-label*='업로드']"
                ],
                attachmentConfirmed: [
                    "div[data-testid='file-thumbnail']",
                    "div[data-testid*='attachment']"
                ]
            )
        }
    }
}
