import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit
#if canImport(ImagePlayground)
import ImagePlayground
#endif

struct ComposerView: View {
    private static let maxMediaItems = 8
    /// 줄넘김 선택지는 열거형 선언 순서와 무관하게 항상 최소 · 적당히 · 자주 순서로 보여준다.
    private static let lineBreakDisplayOrder: [LineBreakFrequency] = [.minimal, .moderate, .frequent]

    var resetRequest = UUID()

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.brandTheme) private var theme
    @EnvironmentObject private var profileStore: CreatorProfileStore
    @EnvironmentObject private var automationCoordinator: AutomationCoordinator
    @EnvironmentObject private var availabilityStore: AIProviderAvailabilityStore
    @EnvironmentObject private var runMetricsStore: AIRunMetricsStore
    @EnvironmentObject private var composerNavState: ComposerNavState

    @State private var idea = ""
    @FocusState private var isIdeaFocused: Bool
    @AppStorage(SharedGenerationSettings.moodKey) private var mood = PostMood.witty
    @AppStorage(SharedGenerationSettings.storyWeightKey) private var length = PostLength.medium
    @AppStorage(SharedGenerationSettings.showsExternalAIBrowserKey) private var showsExternalAIBrowser = false
    @State private var generatedPost: GeneratedPost?
    @State private var isGenerating = false
    @State private var generationID: UUID?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var previewAspect = PreviewAspect.feed
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var mediaItems: [ComposerMedia] = []
    @State private var mediaLoadTask: Task<Void, Never>?
    @State private var mediaLoadID = UUID()
    @State private var isLoadingMedia = false
    @State private var isGeneratingImage = false
    @State private var isPreparingShare = false
    @State private var sharePreparationID: UUID?
    @State private var sharePayload: SharePayload?
    @State private var shareMessage: String?
    @State private var shareMessageIsError = false
    @State private var hasPositionedInitialScroll = false
    @State private var generatedSignature: DraftSignature?
    @State private var activeCaptionSource: CaptionSource?
    @State private var captionCandidates: [CaptionSource: CaptionCandidate] = [:]
    @State private var showsImagePlayground = false
    @State private var imagePlaygroundPrompt = ""
    @State private var imageGenerationPostID: UUID?
    @State private var pendingExternalProvider: ExternalAIProvider?
    @State private var activeExternalProvider: ExternalAIProvider?
    @State private var externalSubmittedAt: Date?
    @State private var elapsedSeconds = 0
    @State private var browserContext: ExternalAIBrowserContext?
    @State private var draggedMediaID: UUID?
    @State private var isMediaDropTargeted = false
    @State private var showsCamera = false
    @State private var showsResetConfirmation = false
    @State private var resetScrollRequest = UUID()
    @State private var activePhotoAttachments: [AIBIMediaAttachment] = []
    /// 외부 AI를 누른 순간의 문구를 고정한다. 이후 클립보드나 편집 화면의 변화가
    /// 현재 요청에 섞이지 않도록, 브라우저에는 이 스냅샷만 전달한다.
    @State private var activeExternalPrompt = ""
    @State private var externalAttachmentPreparationTask: Task<Void, Never>?
    @State private var isPreparingExternalAttachments = false
    @State private var sparklesRotationAngle: Double = 0
    @State private var isWritingSettingsExpanded = false
    /// 접힘 상태 카드 높이를 원래 자연 높이의 정확히 2배로 만들기 위한 헤더 실측 높이.
    @State private var writingSettingsHeaderHeight: CGFloat?
    @State private var isAutomationPickerPresented = false
    @State private var reservesAIChoiceScrollClearance = false
    @State private var automationPickerItems: [PhotosPickerItem] = []
    /// 퀵 액션으로 들어와 AIBI 생성이 진행 중이거나 결과/실패를 기다리는 동안 true. 전용 자동화 화면(fullScreenCover)의 표시 여부를 결정한다.
    @State private var isAutomationSessionActive = false
    /// 카메라 퀵 액션에서 실제로 사진을 찍어 온 경우에만 이전 작업을 비우기 위한 예약 표시. 촬영 취소 시에는 아무것도 지우지 않는다.
    @State private var pendingCameraResetOnCapture = false
    @State private var automationSurfaceState: AutomationSurfaceState = .processing
    @State private var automationRelayState: AutomationRelayState = .preparing
    /// 자동화 전체 화면 진행 표시와 하단 캐릭터에 쓰는, 지금 요청 중인 AI.
    @State private var automationActiveChoice: AIProviderIdentity = .device
    @AppStorage("hasShownPastePermissionGuidance") private var hasShownPastePermissionGuidance = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("composer-top")
                Group {
                    creationColumn
                        .frame(maxWidth: horizontalSizeClass == .regular ? 720 : 680)
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 24 : 16)
                .padding(.vertical, horizontalSizeClass == .regular ? 20 : 12)
                .frame(maxWidth: .infinity)
            }
            .contentMargins(.bottom, 96, for: .scrollContent)
            .scrollDismissesKeyboard(.immediately)
            .onScrollPhaseChange { _, newPhase in
                guard newPhase == .interacting else { return }
                isIdeaFocused = false
            }
            .onAppear {
                guard !hasPositionedInitialScroll else { return }
                hasPositionedInitialScroll = true
                proxy.scrollTo("composer-top", anchor: .top)
            }
            .onChange(of: resetScrollRequest) {
                withAnimation { proxy.scrollTo("composer-top", anchor: .top) }
            }
            .composerAIChoiceScrollSync(
                trigger: composerNavState.aiChoiceRevealTrigger,
                proxy: proxy,
                onReveal: {
                    isIdeaFocused = false
                    reservesAIChoiceScrollClearance = true
                }
            )
            .composerProgressScrollSync(
                isGenerating: isGenerating,
                proxy: proxy,
                onReveal: { reservesAIChoiceScrollClearance = true }
            )
            .task(id: externalSubmittedAt) {
                guard let submittedAt = externalSubmittedAt else {
                    elapsedSeconds = 0
                    return
                }
                while !Task.isCancelled && isGenerating {
                    let elapsed = max(0, Int(Date().timeIntervalSince(submittedAt)))
                    elapsedSeconds = elapsed
                    if elapsed >= Self.externalGenerationTimeoutSeconds {
                        timeoutExternalGeneration()
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        .background(theme.canvasGradient)
        .background(KeyboardDismissTapInstaller())
        .background {
            if let provider = activeExternalProvider,
               browserContext == nil,
               !isPreparingExternalAttachments {
                ExternalAIHiddenAutomatorView(
                    provider: provider,
                    prompt: activeExternalPrompt,
                    attachments: activePhotoAttachments,
                    generationID: generationID,
                    onSubmitted: { date in
                        externalSubmittedAt = date
                        elapsedSeconds = 0
                        statusMessage = "정보를 보냈어요"
                        automationRelayState = .waiting
                        dismissKeyboardAfterAutomationSubmission()
                    },
                    onSuccess: { text in
                        importAIResult(text, from: provider)
                    },
                    onFallback: { reason in
                        recordAIDiagnostic("manual_takeover")
                        browserContext = ExternalAIBrowserContext(provider: provider, fallbackReason: reason)
                    },
                    onError: { err in
                        recordAIDiagnostic("run_failed")
                        errorMessage = err
                        activeExternalProvider = nil
                        externalSubmittedAt = nil
                        elapsedSeconds = 0
                        isGenerating = false
                        activePhotoAttachments = []
                        if isAutomationSessionActive {
                            automationSurfaceState = .failure(err)
                        }
                    }
                )
                .id(generationID)
                .frame(width: 375, height: 667)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    appIconThumbnail
                    Text("Stargram")
                        .font(.headline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Stargram")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("취소") {
                    if hasComposerContent {
                        showsResetConfirmation = true
                    } else {
                        resetComposer()
                    }
                }
                .accessibilityHint("작성 중인 이야기와 미디어를 비우고 처음 화면으로 돌아갑니다")
            }
        }
        .onChange(of: resetRequest) {
            if hasComposerContent {
                showsResetConfirmation = true
            } else {
                resetScrollRequest = UUID()
            }
        }
        .onChange(of: selectedItems) { _, items in
            guard !items.isEmpty else { return }
            mediaLoadTask?.cancel()
            let loadID = UUID()
            mediaLoadID = loadID
            mediaLoadTask = Task { await loadMedia(from: items, loadID: loadID) }
        }
        .onChange(of: automationCoordinator.trigger, initial: true) { _, requestID in
            guard let requestID else { return }
            Task { @MainActor in
                await Task.yield()
                guard automationCoordinator.trigger == requestID else { return }
                automationCoordinator.clear(requestID)
                dismissKeyboardForAutomation()
                await Task.yield()
                isAutomationPickerPresented = true
            }
        }
        .onChange(of: automationCoordinator.isAutomationEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            cancelPendingAutomationUI()
        }
        .onChange(of: automationCoordinator.cameraTrigger, initial: true) { _, requestID in
            guard let requestID else { return }
            Task { @MainActor in
                await Task.yield()
                guard automationCoordinator.cameraTrigger == requestID else { return }
                automationCoordinator.clearCameraTrigger(requestID)
                dismissKeyboardForAutomation()
                pendingCameraResetOnCapture = true
                await Task.yield()
                openCamera()
            }
        }
        .onChange(of: automationCoordinator.shareBatchTrigger, initial: true) { _, requestID in
            guard let requestID else { return }
            Task { @MainActor in
                await Task.yield()
                guard automationCoordinator.shareBatchTrigger == requestID else { return }
                automationCoordinator.clearShareBatchTrigger(requestID)
                dismissKeyboardForAutomation()
                await Task.yield()
                await importPendingShareBatch()
            }
        }
        .photosPicker(
            isPresented: $isAutomationPickerPresented,
            selection: $automationPickerItems,
            maxSelectionCount: Self.maxMediaItems,
            selectionBehavior: .ordered,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: automationPickerItems) { _, items in
            guard !items.isEmpty else { return }
            dismissKeyboardForAutomation()
            let pickedItems = items
            automationPickerItems = []
            resetComposer()
            let loadID = UUID()
            mediaLoadID = loadID
            mediaLoadTask = Task {
                await loadMedia(from: pickedItems, loadID: loadID)
                guard mediaLoadID == loadID, !isGenerating, hasRepresentativePhoto else { return }
                guard let choice = randomAutomationChoice() else {
                    errorMessage = Self.noRandomProviderMessage
                    return
                }
                automationActiveChoice = choice
                automationSurfaceState = .processing
                dismissKeyboardForAutomation()
                isAutomationSessionActive = true
                runAutomationGeneration(choice)
            }
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(items: payload.items, cleanupURLs: payload.cleanupURLs) { completed, error in
                if let error {
                    shareMessage = "보내지 못했어요: \(error.localizedDescription)"
                    shareMessageIsError = true
                } else if completed {
                    shareMessage = "보내기 완료 · 문구 붙여넣기"
                    shareMessageIsError = false
                } else {
                    shareMessage = "보내기 취소 · 문구는 복사됨"
                    shareMessageIsError = false
                }
            }
        }
        .fullScreenCover(item: $browserContext) { context in
            ExternalAIBrowserSheet(
                provider: context.provider,
                prompt: activeExternalPrompt,
                attachments: activePhotoAttachments,
                fallbackReason: context.fallbackReason,
                onSubmitted: { date in
                    externalSubmittedAt = date
                    elapsedSeconds = 0
                    statusMessage = "정보를 보냈어요"
                    automationRelayState = .waiting
                    dismissKeyboardAfterAutomationSubmission()
                },
                onError: { message in
                    recordAIDiagnostic("run_failed")
                    errorMessage = message
                    externalSubmittedAt = nil
                    elapsedSeconds = 0
                    isGenerating = false
                    activeExternalProvider = nil
                    activePhotoAttachments = []
                    if isAutomationSessionActive {
                        automationSurfaceState = .failure(message)
                    }
                },
                onImport: { text in
                    importAIResult(text, from: context.provider)
                    browserContext = nil
                },
                onManualCopyFallback: {
                    statusMessage = "문구 복사됨 · 직접 붙여넣고, 답변은 복사해서 붙여넣기로 가져오세요"
                    if !hasShownPastePermissionGuidance {
                        hasShownPastePermissionGuidance = true
                        statusMessage = "문구 복사됨 · 붙여넣기가 막히면 설정 > 앱 > Stargram > 다른 앱에서 붙여넣기 > 허용"
                    }
                },
                onDismiss: {
                    if isGenerating {
                        recordAIDiagnostic("run_cancelled")
                        isGenerating = false
                        activeExternalProvider = nil
                        activePhotoAttachments = []
                        if isAutomationSessionActive {
                            automationSurfaceState = .failure("연결이 중단됐어요. 다시 시도해 주세요.")
                        }
                    }
                    browserContext = nil
                }
            )
        }
        .fullScreenCover(isPresented: $isAutomationSessionActive) {
            AutomationSurfaceView(
                theme: theme,
                state: automationSurfaceState,
                relayMessage: automationRelayState.message,
                resultImages: mediaItems.filter { $0.kind == .image }.map(\.data),
                isPreparingShare: isPreparingShare,
                activeChoice: automationActiveChoice,
                onCancel: closeAutomationSurface,
                onRetry: retryAutomationGeneration,
                onShare: { Task { await share() } },
                onClose: closeAutomationSurface
            )
            .interactiveDismissDisabled()
            .onAppear {
                dismissKeyboardForAutomation()
            }
        }
        .onChange(of: isAutomationSessionActive) { _, isActive in
            guard isActive else { return }
            dismissKeyboardForAutomation()
            Task { @MainActor in
                await Task.yield()
                dismissKeyboardForAutomation()
            }
        }
        .onChange(of: automationSurfaceState) { _, _ in
            guard isAutomationSessionActive else { return }
            dismissKeyboardForAutomation()
        }
        .onChange(of: browserContext) { _, context in
            guard context == nil, isAutomationSessionActive else { return }
            dismissKeyboardAfterBrowserDismissal()
        }
        .fullScreenCover(isPresented: $showsCamera, onDismiss: { pendingCameraResetOnCapture = false }) {
            CameraCaptureView(
                maxCount: Self.maxMediaItems,
                currentCount: mediaItems.count,
                onFinish: { photos in addCameraPhotos(photos) },
                onPhotoLibrarySaveIssue: {
                    errorMessage = "촬영한 사진을 사진 보관함에 저장하지 못했어요. 설정에서 사진 추가 권한을 확인해 주세요."
                }
            )
            .ignoresSafeArea()
        }
        .alert(
            "새 이야기로 시작할까요?",
            isPresented: $showsResetConfirmation
        ) {
            Button("새로 시작", role: .destructive) { resetComposer() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("현재 이야기, 만든 게시물과 미디어를 비웁니다. 나의 취향 설정은 그대로 유지됩니다.")
        }
        .starImagePlaygroundSheet(
            isPresented: $showsImagePlayground,
            prompt: imagePlaygroundPrompt,
            onCompletion: receiveImagePlaygroundResult,
            onCancellation: {
                isGeneratingImage = false
                imageGenerationPostID = nil
            }
        )
        .composerNavSync(
            hasSendableContentKey: !trimmedIdea.isEmpty || !mediaItems.isEmpty,
            hasShareableContentKey: !trimmedIdea.isEmpty && !mediaItems.isEmpty,
            availabilitySignature: availabilitySignature,
            update: updateComposerNavState,
            sendTrigger: composerNavState.sendTrigger,
            onSend: { requestID in
                composerNavState.clearSendTrigger(requestID)
                runAI(aiChoice(for: composerNavState.sendChoice))
            },
            instagramShareTrigger: composerNavState.instagramShareTrigger,
            onInstagramShare: { requestID in
                composerNavState.clearInstagramShareTrigger(requestID)
                Task { await share() }
            }
        )
    }

    /// onChange 비교용으로 묶은, 클라우드 제공자 켬/끔·마지막 선택의 스냅샷 문자열.
    private var availabilitySignature: String {
        "\(availabilityStore.isOpenAIEnabled)-\(availabilityStore.isGeminiEnabled)-\(availabilityStore.isClaudeEnabled)-\(availabilityStore.lastUsedChoice.rawValue)"
    }

    /// 하단 탭의 보내기 상태(내용 존재 여부·표시할 AI)를 항상 최신으로 유지한다.
    @MainActor
    private func updateComposerNavState() {
        composerNavState.hasSendableContent = !trimmedIdea.isEmpty || !mediaItems.isEmpty
        composerNavState.hasShareableContent = !trimmedIdea.isEmpty && !mediaItems.isEmpty
        composerNavState.sendChoice = availabilityStore.resolvedChoice(preferring: availabilityStore.lastUsedChoice)
    }

    private func aiChoice(for identity: AIProviderIdentity) -> AIChoice {
        guard let provider = identity.externalProvider else { return .appleIntelligence }
        return .external(provider)
    }

    private func identity(for choice: AIChoice) -> AIProviderIdentity {
        switch choice {
        case .appleIntelligence: .device
        case let .external(provider): AIProviderIdentity(externalProvider: provider) ?? .device
        }
    }

    private var creationColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            heroCopy
            mediaAndWritingCard
            writingSettingsCard
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private var mediaAndWritingCard: some View {
        let pickerTitle = "미디어"
        let pickerIcon = "photo.badge.plus"

        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                BrandSectionTitle(title: "미디어", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)

                HStack(spacing: 10) {
                    PhotosPicker(
                        selection: $selectedItems,
                        maxSelectionCount: max(1, Self.maxMediaItems - mediaItems.count),
                        selectionBehavior: .ordered,
                        matching: .any(of: [.images, .videos]),
                        photoLibrary: .shared()
                    ) {
                        HStack(spacing: 8) {
                            Image(systemName: pickerIcon)
                                .foregroundStyle(BrandTheme.accent)
                            Text(pickerTitle)
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ComposerToolButtonStyle())
                    .disabled(isLoadingMedia || mediaItems.count >= Self.maxMediaItems)
                    .accessibilityHint("사진 보관함에서 게시 순서대로 최대 \(Self.maxMediaItems)개를 선택합니다")

                    Button(action: openCamera) {
                        HStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .foregroundStyle(BrandTheme.accent)
                            Text("카메라")
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ComposerToolButtonStyle())
                    .disabled(isLoadingMedia || mediaItems.count >= Self.maxMediaItems)
                    .accessibilityHint("카메라로 여러 장을 연속 촬영해 미디어에 추가합니다")
                }

                if !mediaItems.isEmpty { mediaOrderEditor }
            }
            .contentShape(Rectangle())
            .onDrop(
                of: [UTType.image.identifier, UTType.movie.identifier],
                isTargeted: $isMediaDropTargeted,
                perform: receiveDroppedMedia
            )
            .overlay {
                if isMediaDropTargeted {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(BrandTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .allowsHitTesting(false)
                }
            }

            if !mediaItems.isEmpty || isLoadingMedia {
                MediaPreview(items: mediaItems, aspect: previewAspect.ratio, isLoading: isLoadingMedia)
            }

            if !mediaItems.isEmpty {
                Picker("게시 비율", selection: $previewAspect) {
                    ForEach(PreviewAspect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                if let source = activeCaptionSource {
                    Label(source.title, systemImage: source.symbolName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                TextField("이야기를 적어 주세요 · AI 결과도 여기에 채워져요", text: $idea, axis: .vertical)
                    .lineLimit(3...20)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(theme.canvas, in: RoundedRectangle(cornerRadius: 14))
                    .disabled(isGenerating || isAutomationSessionActive)
                    .focused($isIdeaFocused)
                    .textSelection(.enabled)
                    .accessibilityHint("게시물의 바탕이 될 이야기를 입력하거나 AI가 만든 글을 다듬습니다")

                if let validation = liveValidationReport {
                    HStack {
                        Label(validation.passesAllRules ? "기준 통과" : "확인 필요", systemImage: validation.passesAllRules ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(validation.passesAllRules ? .green : .orange)
                        Spacer()
                        Text("\(trimmedIdea.count)자").monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))

                    if !validation.passesAllRules {
                        Text(validation.failedRuleDescriptions.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineSpacing(2)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: "paintpalette")
                        .accessibilityHidden(true)
                    Text(composerSummaryText)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            if comparisonCandidates.count > 1 { candidateComparison }

            aiChoiceButtons

            if isGenerating {
                generatingProgressCard
                    .transition(.opacity)
            }

            if reservesAIChoiceScrollClearance {
                Color.clear
                    .frame(height: 78)
                    .id("bottom-action-scroll-target")
            }

            if let message = errorMessage ?? statusMessage {
                Label(message, systemImage: errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                    .transition(.opacity)
            }

            if !trimmedIdea.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button { Task { await share() } } label: {
                        HStack {
                            if isPreparingShare { ProgressView().tint(.white) }
                            Label(isPreparingShare ? "준비 중" : "공유하기 →", systemImage: "paperplane.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlossyPrimaryButtonStyle())
                    .disabled(isPreparingShare || isGenerating)
                    .accessibilityHint("문구를 자동으로 복사하고 미디어 공유 화면을 엽니다")
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: previewAspect)
        .frame(maxWidth: 680, alignment: .leading)
        .starCard()
    }

    private var appIconThumbnail: some View {
        Image(toolbarAppIconAssetName)
        .resizable()
        .scaledToFill()
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private var toolbarAppIconAssetName: String {
        switch theme.style {
        case .bk: "AppIconToolbarBK"
        case .classic: "AppIconToolbarClassic"
        case .interstellar: "AppIconToolbarInterstellar"
        }
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("오늘 어떤 이야기를 전할까요?", systemImage: "sparkles")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)

            if theme.style == .bk {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accent)
                    .frame(width: 36, height: 3)
                    .accessibilityHidden(true)
            }
        }
    }

    private var writingSettingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isWritingSettingsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label("글 스타일 설정", systemImage: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: isWritingSettingsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { writingSettingsHeaderHeight = $0 }
                // 접힘 상태에서는 2배 높이 카드 전체가 탭 영역이 되도록 헤더를 채운다.
                .frame(maxHeight: isWritingSettingsExpanded ? nil : .infinity)
                .foregroundStyle(theme.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isWritingSettingsExpanded ? "펼쳐짐" : "접힘")

            if isWritingSettingsExpanded {
                Divider()
                settingsRow(title: "글자 수", systemImage: "textformat.size") {
                HStack(spacing: 8) {
                    Text("\(profileStore.profile.controls.characterCount)자")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 44, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { Double(profileStore.profile.controls.characterCount) },
                            set: { profileStore.profile.controls.characterCount = Int($0) }
                        ),
                        in: 50...500,
                        step: 10
                    )
                    .accessibilityLabel("글자 수")
                    .accessibilityValue("\(profileStore.profile.controls.characterCount)자")
                }
            }

            settingsRow(title: "이모지 사용", systemImage: "face.smiling.fill") {
                CompactChoiceControl(
                    items: EmojiIntensity.allCases,
                    selection: $profileStore.profile.emojiIntensity,
                    icon: \.compactIcon,
                    shortLabel: \.compactLabel,
                    accessibilityLabel: { "이모지 사용: \($0.title)" }
                )
            }

            settingsRow(title: "분위기", systemImage: "cloud.sun.fill") {
                Picker("분위기", selection: $mood) {
                    ForEach(PostMood.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }

            settingsRow(title: "스타일", systemImage: "text.book.closed.fill") {
                CompactChoiceControl(
                    items: PostStyle.allCases,
                    selection: $profileStore.profile.style,
                    icon: \.compactIcon,
                    shortLabel: \.title,
                    accessibilityLabel: { "스타일: \($0.title)" }
                )
            }

            settingsRow(title: "말투", systemImage: "quote.bubble.fill") {
                Picker("말투", selection: $profileStore.profile.tone) {
                    ForEach(PostTone.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }

            settingsRow(title: "나잇대", systemImage: "person.crop.circle.badge.clock") {
                Picker("나잇대", selection: $profileStore.profile.ageGroup) {
                    ForEach(AudienceAgeGroup.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }

            settingsRow(title: "줄넘김", systemImage: "arrow.turn.down.left") {
                Picker("줄넘김", selection: $profileStore.profile.lineBreakFrequency) {
                    ForEach(Self.lineBreakDisplayOrder) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }

            settingsRow(title: "내 글 반영", systemImage: "pencil.and.outline") {
                Picker("내 글 반영", selection: $length) {
                    ForEach(PostLength.allCases) { Text($0.storyWeightTitle).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            settingsRow(title: "추가로 하고 싶은 설정", systemImage: "square.and.pencil") {
                TextField(
                    "예: 이모티콘 대신 물결표를 즐겨 써줘 / 문장은 짧게 끊어줘",
                    text: $profileStore.profile.detailedGuidelines,
                    axis: .vertical
                )
                .font(.system(size: 13, weight: .regular))
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .padding(8)
                .background(theme.canvas, in: RoundedRectangle(cornerRadius: 10))
            }
            }
        }
        .controlSize(.small)
        // 접힘 상태 전체 높이(헤더 + 상하 패딩 10×2)가 자연 높이의 정확히 2배가 되도록,
        // 패딩 안쪽 콘텐츠를 (헤더×2 + 20)으로 고정한다. 펼침 상태는 손대지 않는다.
        .frame(height: isWritingSettingsExpanded ? nil : writingSettingsHeaderHeight.map { $0 * 2 + 20 })
        .padding(10)
        .background(theme.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.border, lineWidth: 1)
        }
        .onAppear {
            isWritingSettingsExpanded = false
        }
    }

    private func settingsRow<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var aiChoiceButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(AIChoice.allCases) { choice in
                    Button {
                        runAI(choice)
                    } label: {
                        VStack(spacing: 3) {
                            choice.icon
                                .frame(width: 32, height: 32)
                            Text(choice.title)
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.4)
                        }
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .background(
                            theme.surface,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(theme.border, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isChoiceDisabled(choice))
                    .opacity(isChoiceDisabled(choice) ? 0.46 : 1)
                    .accessibilityLabel(choice.title)
                    .accessibilityHint(choice.accessibilityHint)
                }

                Button {
                    runRandomAI()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "die.face.5.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .frame(width: 32, height: 32)
                        Text("Random")
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                    }
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(
                        theme.surface,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRandomChoiceDisabled)
                .opacity(isRandomChoiceDisabled ? 0.46 : 1)
                .accessibilityLabel("Random")
                .accessibilityHint("사용 가능한 AI 중 하나를 무작위로 골라 바로 만듭니다")
            }

            if let provider = pendingExternalProvider, !isGenerating {
                PasteButton(payloadType: String.self) { values in
                    guard let text = values.first else { return }
                    importAIResult(text, from: provider)
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityHint("\(provider.title)에서 복사한 결과를 게시물로 가져옵니다")
            }
        }
        .id("ai-choice-buttons")
        .animation(.easeInOut(duration: 0.2), value: isGenerating)
    }

    private var generatingProgressCard: some View {
        HStack(spacing: 10) {
            generatingStatusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(generatingStatusTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.ink)
                Text(generatingStatusSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if externalSubmittedAt != nil {
                    ProgressView(
                        value: Double(Self.remainingExternalSeconds(elapsedSeconds)),
                        total: Double(Self.externalGenerationTimeoutSeconds)
                    )
                    .progressViewStyle(.linear)
                    .tint(BrandTheme.accent)
                    .accessibilityLabel("AI 답변 대기 남은 시간")
                    .accessibilityValue(Self.formatCountdown(Self.remainingExternalSeconds(elapsedSeconds)))
                }
            }
            Spacer()
            Button("취소") {
                cancelExternalGeneration()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .accessibilityHint("현재 AI 요청을 중단하고 작성 화면으로 돌아갑니다")
        }
        .padding(10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandTheme.accent.opacity(0.35), lineWidth: 1)
        }
        .id("composer-progress")
    }

    /// "게시물 준비 중" 같은 모호한 점 하나짜리 스피너 대신, 지금 요청 중인 AI의 실제 아이콘을 보여주고
    /// 요청이 진행되는 동안에만(뷰가 나타나 있는 동안만) 계속 회전시킨다.
    private var generatingStatusIcon: some View {
        Group {
            if let assetName = activeExternalProvider?.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: activeExternalProvider == nil ? "apple.logo" : "sparkles")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(BrandTheme.accent)
            }
        }
        .frame(width: 28, height: 28)
        .rotationEffect(.degrees(sparklesRotationAngle))
        .accessibilityHidden(true)
        .onAppear {
            sparklesRotationAngle = 0
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                sparklesRotationAngle = 360
            }
        }
    }

    private var generatingStatusTitle: String {
        if let provider = activeExternalProvider {
            if isPreparingExternalAttachments {
                return "사진 \(mediaItems.filter { $0.kind == .image }.count)장 준비 중…"
            }
            if let _ = externalSubmittedAt {
                return "답변을 기다리는 중"
            }
            return "\(provider.title)에 연결하는 중…"
        }
        return "AI가 글을 쓰는 중이에요…"
    }

    private var generatingStatusSubtitle: String {
        if let _ = activeExternalProvider {
            if isPreparingExternalAttachments {
                return "원본은 그대로 두고 전송 크기로 최적화하고 있어요"
            }
            if let _ = externalSubmittedAt {
                return "남은 시간 \(Self.formatCountdown(Self.remainingExternalSeconds(elapsedSeconds)))"
            }
            return "입력창을 준비하고 있어요"
        }
        return "잠시만 기다려 주세요"
    }

    private static let externalGenerationTimeoutSeconds = 119

    private static func remainingExternalSeconds(_ elapsed: Int) -> Int {
        max(0, externalGenerationTimeoutSeconds - elapsed)
    }

    private static func formatCountdown(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @MainActor
    private func cancelExternalGeneration() {
        recordAIDiagnostic("run_cancelled")
        externalAttachmentPreparationTask?.cancel()
        externalAttachmentPreparationTask = nil
        generationID = nil
        browserContext = nil
        activeExternalProvider = nil
        pendingExternalProvider = nil
        externalSubmittedAt = nil
        elapsedSeconds = 0
        isGenerating = false
        activePhotoAttachments = []
        isPreparingExternalAttachments = false
        isAutomationSessionActive = false
        statusMessage = "AI 요청을 취소했어요"
    }

    @MainActor
    private func timeoutExternalGeneration() {
        recordAIDiagnostic("generation_failed")
        recordAIDiagnostic("run_failed")
        externalAttachmentPreparationTask?.cancel()
        externalAttachmentPreparationTask = nil
        generationID = nil
        browserContext = nil
        activeExternalProvider = nil
        externalSubmittedAt = nil
        elapsedSeconds = 0
        isGenerating = false
        activePhotoAttachments = []
        isPreparingExternalAttachments = false
        let message = "1분 59초 동안 답변이 없어서 중단했어요. 다시 시도해 주세요."
        errorMessage = message
        if isAutomationSessionActive {
            automationSurfaceState = .failure(message)
        }
    }

    @MainActor
    private func recordAIDiagnostic(_ event: String) {
        if let runID = AIBIDiagnosticsStore.shared.currentRunID {
            AIBIDiagnosticsStore.shared.record(runID: runID, event: event)
        }
    }

    @MainActor
    private func runAI(_ choice: AIChoice) {
        guard !isGenerating else { return }
        if case let .external(provider) = choice, !availabilityStore.isEnabled(provider) { return }
        dismissKeyboardForAutomation()
        availabilityStore.recordUsed(identity(for: choice))
        switch choice {
        case .appleIntelligence:
            Task { await generateDraft() }
        case let .external(provider):
            startExternalGeneration(for: provider)
        }
    }

    @MainActor
    private func startExternalGeneration(for provider: ExternalAIProvider) {
        guard !trimmedIdea.isEmpty || hasRepresentativePhoto else {
            errorMessage = "이야기를 입력하거나 사진을 추가해 주세요."
            return
        }
        let requestID = UUID()
        let diagnosticID = AIBIDiagnosticsStore.shared.start(provider: provider.rawValue)
        generationID = requestID
        isGenerating = true
        activeExternalProvider = provider
        pendingExternalProvider = provider
        externalSubmittedAt = nil
        elapsedSeconds = 0
        errorMessage = nil
        statusMessage = "\(provider.title)에 연결하는 중…"
        automationRelayState = .preparing
        shareMessage = nil
        shareMessageIsError = false
        generatedPost = nil
        generatedSignature = nil
        activeCaptionSource = nil
        activePhotoAttachments = []
        activeExternalPrompt = externalPrompt

        let sourceImages = mediaItems
            .filter { $0.kind == .image }
            .map(\.data)
        AIBIDiagnosticsStore.shared.record(runID: diagnosticID, event: "media_preparation_started", metrics: ["expected_count": sourceImages.count])
        guard !sourceImages.isEmpty else {
            isPreparingExternalAttachments = false
            if showsExternalAIBrowser {
                browserContext = ExternalAIBrowserContext(provider: provider)
            }
            return
        }

        isPreparingExternalAttachments = true
        statusMessage = "사진 \(sourceImages.count)장 준비 중…"
        let attachmentPolicy = sourceImages.count >= 5
            ? AIBIImageNormalizationPolicy(
                maximumImageCount: 8,
                maximumLongEdgePixels: 1_600,
                maximumBytesPerImage: 1_200_000,
                initialJPEGQuality: 0.80,
                minimumJPEGQuality: 0.46
            )
            : AIBIImageNormalizationPolicy()
        externalAttachmentPreparationTask?.cancel()
        externalAttachmentPreparationTask = Task {
            let prepared = await Task.detached(priority: .userInitiated) {
                try? AIBIImageNormalizer.normalizeOrdered(sourceImages, policy: attachmentPolicy)
            }.value
            guard !Task.isCancelled, generationID == requestID else { return }
            externalAttachmentPreparationTask = nil
            isPreparingExternalAttachments = false
            guard let prepared, prepared.count == sourceImages.count else {
                AIBIDiagnosticsStore.shared.record(runID: diagnosticID, event: "media_preparation_failed")
                let message = "선택한 사진을 전송용으로 준비하지 못했어요. 사진을 확인하고 다시 시도해 주세요."
                errorMessage = message
                activeExternalProvider = nil
                pendingExternalProvider = nil
                isGenerating = false
                activePhotoAttachments = []
                if isAutomationSessionActive {
                    automationSurfaceState = .failure(message)
                }
                return
            }
            activePhotoAttachments = prepared
            AIBIDiagnosticsStore.shared.record(runID: diagnosticID, event: "media_prepared", metrics: ["prepared_count": prepared.count, "total_bytes": prepared.reduce(0) { $0 + $1.data.count }])
            activeExternalPrompt = externalPrompt
            statusMessage = "사진 \(prepared.count)장을 \(provider.title)에 연결하는 중…"
            automationRelayState = .sending
            if showsExternalAIBrowser {
                browserContext = ExternalAIBrowserContext(provider: provider)
            }
        }
    }

    private var mediaOrderEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("길게 눌러 순서 변경")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(mediaItems.enumerated()), id: \.element.id) { index, media in
                        ZStack(alignment: .topTrailing) {
                            MediaThumbnail(media: media)

                            Button(role: .destructive) {
                                withAnimation(.snappy) { mediaItems.removeAll { $0.id == media.id } }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.72))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(index + 1)번째 미디어 삭제")
                        }
                        .overlay(alignment: .topLeading) {
                            if index == 0 {
                                Text("대표")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(
                                        theme.style == .bk ? BrandTheme.carbon : Color.black.opacity(0.66),
                                        in: Capsule()
                                    )
                                    .padding(6)
                            }
                        }
                        .onDrag {
                            draggedMediaID = media.id
                            return NSItemProvider(object: media.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: MediaReorderDropDelegate(
                                targetID: media.id,
                                mediaItems: $mediaItems,
                                draggedMediaID: $draggedMediaID
                            )
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(index == 0 ? "대표 \(media.kind.title)" : "\(index + 1)번째 \(media.kind.title)")
                        .accessibilityAction(named: "앞으로 이동") { moveMedia(at: index, offset: -1) }
                        .accessibilityAction(named: "뒤로 이동") { moveMedia(at: index, offset: 1) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(theme.canvas, in: RoundedRectangle(cornerRadius: 14))
    }

    private var candidateComparison: some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandSectionTitle(title: "결과 비교", systemImage: "square.on.square")
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(comparisonCandidates, id: \.source) { candidate in
                        let report = validationReport(for: candidate)
                        Button {
                            useCandidate(candidate)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(candidate.source.title, systemImage: candidate.source.symbolName)
                                        .font(.caption.weight(.semibold))
                                    Spacer(minLength: 8)
                                    Image(systemName: report.passesAllRules ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(report.passesAllRules ? .green : .orange)
                                }
                                Text(candidate.post.previewSnippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                Text("\(candidate.post.characterCount)자 · \(report.passesAllRules ? "통과" : "확인 필요")")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(report.passesAllRules ? .green : .orange)
                            }
                            .frame(width: 220, height: 112, alignment: .topLeading)
                            .padding(12)
                            .background(
                                activeCaptionSource == candidate.source ? theme.selectionFill : theme.canvas,
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(activeCaptionSource == candidate.source ? BrandTheme.accent : Color.secondary.opacity(0.2), lineWidth: activeCaptionSource == candidate.source ? 1.5 : 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("이 결과를 게시물 미리보기에 사용합니다")
                    }
                }
            }
        }
    }

    private var hasComposerContent: Bool {
        !idea.isEmpty || generatedPost != nil || !mediaItems.isEmpty || !selectedItems.isEmpty || !captionCandidates.isEmpty || isGenerating
    }

    private var trimmedIdea: String { idea.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var composerSummaryText: String {
        let profile = profileStore.profile
        return "\(mood.rawValue) · \(profile.style.title) · \(profile.tone.title) · \(profile.controls.characterCount)자"
    }

    private var currentDraftSignature: DraftSignature {
        DraftSignature(
            idea: trimmedIdea,
            mood: mood,
            length: length,
            profile: profileStore.profile
        )
    }

    private var comparisonCandidates: [CaptionCandidate] {
        guard let generatedSignature else { return [] }
        return CaptionSource.allCases.compactMap { source in
            guard let candidate = captionCandidates[source], candidate.signature == generatedSignature else { return nil }
            return candidate
        }
    }

    private var currentValidationContext: CaptionValidationContext {
        let profile = profileStore.profile
        return CaptionValidationContext(
            destinationLimit: CaptionFormatReport.neutralSafetyCharacterLimit,
            prohibitedPhrases: "",
            emojiIntensity: profile.emojiIntensity
        )
    }

    /// 지금 편집 중인 글(직접 쓴 글이든 AI가 돌려준 글이든)을 그대로 기준으로 검증한다.
    private var liveValidationReport: CaptionValidationReport? {
        guard !trimmedIdea.isEmpty else { return nil }
        return CaptionValidationReport.evaluate(idea, context: currentValidationContext)
    }

    private var hasRepresentativePhoto: Bool {
        mediaItems.contains { $0.kind == .image }
    }

    private func isChoiceDisabled(_ choice: AIChoice) -> Bool {
        if isGenerating { return true }
        switch choice {
        case .appleIntelligence:
            return trimmedIdea.isEmpty && !hasRepresentativePhoto
        case let .external(provider):
            if !availabilityStore.isEnabled(provider) { return true }
            return trimmedIdea.isEmpty && !hasRepresentativePhoto
        }
    }

    private var isRandomChoiceDisabled: Bool {
        isGenerating
            || (trimmedIdea.isEmpty && !hasRepresentativePhoto)
            || availabilityStore.enabledExternalProviders.isEmpty
    }

    private func runRandomAI() {
        guard let choice = randomAutomationChoice() else {
            errorMessage = Self.noRandomProviderMessage
            return
        }
        runAI(aiChoice(for: choice))
    }

    /// 사진만 있는지, 사진과 글이 함께 있는지, 글만 있는지에 따라 외부 AI에게 보낼 문구를 자동으로 고른다.
    private var externalPrompt: String {
        let profile = profileStore.profile
        switch (!activePhotoAttachments.isEmpty, !trimmedIdea.isEmpty) {
        case (true, true):
            return photoAndTextPrompt(profile: profile)
        case (true, false):
            return photoOnlyPrompt(profile: profile)
        default:
            return profile.generationPrompt(for: trimmedIdea, mood: mood, length: length)
        }
    }

    /// 사진 관련 요청도 설정 화면에 보이는 값과 "상세 작성 기준"만 사용한다. 숨은 고정 형식은 없다.
    private func photoOnlyPrompt(profile: CreatorProfile) -> String {
        var lines: [String] = [
            "[상황]",
            "선택한 사진 \(activePhotoAttachments.count)장이 순서대로 첨부돼 있어. 사진을 모두 실제로 살펴보고, 사진에 없는 내용은 지어내지 마.",
            "",
            "[원하는 결과]",
            "사진 속 장면과 분위기를 바탕으로 올릴 한국어 글을 쓰고, 완성 문구만 출력해.",
            "- 글자 수: \(profile.characterCountPromptInstruction)",
            "- 나잇대: \(profile.ageGroup.promptAudienceHint)",
            "- 분위기: \(mood.rawValue), \(length.promptInstruction)",
            "- 이모지 사용: \(profile.emojiIntensity.promptInstruction)",
            "- 스타일: \(profile.style.promptInstruction)",
            "- 말투: \(profile.tone.promptInstruction)",
            "- 줄넘김: \(profile.lineBreakFrequency.promptInstruction)"
        ]
        let details = profile.detailedGuidelines.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty { lines.append("- 추가로 하고 싶은 설정: \(details)") }
        return lines.joined(separator: "\n")
    }

    private func photoAndTextPrompt(profile: CreatorProfile) -> String {
        var lines: [String] = [
            "[상황]",
            "선택한 사진 \(activePhotoAttachments.count)장이 순서대로 첨부돼 있고 내가 적은 메모가 함께 있어. 사진을 모두 실제로 살펴보고, 사진과 메모 둘 다에 어울리는 글을 써 줘. 사진에 없는 내용은 지어내지 마.",
            "",
            "[내가 입력한 내용]",
            trimmedIdea,
            "",
            "[원하는 결과]",
            "사진과 위 내용을 함께 반영한 한국어 글을 쓰고, 완성 문구만 출력해.",
            "- 글자 수: \(profile.characterCountPromptInstruction)",
            "- 나잇대: \(profile.ageGroup.promptAudienceHint)",
            "- 분위기: \(mood.rawValue), \(length.promptInstruction)",
            "- 이모지 사용: \(profile.emojiIntensity.promptInstruction)",
            "- 스타일: \(profile.style.promptInstruction)",
            "- 말투: \(profile.tone.promptInstruction)",
            "- 줄넘김: \(profile.lineBreakFrequency.promptInstruction)"
        ]
        let details = profile.detailedGuidelines.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty { lines.append("- 추가로 하고 싶은 설정: \(details)") }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private func importAIResult(_ text: String, from provider: ExternalAIProvider) {
        dismissKeyboardForAutomation()
        guard !text.isEmpty else {
            let message = "복사한 결과가 비어 있어요."
            errorMessage = message
            activeExternalProvider = nil
            isGenerating = false
            activePhotoAttachments = []
            if isAutomationSessionActive {
                automationSurfaceState = .failure(message)
            }
            return
        }
        isIdeaFocused = false
        if let diagnosticID = AIBIDiagnosticsStore.shared.currentRunID {
            AIBIDiagnosticsStore.shared.record(runID: diagnosticID, event: "result_applied", metrics: ["response_length": text.count])
            AIBIDiagnosticsStore.shared.record(runID: diagnosticID, event: "run_completed")
        }
        let signature = currentDraftSignature
        let lines = text.components(separatedBy: "\n")
        let hashtags = (lines.first ?? "").split(separator: " ").compactMap { token -> String? in
            guard token.hasPrefix("#") else { return nil }
            return String(token.dropFirst())
        }
        let post = GeneratedPost(
            sourceIdea: signature.idea,
            hook: lines.dropFirst().first ?? "",
            caption: lines.dropFirst().dropLast().joined(separator: "\n"),
            callToAction: lines.last ?? "",
            hashtags: hashtags,
            composedText: text
        )
        let candidate = CaptionCandidate(
            source: provider.captionSource,
            post: post,
            signature: signature,
            requestID: UUID()
        )
        captionCandidates[candidate.source] = candidate
        useCandidate(candidate)
        if let submittedAt = externalSubmittedAt, let identity = AIProviderIdentity(externalProvider: provider) {
            runMetricsStore.recordRun(for: identity, elapsedSeconds: Date().timeIntervalSince(submittedAt))
        }
        pendingExternalProvider = nil
        activeExternalProvider = nil
        externalSubmittedAt = nil
        elapsedSeconds = 0
        isGenerating = false
        errorMessage = nil
        activePhotoAttachments = []
        statusMessage = validationReport(for: candidate).passesAllRules ? "\(provider.title) 결과 가져옴" : "가져옴 · 기준 확인 필요"
        if isAutomationSessionActive {
            automationSurfaceState = .result(text)
        }
    }

    @MainActor
    private func useCandidate(_ candidate: CaptionCandidate) {
        mediaItems.removeAll { media in
            guard let sourcePostID = media.generatedFromPostID else { return false }
            return sourcePostID != candidate.post.id
        }
        generatedPost = candidate.post
        generatedSignature = candidate.signature
        activeCaptionSource = candidate.source
        idea = candidate.post.composedText
    }

    @MainActor
    private func resetComposer() {
        dismissKeyboardForAutomation()
        mediaLoadTask?.cancel()
        mediaLoadID = UUID()
        generationID = nil
        sharePreparationID = nil
        isGenerating = false
        isPreparingShare = false
        idea = ""
        generatedPost = nil
        generatedSignature = nil
        activeCaptionSource = nil
        captionCandidates.removeAll()
        selectedItems = []
        mediaItems.removeAll()
        errorMessage = nil
        statusMessage = nil
        shareMessage = nil
        shareMessageIsError = false
        pendingExternalProvider = nil
        activeExternalProvider = nil
        externalSubmittedAt = nil
        elapsedSeconds = 0
        browserContext = nil
        sharePayload = nil
        showsCamera = false
        showsImagePlayground = false
        isGeneratingImage = false
        imageGenerationPostID = nil
        externalAttachmentPreparationTask?.cancel()
        externalAttachmentPreparationTask = nil
        activePhotoAttachments = []
        activeExternalPrompt = ""
        isPreparingExternalAttachments = false
        isAutomationSessionActive = false
        automationSurfaceState = .processing
        automationRelayState = .preparing
        isAutomationPickerPresented = false
        automationPickerItems = []
        pendingCameraResetOnCapture = false
        resetScrollRequest = UUID()
    }

    /// 설정에서 자동화를 끌 때 호출된다. 대기 중인 사진 선택기와 진행 중인 자동화 세션만 정리하고,
    /// 사용자가 손으로 입력한 이야기·미디어·생성된 글은 자동화와 무관하므로 그대로 둔다.
    @MainActor
    private func cancelPendingAutomationUI() {
        isAutomationPickerPresented = false
        automationPickerItems = []
        guard isAutomationSessionActive else { return }
        closeAutomationSurface()
    }

    /// 자동화 화면의 취소/닫기 동작. 생성 중이면 AIBI 작업을 즉시 중단하고, 결과·실패 상태면 조용히 화면만 닫는다.
    @MainActor
    private func closeAutomationSurface() {
        if isGenerating {
            cancelExternalGeneration()
        } else {
            externalAttachmentPreparationTask?.cancel()
            externalAttachmentPreparationTask = nil
            generationID = nil
            browserContext = nil
            isAutomationSessionActive = false
            automationSurfaceState = .processing
        }
    }

    /// 같은 선택 사진을 그대로 유지한 채, 이전 결과만 지우고 새 무작위 클라우드 제공자로 재시도한다.
    @MainActor
    private func retryAutomationGeneration() {
        guard let choice = randomAutomationChoice() else {
            automationSurfaceState = .failure(Self.noRandomProviderMessage)
            return
        }
        automationActiveChoice = choice
        dismissKeyboardForAutomation()
        idea = ""
        generatedPost = nil
        generatedSignature = nil
        activeCaptionSource = nil
        captionCandidates.removeAll()
        errorMessage = nil
        statusMessage = nil
        automationSurfaceState = .processing
        automationRelayState = .preparing
        runAutomationGeneration(choice)
    }

    /// 무작위 선택(랜덤 버튼·자동화)이 고를 수 있는 AI. 꺼진 클라우드 제공자는 후보에서 빠지고,
    /// 기기 AI(온디바이스)는 무작위 후보에 포함하지 않는다. 켜진 클라우드 제공자가 없으면 nil.
    private func randomAutomationChoice() -> AIProviderIdentity? {
        availabilityStore.enabledExternalProviders
            .compactMap(AIProviderIdentity.init(externalProvider:))
            .randomElement()
    }

    private static let noRandomProviderMessage = "무작위로 고를 수 있는 클라우드 AI가 없어요. 설정에서 AI를 켜거나 직접 선택해 주세요."

    @MainActor
    private func runAutomationGeneration(_ choice: AIProviderIdentity) {
        availabilityStore.recordUsed(choice)
        switch choice {
        case .device:
            Task { await generateDraft() }
        case .openAI, .gemini, .claude:
            guard let provider = choice.externalProvider else { return }
            startExternalGeneration(for: provider)
        }
    }

    private func validationContext(for signature: DraftSignature) -> CaptionValidationContext {
        CaptionValidationContext(
            destinationLimit: CaptionFormatReport.neutralSafetyCharacterLimit,
            prohibitedPhrases: "",
            emojiIntensity: signature.profile.emojiIntensity
        )
    }

    private func validationReport(for candidate: CaptionCandidate) -> CaptionValidationReport {
        CaptionValidationReport.evaluate(
            candidate.post.composedText,
            context: validationContext(for: candidate.signature)
        )
    }

    @MainActor
    private func generateDraft() async {
        guard !trimmedIdea.isEmpty || hasRepresentativePhoto else {
            errorMessage = "이야기를 입력하거나 사진을 추가해 주세요."
            return
        }
        let requestID = UUID()
        generationID = requestID
        isGenerating = true
        activeExternalProvider = nil
        errorMessage = nil
        statusMessage = "AI가 글을 쓰는 중이에요…"
        shareMessage = nil
        shareMessageIsError = false
        generatedPost = nil
        generatedSignature = nil
        activeCaptionSource = nil
        do {
            let profile = profileStore.profile
            let signature = currentDraftSignature
            let post: GeneratedPost
            let source: CaptionSource
            let deviceStartedAt = Date()
            if DeviceIntelligenceCaptionGenerator.availability == .available,
               let devicePost = try? await DeviceIntelligenceCaptionGenerator().generate(
                    from: trimmedIdea,
                    mood: mood,
                    length: length,
                    profile: profile
               ) {
                post = devicePost
                source = .device
                runMetricsStore.recordRun(for: .device, elapsedSeconds: Date().timeIntervalSince(deviceStartedAt))
            } else {
                post = try await PreviewCaptionGenerator().generate(
                    from: trimmedIdea,
                    mood: mood,
                    length: length,
                    profile: profile
                )
                source = .deterministic
            }
            let candidate = CaptionCandidate(
                source: source,
                post: post,
                signature: signature,
                requestID: UUID()
            )
            guard generationID == requestID else { return }
            captionCandidates[source] = candidate
            useCandidate(candidate)
            statusMessage = validationReport(for: candidate).passesAllRules ? "완료" : "확인 필요"
            if isAutomationSessionActive {
                automationSurfaceState = .result(candidate.post.composedText)
            }
        } catch {
            if generationID == requestID {
                errorMessage = error.localizedDescription
                if isAutomationSessionActive {
                    automationSurfaceState = .failure(error.localizedDescription)
                }
            }
        }
        if generationID == requestID {
            generationID = nil
            isGenerating = false
        }
    }

    @MainActor
    private func loadMedia(from items: [PhotosPickerItem], loadID: UUID) async {
        isLoadingMedia = true
        errorMessage = nil
        defer {
            if mediaLoadID == loadID {
                isLoadingMedia = false
                selectedItems = []
            }
        }
        var loaded: [ComposerMedia] = []
        for item in items {
            if Task.isCancelled { return }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            guard !Task.isCancelled, mediaLoadID == loadID else { return }
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) })
            loaded.append(ComposerMedia(
                data: data,
                kind: type?.conforms(to: .movie) == true ? .video : .image,
                fileExtension: type?.preferredFilenameExtension
            ))
        }
        guard !Task.isCancelled, mediaLoadID == loadID else { return }
        if loaded.isEmpty {
            errorMessage = "선택한 미디어를 불러오지 못했어요."
        } else {
            appendMedia(loaded)
        }
    }

    /// 공유 확장이 채워 둔 공유 보관함의 사진을 사진 선택기 없이 바로 미디어에 채우고 자동화를 시작한다.
    /// 메모리로 불러오는 데 성공한 경우에만 공유 보관함의 파일과 매니페스트를 지운다.
    @MainActor
    private func importPendingShareBatch() async {
        guard let batch = SharedInbox.oldestPendingBatch() else { return }

        dismissKeyboardForAutomation()

        isLoadingMedia = true
        errorMessage = nil
        var loaded: [ComposerMedia] = []
        for filename in batch.filenames {
            guard let url = try? SharedInbox.fileURL(named: filename),
                  let data = try? Data(contentsOf: url) else { continue }
            loaded.append(ComposerMedia(data: data, kind: .image, fileExtension: url.pathExtension))
        }
        isLoadingMedia = false

        guard loaded.count == batch.filenames.count else {
            errorMessage = "공유된 사진을 불러오지 못했어요. 다시 공유해 주세요."
            return
        }

        resetComposer()
        mediaItems = Array(loaded.prefix(Self.maxMediaItems))
        do {
            try SharedInbox.removeBatch(id: batch.id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        SharedInbox.deleteFiles(for: batch)

        guard hasRepresentativePhoto else { return }
        guard let choice = randomAutomationChoice() else {
            errorMessage = Self.noRandomProviderMessage
            return
        }
        automationActiveChoice = choice
        automationSurfaceState = .processing
        dismissKeyboardForAutomation()
        isAutomationSessionActive = true
        runAutomationGeneration(choice)
    }

    @MainActor
    private func dismissKeyboardForAutomation() {
        isIdeaFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.endEditing(true)
            }
        }
    }

    /// 브라우저 닫힘 전환 중 iOS가 이전 입력 포커스를 복원하는 경우까지 다시 내려 준다.
    @MainActor
    private func dismissKeyboardAfterBrowserDismissal() {
        dismissKeyboardForAutomation()
        Task { @MainActor in
            for delay in [80, 260, 520] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard isAutomationSessionActive, browserContext == nil else { return }
                dismissKeyboardForAutomation()
            }
        }
    }

    /// 웹 자동 전송 직후 WebKit이 잠깐 포커스를 되살리는 경우까지 여러 번 정리해,
    /// 자동화 전체 화면 하단에 키보드 입력 보조 막대가 남지 않게 한다.
    @MainActor
    private func dismissKeyboardAfterAutomationSubmission() {
        dismissKeyboardForAutomation()
        Task { @MainActor in
            for delay in [120, 420, 900] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard isAutomationSessionActive else { return }
                dismissKeyboardForAutomation()
            }
        }
    }

    private func receiveDroppedMedia(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        guard mediaItems.count < Self.maxMediaItems else {
            errorMessage = "미디어는 최대 \(Self.maxMediaItems)개까지 추가할 수 있어요."
            return false
        }

        mediaLoadTask?.cancel()
        let loadID = UUID()
        mediaLoadID = loadID
        mediaLoadTask = Task { await loadDroppedMedia(from: providers, loadID: loadID) }
        return true
    }

    @MainActor
    private func loadDroppedMedia(from providers: [NSItemProvider], loadID: UUID) async {
        isLoadingMedia = true
        errorMessage = nil
        defer {
            if mediaLoadID == loadID { isLoadingMedia = false }
        }

        var loaded: [ComposerMedia] = []
        for provider in providers {
            if Task.isCancelled { return }
            let contentTypes = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            guard let type = contentTypes.first(where: { $0.conforms(to: .movie) })
                    ?? contentTypes.first(where: { $0.conforms(to: .image) }),
                  let data = await loadDataRepresentation(from: provider, typeIdentifier: type.identifier),
                  !data.isEmpty else { continue }
            guard !Task.isCancelled, mediaLoadID == loadID else { return }
            loaded.append(ComposerMedia(
                data: data,
                kind: type.conforms(to: .movie) ? .video : .image,
                fileExtension: type.preferredFilenameExtension
            ))
        }

        guard !Task.isCancelled, mediaLoadID == loadID else { return }
        if loaded.isEmpty {
            errorMessage = "드래그한 미디어를 불러오지 못했어요."
        } else {
            appendMedia(loaded)
        }
    }

    private func loadDataRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func appendMedia(_ loaded: [ComposerMedia]) {
        let availableCount = max(0, Self.maxMediaItems - mediaItems.count)
        let accepted = Array(loaded.prefix(availableCount))
        guard !accepted.isEmpty else {
            errorMessage = "미디어는 최대 \(Self.maxMediaItems)개까지 추가할 수 있어요."
            return
        }
        mediaItems.append(contentsOf: accepted)
        errorMessage = nil
        statusMessage = loaded.count > accepted.count
            ? "\(accepted.count)개 추가 · 최대 \(Self.maxMediaItems)개"
            : "\(accepted.count)개 추가"
    }

    private func moveMedia(at index: Int, offset: Int) {
        let destination = index + offset
        guard mediaItems.indices.contains(index), mediaItems.indices.contains(destination) else { return }
        mediaItems.swapAt(index, destination)
    }

    @MainActor
    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "이 기기에서는 카메라를 사용할 수 없어요."
            return
        }
        errorMessage = nil
        showsCamera = true
    }

    @MainActor
    private func addCameraPhotos(_ photos: [Data]) {
        let shouldResetForAutomation = pendingCameraResetOnCapture
        pendingCameraResetOnCapture = false
        if shouldResetForAutomation, !photos.isEmpty {
            resetComposer()
        }
        let availableCount = max(0, Self.maxMediaItems - mediaItems.count)
        let accepted = photos.prefix(availableCount)
        guard !accepted.isEmpty else { return }
        mediaItems.append(contentsOf: accepted.map {
            ComposerMedia(data: $0, kind: .image, fileExtension: "jpg")
        })
        if mediaItems.count >= Self.maxMediaItems {
            statusMessage = "촬영한 사진 \(accepted.count)장 추가 · 최대 \(Self.maxMediaItems)개"
        } else {
            statusMessage = "촬영한 사진 \(accepted.count)장 추가"
        }
    }

    @MainActor
    private func share() async {
        let text = trimmedIdea
        guard !text.isEmpty else {
            shareMessage = "먼저 이야기를 적어 주세요."
            shareMessageIsError = true
            return
        }
        guard !mediaItems.isEmpty else {
            shareMessage = "사진이나 영상을 먼저 추가해 주세요."
            shareMessageIsError = true
            return
        }
        guard mediaItems.count <= Self.maxMediaItems else {
            shareMessage = "미디어는 최대 \(Self.maxMediaItems)개까지 공유할 수 있어요."
            shareMessageIsError = true
            return
        }
        UIPasteboard.general.string = text
        let requestID = UUID()
        sharePreparationID = requestID
        isPreparingShare = true
        errorMessage = nil
        shareMessage = "공유 준비 중"
        shareMessageIsError = false
        let snapshot = mediaItems
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepareShareFiles(from: snapshot)
            }.value
            guard sharePreparationID == requestID else {
                try? FileManager.default.removeItem(at: prepared.directory)
                return
            }
            let activityItems: [Any]
            if snapshot.count == 1,
               snapshot[0].kind == .image,
               let image = UIImage(contentsOfFile: prepared.items[0].path) {
                activityItems = [image]
            } else {
                activityItems = prepared.items
            }
            shareMessage = (liveValidationReport?.passesAllRules ?? false) ? "문구 복사됨" : "확인 필요 · 문구 복사됨"
            shareMessageIsError = false
            sharePayload = SharePayload(items: activityItems, cleanupURLs: [prepared.directory])
        } catch {
            if sharePreparationID == requestID {
                shareMessage = "미디어 공유를 준비하지 못했어요: \(error.localizedDescription)"
                shareMessageIsError = true
            }
        }
        if sharePreparationID == requestID {
            sharePreparationID = nil
            isPreparingShare = false
        }
    }

    nonisolated private static func prepareShareFiles(from mediaItems: [ComposerMedia]) throws -> (items: [URL], directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imanagerai-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let urls = try mediaItems.enumerated().map { index, media in
                let safeExtension = media.fileExtension?.lowercased().filter { $0.isLetter || $0.isNumber }
                let fallback = media.kind == .image ? "png" : "mov"
                let ext = safeExtension?.isEmpty == false ? safeExtension! : fallback
                let url = directory.appendingPathComponent(String(format: "%02d.%@", index + 1, ext))
                try media.data.write(to: url)
                return url
            }
            return (urls, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @MainActor
    private func makeImageFromPost() async {
        guard let post = generatedPost, mediaItems.count < Self.maxMediaItems else { return }
        isGeneratingImage = true
        errorMessage = nil

        if imagePlaygroundIsAvailable {
            imageGenerationPostID = post.id
            imagePlaygroundPrompt = post.composedText
            showsImagePlayground = true
            return
        }

        do {
            let payload = GeneratedImagePayload(data: try makeLocalImageData(from: post), fileExtension: "png")
            guard generatedPost?.id == post.id else { return }
            mediaItems.append(ComposerMedia(
                data: payload.data,
                kind: .image,
                fileExtension: payload.fileExtension,
                generatedFromPostID: post.id
            ))
            statusMessage = "이미지 추가"
        } catch {
            errorMessage = error.localizedDescription
        }
        isGeneratingImage = false
    }

    private var imagePlaygroundIsAvailable: Bool {
#if canImport(ImagePlayground)
        if #available(iOS 18.1, *) {
            return ImagePlaygroundViewController.isAvailable
        }
#endif
        return false
    }

    @MainActor
    private func receiveImagePlaygroundResult(_ url: URL) {
        defer {
            isGeneratingImage = false
            imageGenerationPostID = nil
        }
        do {
            let data = try Data(contentsOf: url)
            guard let sourcePostID = imageGenerationPostID,
                  generatedPost?.id == sourcePostID,
                  mediaItems.count < Self.maxMediaItems else { return }
            let fileExtension = url.pathExtension.isEmpty ? "png" : url.pathExtension
            mediaItems.append(ComposerMedia(
                data: data,
                kind: .image,
                fileExtension: fileExtension,
                generatedFromPostID: sourcePostID
            ))
            statusMessage = "이미지 추가"
        } catch {
            errorMessage = "만든 이미지를 불러오지 못했어요."
        }
    }

    private func makeLocalImageData(from post: GeneratedPost) throws -> Data {
        let size = CGSize(width: 1080, height: 1350)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            let colors = imagePalette(for: post.sourceIdea)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [colors.background.cgColor, colors.glow.cgColor] as CFArray,
                locations: [0, 1]
            )!
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )

            cg.setFillColor(colors.accent.withAlphaComponent(0.16).cgColor)
            cg.fillEllipse(in: CGRect(x: -160, y: 180, width: 760, height: 760))
            cg.setFillColor(colors.accent.withAlphaComponent(0.1).cgColor)
            cg.fillEllipse(in: CGRect(x: 590, y: 760, width: 620, height: 620))

            let card = CGRect(x: 110, y: 210, width: 860, height: 930)
            let cardPath = UIBezierPath(roundedRect: card, cornerRadius: 58)
            UIColor.white.withAlphaComponent(0.78).setFill()
            cardPath.fill()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = 15
            let headline = imageHeadline(from: post.sourceIdea)
            (headline as NSString).draw(
                in: CGRect(x: 180, y: 410, width: 720, height: 300),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 68, weight: .bold),
                    .foregroundColor: colors.ink,
                    .paragraphStyle: paragraph
                ]
            )

            let hook = post.hook.trimmingCharacters(in: .whitespacesAndNewlines)
            (hook as NSString).draw(
                in: CGRect(x: 200, y: 760, width: 680, height: 180),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 34, weight: .medium),
                    .foregroundColor: colors.ink.withAlphaComponent(0.72),
                    .paragraphStyle: paragraph
                ]
            )

            let star = UIBezierPath()
            let center = CGPoint(x: 540, y: 330)
            for index in 0..<10 {
                let radius: CGFloat = index.isMultiple(of: 2) ? 64 : 27
                let angle = CGFloat(index) * .pi / 5 - .pi / 2
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                index == 0 ? star.move(to: point) : star.addLine(to: point)
            }
            star.close()
            colors.accent.setFill()
            star.fill()

            ("STAR MANAGER" as NSString).draw(
                in: CGRect(x: 0, y: 1050, width: size.width, height: 60),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 27, weight: .semibold),
                    .foregroundColor: colors.accent,
                    .paragraphStyle: paragraph,
                    .kern: 6
                ]
            )
        }

        guard let data = image.pngData() else { throw AIBackendError.missingImage }
        return data
    }

    private func imageHeadline(from idea: String) -> String {
        let words = idea.split(whereSeparator: \.isWhitespace)
        let headline = words.prefix(6).joined(separator: " ")
        return headline.isEmpty ? "오늘의 이야기를\n한 장에 담다" : headline
    }

    private func imagePalette(for text: String) -> (background: UIColor, glow: UIColor, accent: UIColor, ink: UIColor) {
        let palettes: [(UIColor, UIColor, UIColor, UIColor)] = [
            (#colorLiteral(red: 0.95, green: 0.91, blue: 0.82, alpha: 1), #colorLiteral(red: 0.84, green: 0.76, blue: 0.91, alpha: 1), #colorLiteral(red: 0.38, green: 0.28, blue: 0.58, alpha: 1), #colorLiteral(red: 0.14, green: 0.13, blue: 0.15, alpha: 1)),
            (#colorLiteral(red: 0.9, green: 0.95, blue: 0.93, alpha: 1), #colorLiteral(red: 0.71, green: 0.84, blue: 0.83, alpha: 1), #colorLiteral(red: 0.1, green: 0.38, blue: 0.38, alpha: 1), #colorLiteral(red: 0.1, green: 0.18, blue: 0.18, alpha: 1)),
            (#colorLiteral(red: 0.97, green: 0.9, blue: 0.86, alpha: 1), #colorLiteral(red: 0.95, green: 0.72, blue: 0.58, alpha: 1), #colorLiteral(red: 0.72, green: 0.25, blue: 0.13, alpha: 1), #colorLiteral(red: 0.2, green: 0.12, blue: 0.1, alpha: 1))
        ]
        let value = text.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palettes[abs(value) % palettes.count]
    }
}

private enum PreviewAspect: String, CaseIterable, Identifiable {
    case square
    case feed
    case vertical

    var id: String { rawValue }
    var title: String {
        switch self { case .square: "1:1"; case .feed: "4:5"; case .vertical: "9:16" }
    }
    var ratio: CGFloat {
        switch self { case .square: 1; case .feed: 4 / 5; case .vertical: 9 / 16 }
    }
}

/// 짧은 아이콘+라벨 버튼을 한 줄에 나란히 배치하는 압축 선택 컨트롤.
/// 세그먼트 컨트롤보다 시각 폭이 좁아, 큰 다이나믹 타입에서도 한 줄을 유지하기 쉽다.
private struct CompactChoiceControl<Item: Identifiable & Hashable & CaseIterable>: View where Item.AllCases: RandomAccessCollection {
    let items: Item.AllCases
    @Binding var selection: Item
    let icon: (Item) -> String
    let shortLabel: (Item) -> String
    let accessibilityLabel: (Item) -> String

    init(
        items: Item.AllCases,
        selection: Binding<Item>,
        icon: @escaping (Item) -> String,
        shortLabel: @escaping (Item) -> String,
        accessibilityLabel: @escaping (Item) -> String
    ) {
        self.items = items
        self._selection = selection
        self.icon = icon
        self.shortLabel = shortLabel
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(items)) { item in
                let isSelected = item == selection
                Button {
                    selection = item
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: icon(item))
                            .font(.system(size: 12, weight: .semibold))
                        Text(shortLabel(item))
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(
                        isSelected ? AnyShapeStyle(BrandTheme.accent) : AnyShapeStyle(Color.secondary.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(item))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

private struct DraftSignature: Equatable {
    let idea: String
    let mood: PostMood
    let length: PostLength
    let profile: CreatorProfile
}

private extension ExternalAIProvider {
    var symbolName: String {
        switch self {
        case .openAI: "bubble.left.and.text.bubble.right"
        case .gemini: "diamond"
        case .grok: "xmark"
        case .claude: "sparkles"
        }
    }
    var assetName: String? {
        switch self {
        case .openAI: "ChatGPTBrand"
        case .gemini: "GeminiBrand"
        case .grok: "GrokBrand"
        case .claude: "ClaudeBrand"
        }
    }
    var backgroundColor: Color {
        switch self {
        case .openAI: .white
        case .gemini: Color(red: 0.92, green: 0.95, blue: 1.00)
        case .grok: .black
        case .claude: Color(red: 0.96, green: 0.91, blue: 0.84)
        }
    }
    var foregroundColor: Color {
        switch self {
        case .openAI, .gemini, .claude: Color(red: 0.10, green: 0.10, blue: 0.11)
        case .grok: .white
        }
    }
    var borderColor: Color {
        switch self {
        case .openAI: .black.opacity(0.14)
        case .gemini: Color(red: 0.25, green: 0.52, blue: 0.96).opacity(0.32)
        case .grok: .black
        case .claude: Color(red: 0.78, green: 0.38, blue: 0.22).opacity(0.35)
        }
    }
    var captionSource: CaptionSource {
        switch self {
        case .openAI: .chatGPT
        case .gemini: .gemini
        case .grok: .grok
        case .claude: .claude
        }
    }
}

/// 미디어·카메라 버튼 짝을 위한 차콜 표면 + 크롬 테두리 + 레드 아이콘 강조 스타일.
private struct ComposerToolButtonStyle: ButtonStyle {
    @Environment(\.brandTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(BrandTheme.carbon, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(theme.chrome.opacity(0.55), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}

private enum AIChoice: Identifiable, CaseIterable, Equatable {
    case appleIntelligence
    case external(ExternalAIProvider)

    static let allCases: [AIChoice] = [
        .external(.gemini),
        .external(.openAI),
        .external(.claude),
        .appleIntelligence
    ]

    var id: String {
        switch self {
        case .appleIntelligence: "apple-ai"
        case let .external(provider): provider.id
        }
    }

    var title: String {
        switch self {
        case .appleIntelligence: "AI"
        case let .external(provider): provider.title
        }
    }

    var actionTitle: String {
        switch self {
        case .appleIntelligence: "AI로 만들기"
        case let .external(provider): "\(provider.title)에서 만들기"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .appleIntelligence: "이 기기 안에서 게시물을 만듭니다"
        case let .external(provider): "앱 안에서 \(provider.title)을 열어 게시물을 만듭니다"
        }
    }

    @ViewBuilder
    var icon: some View {
        switch self {
        case .appleIntelligence:
            Image(systemName: "apple.logo")
                .font(.system(size: 29, weight: .semibold))
        case let .external(provider):
            if let assetName = provider.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: provider.symbolName)
                    .font(.system(size: 28, weight: .semibold))
            }
        }
    }

    var foregroundColor: Color {
        switch self {
        case .appleIntelligence: .white
        case let .external(provider): provider.foregroundColor
        }
    }

    var backgroundColor: Color {
        switch self {
        case .appleIntelligence: BrandTheme.accent
        case let .external(provider): provider.backgroundColor
        }
    }

    var borderColor: Color {
        switch self {
        case .appleIntelligence: BrandTheme.accent
        case let .external(provider): provider.borderColor
        }
    }
}

private enum CaptionSource: String, CaseIterable, Identifiable, Hashable {
    case device
    case deterministic
    case chatGPT
    case gemini
    case grok
    case claude

    var id: String { rawValue }
    var title: String {
        switch self {
        case .device: "아이폰 AI"
        case .deterministic: "기본 생성"
        case .chatGPT: "ChatGPT"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .claude: "Claude"
        }
    }
    var symbolName: String {
        switch self {
        case .device: "apple.intelligence"
        case .deterministic: "iphone"
        case .chatGPT: "bubble.left.and.text.bubble.right"
        case .gemini: "diamond"
        case .grok: "xmark"
        case .claude: "sparkles"
        }
    }
}

private struct CaptionCandidate: Identifiable, Equatable {
    var id: CaptionSource { source }
    let source: CaptionSource
    let post: GeneratedPost
    let signature: DraftSignature
    let requestID: UUID
}

private struct StarImagePlaygroundModifier: ViewModifier {
    @Binding var isPresented: Bool
    let prompt: String
    let onCompletion: (URL) -> Void
    let onCancellation: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
#if canImport(ImagePlayground)
        if #available(iOS 18.1, *) {
            content.imagePlaygroundSheet(
                isPresented: $isPresented,
                concept: prompt,
                onCompletion: onCompletion,
                onCancellation: onCancellation
            )
        } else {
            content
        }
#else
        content
#endif
    }
}

private extension View {
    /// 하단 탭 보내기 상태 동기화를 별도의 작은 제네릭 함수로 분리해, 거대한 `body` 표현식 하나에
    /// 모든 `onChange`를 이어 붙일 때 발생하는 타입 체커 시간 초과를 피한다.
    func composerNavSync(
        hasSendableContentKey: Bool,
        hasShareableContentKey: Bool,
        availabilitySignature: String,
        update: @escaping () -> Void,
        sendTrigger: UUID?,
        onSend: @escaping (UUID) -> Void,
        instagramShareTrigger: UUID?,
        onInstagramShare: @escaping (UUID) -> Void
    ) -> some View {
        onChange(of: hasSendableContentKey, initial: true) { _, _ in update() }
            .onChange(of: hasShareableContentKey, initial: true) { _, _ in update() }
            .onChange(of: availabilitySignature, initial: true) { _, _ in update() }
            .onChange(of: sendTrigger) { _, requestID in
                guard let requestID else { return }
                onSend(requestID)
            }
            .onChange(of: instagramShareTrigger) { _, requestID in
                guard let requestID else { return }
                onInstagramShare(requestID)
            }
    }

    /// 진행 카드로의 스크롤 트리거를 별도 함수로 분리해, 거대한 `body` 표현식의 타입 체커 시간 초과를 피한다.
    func composerProgressScrollSync(
        isGenerating: Bool,
        proxy: ScrollViewProxy,
        onReveal: @escaping () -> Void
    ) -> some View {
        onChange(of: isGenerating) { _, generating in
            guard generating else { return }
            onReveal()
            Task { @MainActor in
                await Task.yield()
                withAnimation(.snappy(duration: 0.32)) {
                    proxy.scrollTo("bottom-action-scroll-target", anchor: .bottom)
                }
            }
        }
    }

    func composerAIChoiceScrollSync(
        trigger: UUID?,
        proxy: ScrollViewProxy,
        onReveal: @escaping () -> Void
    ) -> some View {
        onChange(of: trigger) { _, requestID in
            guard requestID != nil else { return }
            onReveal()
            Task { @MainActor in
                await Task.yield()
                withAnimation(.snappy(duration: 0.32)) {
                    proxy.scrollTo("bottom-action-scroll-target", anchor: .bottom)
                }
            }
        }
    }

    func starImagePlaygroundSheet(
        isPresented: Binding<Bool>,
        prompt: String,
        onCompletion: @escaping (URL) -> Void,
        onCancellation: @escaping () -> Void
    ) -> some View {
        modifier(StarImagePlaygroundModifier(
            isPresented: isPresented,
            prompt: prompt,
            onCompletion: onCompletion,
            onCancellation: onCancellation
        ))
    }
}

private struct MediaPreview: View {
    let items: [ComposerMedia]
    let aspect: CGFloat
    let isLoading: Bool

    @Environment(\.brandTheme) private var theme

    var body: some View {
        ZStack {
            theme.paper
            if isLoading {
                ProgressView("미디어 불러오는 중")
            } else if !items.isEmpty {
                TabView {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, media in
                        ZStack(alignment: .topTrailing) {
                            if media.kind == .image, let image = UIImage(data: media.data) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                VStack(spacing: 10) {
                                    Image(systemName: "play.rectangle.fill").font(.system(size: 42))
                                    Text("영상").font(.subheadline.weight(.medium))
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .foregroundStyle(theme.ink)
                            }
                            Text("\(index + 1)/\(items.count)")
                                .font(.caption.bold())
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(12)
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34))
                    Text("불러오는 중").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.quaternary) }
        .clipped()
        .accessibilityLabel(items.isEmpty ? "미디어 준비 중" : "선택한 미디어 \(items.count)개 미리보기")
    }
}

private struct ComposerMedia: Identifiable, Sendable {
    let id = UUID()
    let data: Data
    let kind: MediaKind
    let fileExtension: String?
    let generatedFromPostID: UUID?

    init(
        data: Data,
        kind: MediaKind,
        fileExtension: String?,
        generatedFromPostID: UUID? = nil
    ) {
        self.data = data
        self.kind = kind
        self.fileExtension = fileExtension
        self.generatedFromPostID = generatedFromPostID
    }
}

private enum MediaKind: String, Sendable {
    case image
    case video

    var title: String { self == .image ? "사진" : "영상" }
    var symbolName: String { self == .image ? "photo.fill" : "video.fill" }
}

private struct MediaThumbnail: View {
    let media: ComposerMedia
    @Environment(\.brandTheme) private var theme
    @State private var videoThumbnailData: Data?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            thumbnail
                .frame(width: 104, height: 118)
                .background(theme.paper)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.black.opacity(0.09), lineWidth: 1)
                }
                .clipped()

            Image(systemName: media.kind.symbolName)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.66), in: Circle())
                .padding(7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: media.id) {
            guard media.kind == .video, videoThumbnailData == nil else { return }
            videoThumbnailData = await Self.makeVideoThumbnailData(for: media)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if media.kind == .image, let image = UIImage(data: media.data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let videoThumbnailData, let image = UIImage(data: videoThumbnailData) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                theme.canvas
                ProgressView()
            }
        }
    }

    private nonisolated static func makeVideoThumbnailData(for media: ComposerMedia) async -> Data? {
        await Task.detached(priority: .utility) {
            let ext = media.fileExtension?.isEmpty == false ? media.fileExtension! : "mov"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("imanagerai-thumb-\(media.id.uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try media.data.write(to: url)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 320)
                let image = try generator.copyCGImage(at: .zero, actualTime: nil)
                return UIImage(cgImage: image).jpegData(compressionQuality: 0.72)
            } catch {
                return nil
            }
        }.value
    }
}

private struct MediaReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var mediaItems: [ComposerMedia]
    @Binding var draggedMediaID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedMediaID,
              draggedMediaID != targetID,
              let sourceIndex = mediaItems.firstIndex(where: { $0.id == draggedMediaID }),
              let targetIndex = mediaItems.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.snappy) {
            mediaItems.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedMediaID = nil
        return true
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
    let cleanupURLs: [URL]
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let maxCount: Int
    let currentCount: Int
    let onFinish: ([Data]) -> Void
    let onPhotoLibrarySaveIssue: () -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        if UIImagePickerController.isFlashAvailable(for: picker.cameraDevice) {
            picker.cameraFlashMode = .off
        }
        picker.showsCameraControls = false
        picker.delegate = context.coordinator
        picker.cameraOverlayView = context.coordinator.makeOverlay(for: picker)
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView
        private weak var picker: UIImagePickerController?
        private weak var countLabel: UILabel?
        private weak var doneButton: UIButton?
        private weak var cancelButton: UIButton?
        private weak var shutterButton: UIButton?
        private weak var flipButton: UIButton?
        private weak var flashButton: UIButton?
        private var pendingPhotos: [Data] = []
        private var isCapturing = false
        private var finishRequested = false
        private var isCancelled = false
        private var didFinish = false
        private var didReportPhotoSaveIssue = false

        init(parent: CameraCaptureView) {
            self.parent = parent
        }

        func makeOverlay(for picker: UIImagePickerController) -> UIView {
            self.picker = picker
            let overlay = CameraOverlayView(frame: picker.view.bounds)
            overlay.backgroundColor = .clear
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            let doneButton = UIButton(type: .system)
            doneButton.setTitle("완료", for: .normal)
            doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            doneButton.setTitleColor(.white, for: .normal)
            doneButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            doneButton.layer.cornerRadius = 18
            doneButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
            doneButton.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
            doneButton.translatesAutoresizingMaskIntoConstraints = false
            doneButton.accessibilityLabel = "촬영 완료"
            doneButton.accessibilityHint = "찍은 사진을 촬영 순서대로 미디어에 추가하고 카메라를 닫습니다"
            self.doneButton = doneButton

            let cancelButton = UIButton(type: .system)
            cancelButton.setTitle("취소", for: .normal)
            cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            cancelButton.setTitleColor(.white, for: .normal)
            cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            cancelButton.layer.cornerRadius = 18
            cancelButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
            cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
            cancelButton.translatesAutoresizingMaskIntoConstraints = false
            cancelButton.accessibilityLabel = "촬영 취소"
            cancelButton.accessibilityHint = "이번 촬영에서 찍은 사진을 추가하지 않고 카메라를 닫습니다"
            self.cancelButton = cancelButton

            let label = UILabel()
            label.textColor = .white
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textAlignment = .center
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 14
            label.layer.masksToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            countLabel = label
            updateLabel()

            let shutterButton = UIButton(type: .custom)
            shutterButton.backgroundColor = .white
            shutterButton.layer.cornerRadius = 36
            shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
            shutterButton.layer.borderWidth = 6
            shutterButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
            shutterButton.translatesAutoresizingMaskIntoConstraints = false
            shutterButton.accessibilityLabel = "사진 촬영"
            self.shutterButton = shutterButton

            let flipButton = iconButton(systemName: "camera.rotate.fill", accessibilityLabel: "카메라 전환")
            flipButton.addTarget(self, action: #selector(flipCameraTapped), for: .touchUpInside)
            flipButton.isHidden = !Self.canFlipCamera
            self.flipButton = flipButton

            let flashButton = iconButton(systemName: "bolt.slash.fill", accessibilityLabel: "플래시 켜기")
            flashButton.addTarget(self, action: #selector(toggleFlashTapped), for: .touchUpInside)
            flashButton.isHidden = !UIImagePickerController.isFlashAvailable(for: picker.cameraDevice)
            self.flashButton = flashButton

            overlay.addSubview(doneButton)
            overlay.addSubview(cancelButton)
            overlay.addSubview(label)
            overlay.addSubview(shutterButton)
            overlay.addSubview(flipButton)
            overlay.addSubview(flashButton)

            NSLayoutConstraint.activate([
                doneButton.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 12),
                doneButton.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -16),

                cancelButton.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 12),
                cancelButton.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 16),

                label.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                cancelButton.trailingAnchor.constraint(lessThanOrEqualTo: label.leadingAnchor, constant: -8),
                label.trailingAnchor.constraint(lessThanOrEqualTo: doneButton.leadingAnchor, constant: -8),
                label.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
                label.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),

                shutterButton.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                shutterButton.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -24),
                shutterButton.widthAnchor.constraint(equalToConstant: 72),
                shutterButton.heightAnchor.constraint(equalTo: shutterButton.widthAnchor),

                flipButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
                flipButton.trailingAnchor.constraint(equalTo: shutterButton.leadingAnchor, constant: -42),
                flipButton.widthAnchor.constraint(equalToConstant: 48),
                flipButton.heightAnchor.constraint(equalTo: flipButton.widthAnchor),

                flashButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
                flashButton.leadingAnchor.constraint(equalTo: shutterButton.trailingAnchor, constant: 42),
                flashButton.widthAnchor.constraint(equalToConstant: 48),
                flashButton.heightAnchor.constraint(equalTo: flashButton.widthAnchor)
            ])

            return overlay
        }

        private func updateLabel() {
            let totalCount = parent.currentCount + pendingPhotos.count
            countLabel?.text = "  \(totalCount)/\(parent.maxCount)  "
            countLabel?.accessibilityLabel = "미디어 \(totalCount)개, 최대 \(parent.maxCount)개"
        }

        @objc private func finishTapped() {
            guard !isCancelled, !didFinish else { return }
            if isCapturing, !finishRequested {
                finishRequested = true
                updateControls()
            } else {
                // 촬영 콜백이 오지 않아도 두 번째 탭으로 지금까지 찍은 사진을 커밋할 수 있다.
                finish()
            }
        }

        @objc private func cancelTapped() {
            guard !didFinish else { return }
            isCancelled = true
            pendingPhotos.removeAll()
            updateControls()
            parent.dismiss()
        }

        @objc private func captureTapped() {
            guard !isCapturing, !finishRequested, !isCancelled,
                  parent.currentCount + pendingPhotos.count < parent.maxCount,
                  let picker else { return }
            isCapturing = true
            updateControls()
            picker.takePicture()
        }

        @objc private func flipCameraTapped() {
            guard !isCapturing, !finishRequested, !isCancelled, let picker else { return }
            picker.cameraDevice = picker.cameraDevice == .rear ? .front : .rear
            if UIImagePickerController.isFlashAvailable(for: picker.cameraDevice) {
                picker.cameraFlashMode = .off
            }
            updateFlashButton()
        }

        @objc private func toggleFlashTapped() {
            guard !isCapturing, !finishRequested, !isCancelled, let picker else { return }
            guard UIImagePickerController.isFlashAvailable(for: picker.cameraDevice) else {
                updateFlashButton()
                return
            }
            picker.cameraFlashMode = picker.cameraFlashMode == .off ? .on : .off
            updateFlashButton()
        }

        private func updateFlashButton() {
            guard let picker, let flashButton else { return }
            let isAvailable = UIImagePickerController.isFlashAvailable(for: picker.cameraDevice)
            flashButton.isHidden = !isAvailable
            let isOn = isAvailable && picker.cameraFlashMode == .on
            flashButton.setImage(UIImage(systemName: isOn ? "bolt.fill" : "bolt.slash.fill"), for: .normal)
            flashButton.accessibilityLabel = isOn ? "플래시 끄기" : "플래시 켜기"
        }

        private func updateControls() {
            let isBusy = isCapturing || finishRequested || isCancelled || didFinish
            doneButton?.isEnabled = !isCancelled && !didFinish
            cancelButton?.isEnabled = !isCancelled && !didFinish
            shutterButton?.isEnabled = !isBusy && parent.currentCount + pendingPhotos.count < parent.maxCount
            flipButton?.isEnabled = !isBusy
            flashButton?.isEnabled = !isBusy
        }

        private func finish() {
            guard !isCancelled, !didFinish else { return }
            didFinish = true
            updateControls()
            parent.onFinish(pendingPhotos)
            pendingPhotos.removeAll()
            parent.dismiss()
        }

        private func iconButton(systemName: String, accessibilityLabel: String) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: systemName), for: .normal)
            button.tintColor = .white
            button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            button.layer.cornerRadius = 24
            button.translatesAutoresizingMaskIntoConstraints = false
            button.accessibilityLabel = accessibilityLabel
            return button
        }

        private static var canFlipCamera: Bool {
            UIImagePickerController.isCameraDeviceAvailable(.rear) &&
                UIImagePickerController.isCameraDeviceAvailable(.front)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.92)
            // 취소·완료 뒤 늦게 도착한 콜백이어도 이미 찍힌 사진은 보관함에 남긴다.
            if let data {
                saveToPhotoLibrary(data)
            }
            guard !isCancelled, !didFinish else { return }
            if let data, parent.currentCount + pendingPhotos.count < parent.maxCount {
                pendingPhotos.append(data)
            }
            isCapturing = false
            updateLabel()
            updateControls()
            if finishRequested {
                finish()
            }
        }

        private func saveToPhotoLibrary(_ data: Data) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                guard status == .authorized || status == .limited else {
                    Task { @MainActor in self?.reportPhotoSaveIssueOnce() }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }) { success, _ in
                    guard !success else { return }
                    Task { @MainActor in self?.reportPhotoSaveIssueOnce() }
                }
            }
        }

        private func reportPhotoSaveIssueOnce() {
            guard !didReportPhotoSaveIssue else { return }
            didReportPhotoSaveIssue = true
            parent.onPhotoLibrarySaveIssue()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            cancelTapped()
        }
    }
}

private final class CameraOverlayView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }
}

private struct KeyboardDismissTapInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async { context.coordinator.install(from: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { context.coordinator.install(from: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        func install(from view: UIView) {
            guard let window = view.window, installedWindow !== window else { return }
            uninstall()
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            installedWindow = window
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer { installedWindow?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            installedWindow = nil
        }

        @objc private func dismissKeyboard() {
            installedWindow?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    let cleanupURLs: [URL]
    let onCompletion: (Bool, Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            for url in cleanupURLs { try? FileManager.default.removeItem(at: url) }
            onCompletion(completed, error)
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private extension UIApplication {
    /// 테마(기본 BK 또는 클래식/인터스텔라 대체 아이콘)에 맞는 일반 툴바 이미지 에셋을 읽어 온다.
    func iManagerAIIcon(for style: AppearanceStyle = .bk) -> UIImage? {
        let assetName: String
        switch style {
        case .bk:
            assetName = "AppIconToolbarBK"
        case .classic:
            assetName = "AppIconToolbarClassic"
        case .interstellar:
            assetName = "AppIconToolbarInterstellar"
        }

        if let image = UIImage(named: assetName) {
            return image
        }

        // 예기치 않게 이미지가 없을 경우 BK 일반 툴바 아이콘 에셋을 사용
        if let bkImage = UIImage(named: "AppIconToolbarBK") {
            return bkImage
        }

        return nil
    }

    var iManagerAIIcon: UIImage? {
        iManagerAIIcon(for: .bk)
    }
}

private enum MediaLoadError: Error { case empty }

/// Home Screen "자동화" 퀵 액션 전용 전체 화면 표면의 상태. 진행 중에는 링만, 완료·실패 시에만 결과/오류 화면을 보여준다.
private enum AutomationSurfaceState: Equatable {
    case processing
    case result(String)
    case failure(String)
}

private enum AutomationRelayState: Equatable {
    case preparing
    case sending
    case waiting

    var message: String {
        switch self {
        case .preparing: "미디어 준비 중"
        case .sending: "보내는 중"
        case .waiting: "보냈음 · 답변 기다림"
        }
    }
}

/// 자동화 퀵 액션 흐름 전용 전체 화면. 제공자 이름·단계 텍스트·카운트다운·컴포저 카드/탭/툴바 등은 절대 노출하지 않는다.
private struct AutomationSurfaceView: View {
    let theme: BrandTheme
    let state: AutomationSurfaceState
    let relayMessage: String
    let resultImages: [Data]
    let isPreparingShare: Bool
    let activeChoice: AIProviderIdentity
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onShare: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Image("AutomationInterstellarBackdrop")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay(Color.black.opacity(0.08))
            }
            .ignoresSafeArea()

            // 배경 하단의 AI 유리 버튼이 현재 제공자 표시와 자동화 닫기를 함께 담당한다.
            VStack {
                Spacer()
                Button(action: onCancel) {
                    selectedProviderGlassIcon
                }
                .buttonStyle(.plain)
                .accessibilityLabel("자동화 취소")
                .accessibilityHint("현재 AI 표시가 있는 유리 버튼을 눌러 자동화를 취소합니다")
            }

            switch state {
            case .processing:
                processingContent
            case let .result(text):
                resultContent(text: text)
            case let .failure(message):
                failureContent(message: message)
            }

            VStack {
                IManagerAISignatureTitle()
                    .padding(.top, 72)
                Spacer()
            }
        }
        .statusBarHidden()
    }

    /// 사각 로고 타일을 다시 원 안에 넣지 않고, 로고 자체를 곧바로 원형으로 잘라 유리 표면으로 만든다.
    private var selectedProviderGlassIcon: some View {
        ZStack {
            Color.clear
                .frame(width: 50, height: 50)
                .automationProviderGlass()
                .opacity(0.28)

            providerStatusLogo
                .opacity(0.72)

            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
                .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        }
            .frame(width: 50, height: 50)
            .padding(.bottom, 34)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var providerStatusLogo: some View {
        if activeChoice == .device {
            Image(systemName: "apple.logo")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white)
        } else {
            activeChoice.tabIcon
                .frame(width: 42, height: 42)
                .clipShape(Circle())
        }
    }

    private var processingContent: some View {
        ZStack {
            AutomationProgressRing()

            EngineFlareFlyby()

            Text(relayMessage)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: relayMessage)
                .offset(y: 82)
                .accessibilityLabel("자동화 상태")
                .accessibilityValue(relayMessage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultContent(text: String) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 136)

            Spacer(minLength: 4)

            if !resultImages.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(resultImages.enumerated()), id: \.offset) { index, data in
                        AutomationResultThumbnail(data: data, index: index)
                            .frame(width: 40, height: 40)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .offset(y: -5)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            ScrollView {
                Text(text)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(
                        Color.black.opacity(0.46),
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.42),
                                        Color(red: 1.0, green: 0.43, blue: 0.48).opacity(0.7),
                                        Color(red: 0.68, green: 0.42, blue: 1.0).opacity(0.46)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.2
                            )
                    }
                    .shadow(color: .black.opacity(0.34), radius: 24, y: 12)
                    .accessibilityLabel("만든 글")
                    .accessibilityValue(text)
            }
            .frame(maxHeight: resultPanelMaxHeight)
            .padding(.horizontal, 20)

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                Button(action: onShare) {
                    HStack {
                        if isPreparingShare { ProgressView().tint(.white) }
                        Label(
                            isPreparingShare ? "보낼 준비 중" : "Instagram으로 보내기",
                            systemImage: "arrow.up.forward"
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(InstagramVoyageButtonStyle())
                .disabled(isPreparingShare)
                .accessibilityHint("문구와 미디어를 Instagram으로 보낼 화면을 엽니다")

                HStack(spacing: 10) {
                    Button(action: onClose) {
                        Label("취소", systemImage: "xmark")
                    }
                    .buttonStyle(AutomationGlassButtonStyle())
                    .accessibilityHint("결과 화면을 닫고 스튜디오로 돌아갑니다")

                    Button(action: onRetry) {
                        Label("다시 만들기", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(AutomationGlassButtonStyle())
                    .disabled(isPreparingShare)
                    .accessibilityHint("같은 사진으로 다른 AI에게 새로 요청합니다")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    private var resultPanelMaxHeight: CGFloat {
        resultImages.isEmpty ? 480 : 390
    }

    private func failureContent(message: String) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(BrandTheme.accent)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.94))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .accessibilityLabel("자동화 실패")
                .accessibilityValue(message)
            Spacer()
            VStack(spacing: 10) {
                Button(action: onRetry) {
                    Label("다시 시도", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlossyPrimaryButtonStyle())
                .accessibilityHint("같은 사진으로 다른 AI에게 새로 요청합니다")

                Button(action: onClose) {
                    Text("닫기")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                }
                .accessibilityLabel("자동화 닫기")
                .accessibilityHint("자동화 화면을 닫고 스튜디오로 돌아갑니다")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }
}

private struct AutomationResultThumbnail: View {
    let data: Data
    let index: Int

    var body: some View {
        Group {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.08)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.65))
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.42), BrandTheme.accent.opacity(0.56)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
        .accessibilityLabel("입력 사진 \(index + 1)")
    }
}

private struct IManagerAISignatureTitle: View {
    var body: some View {
        Text("Stargram")
            .font(.custom("SnellRoundhand-Bold", size: 38, relativeTo: .largeTitle))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        .white,
                        Color(red: 1.0, green: 0.75, blue: 0.65),
                        Color(red: 1.0, green: 0.42, blue: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .shadow(color: Color(red: 1.0, green: 0.36, blue: 0.45).opacity(0.72), radius: 14)
            .shadow(color: .black.opacity(0.65), radius: 3, y: 2)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct InstagramVoyageButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.42, green: 0.22, blue: 0.84),
                        Color(red: 0.86, green: 0.16, blue: 0.52),
                        Color(red: 1.0, green: 0.43, blue: 0.28)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: Capsule()
            )
            .overlay { Capsule().stroke(.white.opacity(0.34), lineWidth: 1) }
            .shadow(color: Color(red: 0.92, green: 0.22, blue: 0.48).opacity(0.48), radius: 18, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct AutomationGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.95))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.black.opacity(0.46), in: Capsule())
            .overlay {
                Capsule().stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.34), BrandTheme.accent.opacity(0.48)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private extension View {
    @ViewBuilder
    func automationProviderGlass() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// 출발점부터 현재 위치까지 빛의 항로가 차오르며 포털을 통과하는 엔진 불꽃.
/// 한 번의 비행 뒤에는 잠시 쉬어, 계속 움직이면서도 진행 화면을 산만하게 만들지 않는다.
private struct EngineFlareFlyby: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    private let flightDuration = 40.0
    private let passageCount = 3

    var body: some View {
        GeometryReader { proxy in
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    let totalElapsed = timeline.date.timeIntervalSince(startedAt)
                    let totalDuration = flightDuration * Double(passageCount)
                    let isWithinPassages = totalElapsed < totalDuration
                    let elapsed = totalElapsed.truncatingRemainder(dividingBy: flightDuration)
                    let progress = CGFloat(min(max(elapsed / flightDuration, 0), 1))
                    let fade = isWithinPassages ? 1.0 : 0.0
                    let horizontalSpan = proxy.size.width + 56
                    let originalVerticalSpan = -proxy.size.height * 0.28
                    let originalAngle = atan2(originalVerticalSpan, horizontalSpan)
                    let quarterAngle = originalAngle / 4
                    let verticalSpan = tan(quarterAngle) * horizontalSpan
                    let centerY = proxy.size.height / 2
                    let start = CGPoint(x: -28, y: centerY - verticalSpan / 2)
                    let end = CGPoint(x: proxy.size.width + 28, y: centerY + verticalSpan / 2)
                    let current = CGPoint(
                        x: start.x + (end.x - start.x) * progress,
                        y: start.y + (end.y - start.y) * progress
                    )
                    let angle = Angle(radians: quarterAngle)

                    ZStack {
                        Canvas { context, _ in
                            var path = Path()
                            path.move(to: start)
                            path.addLine(to: current)

                            let trail = GraphicsContext.Shading.linearGradient(
                                Gradient(colors: [
                                    .clear,
                                    Color.white.opacity(0.16),
                                    Color(red: 1.0, green: 0.64, blue: 0.28).opacity(0.55),
                                    Color(red: 0.78, green: 0.88, blue: 1.0).opacity(0.88),
                                    .white
                                ]),
                                startPoint: start,
                                endPoint: current
                            )

                            var glowContext = context
                            glowContext.addFilter(.blur(radius: 8))
                            glowContext.stroke(
                                path,
                                with: trail,
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            context.stroke(
                                path,
                                with: trail,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                            )
                        }
                        .opacity(fade)

                        EngineFlareGlyph()
                            .rotationEffect(angle)
                            .position(current)
                            .opacity(fade)
                    }
                }
            }
        }
        .onAppear { startedAt = Date() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct EngineFlareGlyph: View {
    var body: some View {
        ZStack(alignment: .trailing) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            Color(red: 1.0, green: 0.62, blue: 0.24).opacity(0.42),
                            Color(red: 0.76, green: 0.88, blue: 1.0).opacity(0.82),
                            .white
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 58, height: 5)
                .shadow(color: Color(red: 1.0, green: 0.68, blue: 0.3).opacity(0.76), radius: 9)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.72)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 42, height: 1.5)
                .offset(y: 4)

            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
                .shadow(color: Color(red: 0.78, green: 0.9, blue: 1.0), radius: 7)
        }
        .frame(width: 64, height: 16)
    }
}

/// 단계 문구 없이, 지금 요청 중인 AI의 아이콘이 링을 따라 계속 공전하며 작업 중임을 보여주는 원형 진행 링.
private struct AutomationProgressRing: View {
    @State private var rotationAngle: Double = 0
    @State private var rotationDirection: Double = 1

    var body: some View {
        ZStack {
            Image("AutomationBlackHole")
                .resizable()
                .scaledToFit()
                .frame(width: 188, height: 150)

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.13), lineWidth: 1.5)

                Circle()
                    .trim(from: 0.08, to: 0.8)
                    .stroke(
                        AngularGradient(
                            colors: [
                                .clear,
                                .white,
                                Color(red: 1.0, green: 0.82, blue: 0.5),
                                Color(red: 1.0, green: 0.58, blue: 0.24),
                                .clear
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .shadow(color: Color(red: 1.0, green: 0.68, blue: 0.32).opacity(0.9), radius: 7)
            }
            .frame(width: 48, height: 48)
            .rotationEffect(.degrees(rotationAngle))

        }
            .frame(width: 188, height: 150)
            .accessibilityHidden(true)
            .task {
                rotationAngle = Double.random(in: 0..<360)
                rotationDirection = Bool.random() ? 1 : -1

                while !Task.isCancelled {
                    let speedFactor = Double.random(in: 0.4...0.9)
                    let revolutionDuration = 1.1 / speedFactor
                    withAnimation(.linear(duration: revolutionDuration)) {
                        rotationAngle += rotationDirection * 360
                    }
                    do {
                        try await Task.sleep(for: .seconds(revolutionDuration))
                    } catch {
                        break
                    }
                }
            }
    }
}

#Preview {
    NavigationStack { ComposerView() }
        .environmentObject(CreatorProfileStore())
        .environmentObject(DirectAIConfigurationStore())
        .environmentObject(AutomationCoordinator.shared)
        .environmentObject(AIProviderAvailabilityStore())
        .environmentObject(AIRunMetricsStore())
        .environmentObject(ComposerNavState())
}
