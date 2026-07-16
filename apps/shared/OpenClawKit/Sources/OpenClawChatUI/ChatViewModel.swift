import Foundation
import Observation
import OpenClawKit
import OSLog

private let chatUILogger = Logger(subsystem: "ai.openclaw", category: "OpenClawChatUI")

@MainActor
@Observable
public final class OpenClawChatViewModel {
    public nonisolated static let defaultModelSelectionID = "__default__"
    static let maxAttachmentBytes = 5_000_000
    static let sessionListFetchLimit = 200

    public internal(set) var messages: [OpenClawChatMessage] = []

    public var input: String = ""
    /// Setter is module-internal for the thinking-level extension only.
    public internal(set) var thinkingLevel: String
    /// User intent stays stable while `thinkingLevel` follows the selected model's advertised levels.
    var preferredThinkingLevel: String
    /// Setter is module-internal for the thinking-level extension only.
    public internal(set) var thinkingLevelOptions: [OpenClawChatThinkingLevelOption]
    /// Setter is module-internal for the thinking-level extension only.
    public internal(set) var showsThinkingPicker = true
    public private(set) var modelSelectionID: String = "__default__"
    public private(set) var modelChoices: [OpenClawChatModelChoice] = []
    private var modelPickerFavorites: [String]
    private var modelPickerRecents: [String]
    /// Setters are module-internal for the sending extension's command catalog.
    public internal(set) var slashCommands: [OpenClawChatCommandChoice] = []
    public internal(set) var isLoadingSlashCommands = false
    public internal(set) var slashCommandsErrorText: String?
    public internal(set) var hasLoadedSlashCommands = false
    @ObservationIgnored
    var slashFilterCache: SlashFilterCache?

    struct SlashFilterCache {
        let query: String
        let filter: OpenClawChatCommandFilter
        let result: [OpenClawChatCommandChoice]
    }

    private struct DeferredDeliveryIdentity {
        let activeAgentID: String?
        let sessionRoutingContract: String?
    }

    public private(set) var isLoading = false
    /// Setters are module-internal for the sending extension only.
    public internal(set) var isSending = false
    public internal(set) var isSendingAttachmentDraft = false
    private var deferredExternalSessionKey: String?
    private var deferredDeliveryIdentity: DeferredDeliveryIdentity?
    var isSubmittingDraft = false
    private var attachmentStagingCount = 0
    public private(set) var isAborting = false
    public var errorText: String?
    public var attachments: [OpenClawPendingAttachment] = []
    /// Setter is module-internal for the health/outbox extension only.
    public internal(set) var healthOK: Bool = false

    /// True when this view model owns a gateway-scoped durable text outbox.
    public var supportsOfflineTextOutbox: Bool {
        outbox != nil
    }

    public private(set) var pendingRunCount: Int = 0
    private(set) var hasActiveSessionRunWithoutChatSnapshot = false

    public private(set) var sessionKey: String {
        didSet { syncContextUsageFraction() }
    }

    public private(set) var sessionId: String?
    public private(set) var streamingAssistantText: String?

    public private(set) var pendingToolCalls: [OpenClawChatPendingToolCall] = []
    public internal(set) var planSteps: [OpenClawChatPlanStep] = []
    public internal(set) var planExplanation: String?
    var planRunId: String?

    private(set) var timelineRevision: UInt64 = 0
    /// Setter is module-internal for the transcript-cache extension only.
    public internal(set) var sessions: [OpenClawChatSessionEntry] = [] {
        didSet { syncContextUsageFraction() }
    }

    public internal(set) var contextUsageFraction: Double?
    /// True while the visible transcript came from the offline cache and no
    /// live history response has replaced it yet (possibly stale).
    public internal(set) var isShowingCachedTranscript = false
    /// Guard the cache pre-paint: once a live response applied (even an empty
    /// one), a slow cache read must never paint stale rows over it.
    var hasAppliedLiveHistory = false
    var hasAppliedLiveSessions = false
    /// Internal for the outbox extension's flush path only.
    let transport: any OpenClawChatTransport
    let haptics: OpenClawChatHaptics
    let transcriptCache: (any OpenClawChatTranscriptCache)?
    let outbox: (any OpenClawChatCommandOutbox)?
    @ObservationIgnored
    private let modelPickerStore: ChatModelPickerStore
    /// Per-message outbox display state; rows without an entry are normal
    /// transcript rows. Observable so bubbles update when flush progresses.
    public internal(set) var outboxStatesByMessageID: [UUID: OpenClawChatOutboxMessageState] = [:]
    @ObservationIgnored
    var outboxCommandIDsByMessageID: [UUID: String] = [:]
    @ObservationIgnored
    var outboxMessageIDsByCommandID: [String: UUID] = [:]
    /// Recent canonical keys let the MainActor resolve proof that arrives
    /// after SQLite cancellation commits but before its UI continuation runs.
    @ObservationIgnored
    var canonicalOutboxMessageKeys: [String] = []
    @ObservationIgnored
    var isFlushingOutbox = false
    @ObservationIgnored
    var isOutboxFlushRequestedWhileActive = false
    @ObservationIgnored
    var cancelingOutboxCommandIDs: Set<String> = []
    @ObservationIgnored
    var outboxPresentationGeneration: UInt64 = 0
    @ObservationIgnored
    var outboxChangesTask: Task<Void, Never>?
    /// Backoff between failed flush attempts; internal so tests can shorten it.
    @ObservationIgnored
    var outboxRetryDelaysMs: [UInt64] = [2000, 8000]
    /// False until restoreOutboxMessages has adopted durable rows for the
    /// visible session. Until then the in-memory outbox state is blind to
    /// rows persisted by an earlier process, so the FIFO send gate must
    /// assume a backlog exists.
    @ObservationIgnored
    var hasRestoredOutboxMessages = false
    @ObservationIgnored
    nonisolated(unsafe) var outboxRetryTask: Task<Void, Never>?
    /// A command becomes terminally 'failed' after this many send attempts.
    nonisolated static let maxOutboxSendAttempts = 3
    @ObservationIgnored
    var pendingCacheWriteTask: Task<Void, Never>?
    private(set) var activeAgentId: String?
    private(set) var sessionRoutingContract: String?
    var sessionDefaults: OpenClawChatSessionsDefaults? {
        didSet { syncContextUsageFraction() }
    }

    var prefersExplicitThinkingLevel: Bool
    private let onSessionChanged: (@MainActor (String) -> Void)?
    let onThinkingLevelChanged: (@MainActor @Sendable (String) -> Void)?
    private let diagnosticsLog: (@MainActor @Sendable (String) -> Void)?
    private let attachmentOwnerIsActive: @MainActor () -> Bool

    @ObservationIgnored
    private nonisolated(unsafe) var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private nonisolated(unsafe) var bootstrapTask: Task<Void, Never>?
    var runOwnershipGeneration: UInt64 = 0
    var latestAppliedRunSnapshotRequestID: UInt64 = 0
    private var isApplyingRunSnapshot = false
    var pendingRuns = Set<String>() {
        didSet {
            if self.pendingRuns != oldValue, !self.isApplyingRunSnapshot {
                self.runOwnershipGeneration &+= 1
            }
            let nextCount = self.pendingRuns.count
            guard nextCount != self.pendingRunCount else { return }
            self.pendingRunCount = nextCount
            self.markTimelineChanged()
        }
    }

    var pendingLocalUserEchoMessageIDsByRunID: [String: UUID] = [:]
    // Final chat events and durable session-message rows arrive independently.
    // Keep each provisional final scoped to the run's user turn so a later identical
    // answer in the same session does not adopt or suppress the wrong row.
    var runMessageScopesByRunID: [String: RunMessageScope] = [:]
    var provisionalFinalMessagesByID: [UUID: ProvisionalFinalMessage] = [:]
    private var sessionGeneration: UInt64 = 0
    private var bootstrapGeneration: UInt64 = 0
    // A newer same-session history request only invalidates older responses after it applies.
    // Failed later refreshes must not drop the last successful pending-run history payload.
    private var lastIssuedHistoryRequestID: UInt64 = 0
    private var latestAppliedHistoryRequestID: UInt64 = 0
    private var historyMutationGeneration: UInt64 = 0
    private var nextSessionsFetchRequestID: UInt64 = 0
    private var latestAppliedSessionsFetchRequestID: UInt64 = 0
    /// Outbox replay waits for a sessions list from the current connection generation.
    var sessionMetadataGeneration: UInt64 = 0
    var readySessionMetadataGeneration: UInt64?

    @ObservationIgnored
    nonisolated(unsafe) var pendingRunOwnerTasks: [String: Task<Void, Never>] = [:]
    var nextPendingRunOwnerArmID: UInt64 = 0
    var pendingRunOwnerArmIDs: [String: UInt64] = [:]
    @ObservationIgnored
    private nonisolated(unsafe) var activeSessionRunIndicatorTimeoutTask: Task<Void, Never>?
    var pendingRunWaitTimeoutMs: UInt64 = 120_000
    var pendingRunUnavailableRetryMs: UInt64 = 30000
    var pendingRunTerminalRetryMs: UInt64 = 2000
    var pendingRunTerminalHistoryGraceMs: UInt64 = 10000
    var pendingRunRefreshDelaysMs: [UInt64] = [
        1500,
        4000,
        9000,
        20000,
        45000,
    ]
    var pendingRunSteadyRefreshDelayMs: UInt64 = 60000
    // Session switches can overlap in-flight picker patches, so stale completions
    // must compare against the latest request and latest desired value for that session.
    private var nextSessionSettingsRequestID: UInt64 = 0
    private var latestModelSelectionRequestIDsByTarget: [ModelPatchTarget: UInt64] = [:]
    private var lastSuccessfulModelSelectionIDsByTarget: [ModelPatchTarget: String] = [:]
    var lastSuccessfulSettingsPatchRequestIDsByTarget: [ModelPatchTarget: UInt64] = [:]
    /// Rollback and pre-refresh sends need the authoritative state from the latest settings patch.
    var lastSuccessfulSettingsPatchResultsByTarget: [ModelPatchTarget: OpenClawChatModelPatchResult] = [:]
    var completedModelPatchTargets: Set<ModelPatchTarget> = []
    private var inFlightSettingsPatchCountsByTarget: [ModelPatchTarget: Int] = [:]
    private var settingsPatchRevisionsByTarget: [ModelPatchTarget: UInt64] = [:]
    private var settingsPatchWaitersByTarget: [ModelPatchTarget: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored
    private var settingsPatchTailsByTarget: [ModelPatchTarget: SettingsPatchTail] = [:]
    var nextThinkingSelectionRequestID: UInt64 = 0
    var latestThinkingSelectionRequestIDsByTarget: [ModelPatchTarget: UInt64] = [:]
    var acceptedSettingsPatchResultsByTarget: [ModelPatchTarget: OpenClawChatModelPatchResult] = [:]
    var acceptedThinkingLevelsByTarget: [ModelPatchTarget: String] = [:]
    var acceptedPreferredThinkingLevelsByTarget: [ModelPatchTarget: String] = [:]
    var acceptedExplicitThinkingPreferencesByTarget: [ModelPatchTarget: Bool] = [:]
    private var isCompacting = false
    private var lastCompactAt: Date?
    private let compactCooldown: TimeInterval = 60

    private enum SessionSwitchIntent {
        case userInitiated
        case externalSync
    }

    struct ModelPatchTarget: Hashable {
        let canonicalSessionKey: String
        let agentID: String?
        let sessionRoutingContract: String?
    }

    private struct ModelSelectionRequest {
        let id: UInt64
        let target: ModelPatchTarget
        let session: SessionSnapshot
        let sessionEntryKey: String?
        let rollbackSelectionID: String
        let previousRequestID: UInt64?
        let selectionID: String
        let modelRef: String?
    }

    private struct SettingsPatchTail {
        let requestID: UInt64
        let routeLeaseTask: Task<OpenClawChatSessionSettingsRouteLease?, Never>
        let task: Task<Void, Never>
    }

    private struct BootstrapContext {
        var id: UInt64
        var historyRequest: HistoryRequest

        var session: SessionSnapshot {
            historyRequest.session
        }
    }

    struct HistoryRequest {
        var id: UInt64
        var session: SessionSnapshot
        var pendingRunIDs: Set<String>
        var visibleMessagesByID: [UUID: OpenClawChatMessage]
        var historyMutationGeneration: UInt64
        var runOwnershipGeneration: UInt64
        var latestUserTurn: LatestUserTurn?
    }

    struct RunHistoryRefreshResult {
        let applied: Bool
        let runSnapshotApplied: Bool
        let supportsInFlightRunState: Bool
        let hasInFlightRun: Bool
        let sessionHasActiveRun: Bool

        static let failed = RunHistoryRefreshResult(
            applied: false,
            runSnapshotApplied: false,
            supportsInFlightRunState: false,
            hasInFlightRun: false,
            sessionHasActiveRun: false
        )
    }

    struct LatestUserTurn {
        var idempotencyKey: String?
        var refreshKey: String?
        var occurrence: Int
        var timestamp: Double?
    }

    struct RunMessageScope {
        var session: SessionSnapshot
        var latestUserTurn: LatestUserTurn?
    }

    struct ProvisionalFinalMessage {
        var reconciliationKey: String
        var runId: String?
        var scope: RunMessageScope
    }

    var pendingToolCallsById: [String: OpenClawChatPendingToolCall] = [:] {
        didSet {
            guard pendingToolCallsById != oldValue else { return }
            pendingToolCalls = pendingToolCallsById.values
                .sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
            markTimelineChanged()
        }
    }

    var lastHealthPollAt: Date?

    public init(
        sessionKey: String,
        transport: any OpenClawChatTransport,
        activeAgentId: String? = nil,
        sessionRoutingContract: String? = nil,
        attachmentOwnerIsActive: @escaping @MainActor () -> Bool = { false },
        haptics: OpenClawChatHaptics = OpenClawChatHaptics(),
        transcriptCache: (any OpenClawChatTranscriptCache)? = nil,
        outbox: (any OpenClawChatCommandOutbox)? = nil,
        modelPickerStore: ChatModelPickerStore = ChatModelPickerStore(),
        initialThinkingLevel: String? = nil,
        onSessionChanged: (@MainActor (String) -> Void)? = nil,
        onThinkingLevelChanged: (@MainActor @Sendable (String) -> Void)? = nil,
        diagnosticsLog: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.sessionKey = sessionKey
        self.transport = transport
        self.haptics = haptics
        self.transcriptCache = transcriptCache
        self.modelPickerStore = modelPickerStore
        modelPickerFavorites = modelPickerStore.favorites
        modelPickerRecents = modelPickerStore.recents
        self.outbox = outbox
        let normalizedAgentId = activeAgentId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.activeAgentId = normalizedAgentId?.isEmpty == false ? normalizedAgentId : nil
        let normalizedRoutingContract = sessionRoutingContract?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionRoutingContract = normalizedRoutingContract?.isEmpty == false ? normalizedRoutingContract : nil
        let normalizedThinkingLevel = Self.normalizedThinkingLevel(initialThinkingLevel)
        let initialResolvedThinkingLevel = normalizedThinkingLevel ?? "off"
        thinkingLevel = initialResolvedThinkingLevel
        preferredThinkingLevel = initialResolvedThinkingLevel
        thinkingLevelOptions = Self.withCurrentThinkingOption(
            Self.baseThinkingLevelOptions,
            current: initialResolvedThinkingLevel
        )
        prefersExplicitThinkingLevel = normalizedThinkingLevel != nil
        self.onSessionChanged = onSessionChanged
        self.onThinkingLevelChanged = onThinkingLevelChanged
        self.diagnosticsLog = diagnosticsLog
        self.attachmentOwnerIsActive = attachmentOwnerIsActive

        let transport = self.transport
        eventTask = Task { [weak self, transport] in
            let stream = transport.events()
            for await evt in stream {
                if Task.isCancelled {
                    return
                }
                await MainActor.run { [weak self] in
                    self?.handleTransportEvent(evt)
                }
            }
        }
        if let outbox = self.outbox {
            let changes = outbox.changes()
            outboxChangesTask = Task { [weak self, changes] in
                for await change in changes {
                    guard !Task.isCancelled else { return }
                    self?.handleOutboxChange(change)
                }
            }
        }
    }

    deinit {
        self.eventTask?.cancel()
        self.bootstrapTask?.cancel()
        self.outboxRetryTask?.cancel()
        self.outboxChangesTask?.cancel()
        self.activeSessionRunIndicatorTimeoutTask?.cancel()
        for (_, task) in self.pendingRunOwnerTasks {
            task.cancel()
        }
    }

    public func load() {
        startBootstrap()
    }

    public func refresh() {
        startBootstrap()
    }

    public var modelPickerSections: ChatModelPickerSections {
        ChatModelPickerStore.sections(
            choices: modelChoices,
            favorites: modelPickerFavorites,
            recents: modelPickerRecents
        )
    }

    public var isSelectedModelPinned: Bool {
        modelSelectionID != Self.defaultModelSelectionID &&
            modelPickerFavorites.contains(modelSelectionID)
    }

    public func toggleSelectedModelPinned() {
        guard modelSelectionID != Self.defaultModelSelectionID else { return }
        modelPickerStore.toggleFavorite(modelSelectionID)
        modelPickerFavorites = modelPickerStore.favorites
    }

    public func resumeFromForeground() {
        Task { await self.refreshRunStateAfterForeground() }
    }

    public func abort() {
        Task { await self.performAbort() }
    }

    public func deleteSession(_ sessionKey: String) {
        Task {
            do {
                try await self.transport.deleteSession(key: sessionKey)
            } catch {
                self.errorText = error.localizedDescription
                return
            }
            self.sessions.removeAll { $0.key == sessionKey }
            if self.matchesCurrentSessionKey(incoming: sessionKey, current: self.sessionKey) {
                // The active transcript just disappeared server-side; fall
                // back to the main session instead of a dead key.
                let fallback = self.resolvedMainSessionKey
                if fallback != self.sessionKey {
                    self.applySessionSwitch(to: fallback, intent: .userInitiated)
                } else {
                    // Deleting the active main session: the key stays the
                    // address, so clear local state and re-bootstrap in place.
                    self.advanceSessionGeneration()
                    self.clearSessionOwnedState()
                    self.errorText = nil
                    self.startBootstrap()
                }
            }
            await self.fetchSessions(limit: nil, sessionSnapshot: self.currentSessionSnapshot())
        }
    }

    public func switchSession(to sessionKey: String) {
        applySessionSwitch(to: sessionKey, intent: .userInitiated)
    }

    public func syncSession(to sessionKey: String) {
        applySessionSwitch(to: sessionKey, intent: .externalSync)
    }

    // periphery:ignore - package tests vary one identity field while preserving the current routing contract.
    public func syncActiveAgentId(_ agentId: String?) {
        syncDeliveryIdentity(
            activeAgentId: agentId,
            sessionRoutingContract: deferredDeliveryIdentity?.sessionRoutingContract
                ?? sessionRoutingContract
        )
    }

    public func syncSessionRoutingContract(_ contract: String?) {
        syncDeliveryIdentity(
            activeAgentId: deferredDeliveryIdentity?.activeAgentID ?? activeAgentId,
            sessionRoutingContract: contract
        )
    }

    /// Updates the alias owner and its gateway routing contract as one
    /// identity change so an intermediate bootstrap cannot win either value.
    public func syncDeliveryIdentity(
        activeAgentId agentId: String?,
        sessionRoutingContract contract: String?
    ) {
        let normalized = agentId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nextAgentId = normalized?.isEmpty == false ? normalized : nil
        let normalizedContract = contract?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextContract = normalizedContract?.isEmpty == false ? normalizedContract : nil
        let agentChanged = activeAgentId != nextAgentId
        let contractChanged = sessionRoutingContract != nextContract
        guard agentChanged || contractChanged else {
            if blocksAttachmentOwnerChange {
                deferredDeliveryIdentity = nil
            }
            return
        }
        if blocksAttachmentOwnerChange {
            deferredDeliveryIdentity = DeferredDeliveryIdentity(
                activeAgentID: nextAgentId,
                sessionRoutingContract: nextContract
            )
            return
        }
        deferredDeliveryIdentity = nil
        // A scoped key can be the main alias under either side of a contract
        // change. Check both or stale transcript state can survive the switch.
        let contractRoutingChanged = contractChanged &&
            (usesMutableContractRouting(for: sessionRoutingContract) ||
                usesMutableContractRouting(for: nextContract))
        activeAgentId = nextAgentId
        sessionRoutingContract = nextContract
        let bootstrapIdentityChanged =
            (agentChanged && usesMutableAgentRouting) ||
            contractRoutingChanged
        guard bootstrapIdentityChanged else {
            if contractChanged, healthOK {
                flushOutboxIfNeeded()
            }
            return
        }
        // Restart when this key depends on a changed routing value so cleared
        // state cannot remain stuck or cross session owners.
        advanceSessionGeneration()
        clearSessionOwnedState()
        startBootstrap()
    }

    public func selectThinkingLevel(_ level: String) {
        performSelectThinkingLevel(level)
    }

    public func selectModel(_ selectionID: String) {
        guard let request = reserveModelSelection(selectionID) else { return }
        enqueueSessionSettingsPatch(requestID: request.id, target: request.target) { [weak self] routeLease in
            guard let self else { return }
            await self.performSelectModel(request, routeLease: routeLease)
        }
    }

    var resolvedMainSessionKey: String {
        let trimmed = sessionDefaults?.mainSessionKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? "main"
    }

    private var usesMutableAgentRouting: Bool {
        OpenClawChatSessionKey.agentID(from: sessionKey) == nil
    }

    private func usesMutableContractRouting(for contract: String?) -> Bool {
        usesMutableContractRouting(sessionKey: sessionKey, contract: contract)
    }

    func usesMutableContractRouting(sessionKey: String, contract: String?) -> Bool {
        if OpenClawChatSessionKey.agentID(from: sessionKey) == nil {
            return true
        }
        let parts = sessionKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let normalizedSessionKey = parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedMainParts = resolvedMainSessionKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        let normalizedMainSessionKey = String(resolvedMainParts.last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let contractMainKey = OpenClawChatSessionRoutingContract.parse(contract)?.mainKey ?? ""
        return normalizedSessionKey == "global" ||
            normalizedSessionKey == "main" ||
            normalizedSessionKey == normalizedMainSessionKey ||
            normalizedSessionKey == contractMainKey
    }

    public var showsModelPicker: Bool {
        !modelChoices.isEmpty
    }

    public var defaultModelLabel: String {
        guard let defaultModelID = normalizedModelSelectionID(sessionDefaults?.model) else {
            return "Default"
        }
        return "Default: \(modelLabel(for: defaultModelID))"
    }

    static let baseThinkingLevelOptions: [OpenClawChatThinkingLevelOption] = [
        OpenClawChatThinkingLevelOption(id: "off", label: "off"),
        OpenClawChatThinkingLevelOption(id: "minimal", label: "minimal"),
        OpenClawChatThinkingLevelOption(id: "low", label: "low"),
        OpenClawChatThinkingLevelOption(id: "medium", label: "medium"),
        OpenClawChatThinkingLevelOption(id: "high", label: "high"),
    ]

    public func addAttachments(urls: [URL]) {
        beginAttachmentStaging()
        Task {
            defer { self.endAttachmentStaging() }
            await self.loadAttachments(urls: urls)
        }
    }

    public func addImageAttachment(data: Data, fileName: String, mimeType: String) {
        beginAttachmentStaging()
        Task {
            defer { self.endAttachmentStaging() }
            await self.addImageAttachment(url: nil, data: data, fileName: fileName, mimeType: mimeType)
        }
    }

    public func removeAttachment(_ id: OpenClawPendingAttachment.ID) {
        attachments.removeAll { $0.id == id }
        applyDeferredExternalStateIfReady()
    }

    public var canSend: Bool {
        !isSubmittingDraft && !isSending && !hasBlockingRunActivity && hasDraftToSend
    }

    public var hasDraftToSend: Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty || !attachments.isEmpty
    }

    /// True while replacing this model could move an attachment across chats.
    public var isAttachmentOwnerPinned: Bool {
        blocksAttachmentOwnerChange
    }

    private var blocksAttachmentOwnerChange: Bool {
        attachmentOwnerIsActive() ||
            isSendingAttachmentDraft ||
            attachmentStagingCount > 0 ||
            !attachments.isEmpty
    }

    var hasBlockingRunActivity: Bool {
        pendingRunCount > 0 || hasActiveSessionRunWithoutChatSnapshot
    }

    /// Applies external owner changes once recording or staging releases them.
    public func attachmentOwnerActivityChanged() {
        applyDeferredExternalStateIfReady()
    }

    /// File reads and image processing suspend before the attachment exists.
    /// Keep their original chat owner pinned until staging succeeds or fails.
    func beginAttachmentStaging() {
        attachmentStagingCount += 1
    }

    func endAttachmentStaging() {
        precondition(attachmentStagingCount > 0)
        attachmentStagingCount -= 1
        applyDeferredExternalStateIfReady()
    }
}

extension OpenClawChatViewModel {
    // MARK: - Internals

    func markTimelineChanged() {
        timelineRevision &+= 1
    }

    func appendMessage(_ message: OpenClawChatMessage) {
        messages.append(message)
        markTimelineChanged()
    }

    func removeMessage(id: UUID) {
        let previousCount = messages.count
        messages.removeAll { $0.id == id }
        if messages.count != previousCount {
            markTimelineChanged()
        }
    }

    func updateStreamingAssistantText(_ text: String?) {
        guard streamingAssistantText != text else { return }
        streamingAssistantText = text
        markTimelineChanged()
    }

    func updateActiveSessionRunWithoutChatSnapshot(_ active: Bool) {
        guard hasActiveSessionRunWithoutChatSnapshot != active else { return }
        hasActiveSessionRunWithoutChatSnapshot = active
        if active {
            armActiveSessionRunIndicatorTimeout()
        } else {
            activeSessionRunIndicatorTimeoutTask?.cancel()
            activeSessionRunIndicatorTimeoutTask = nil
        }
        markTimelineChanged()
    }

    private func armActiveSessionRunIndicatorTimeout() {
        activeSessionRunIndicatorTimeoutTask?.cancel()
        let timeoutMs = pendingRunWaitTimeoutMs
        activeSessionRunIndicatorTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            } catch {
                return
            }
            await MainActor.run {
                self?.updateActiveSessionRunWithoutChatSnapshot(false)
            }
        }
    }

    func clearActiveSessionRunIndicatorIfLatestUserAnswered() {
        guard hasActiveSessionRunWithoutChatSnapshot,
              !Self.hasUnansweredLatestUser(in: messages)
        else { return }
        updateActiveSessionRunWithoutChatSnapshot(false)
    }

    func logDiagnostic(_ message: String) {
        diagnosticsLog?(message)
    }

    func currentSessionSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            key: sessionKey,
            generation: sessionGeneration,
            agentID: activeAgentId,
            deliveryAgentID: OpenClawChatSessionKey.agentID(from: sessionKey) ?? activeAgentId,
            sessionRoutingContract: sessionRoutingContract
        )
    }

    func isCurrentSession(_ snapshot: SessionSnapshot) -> Bool {
        let contractSensitive = usesMutableContractRouting(for: snapshot.sessionRoutingContract) ||
            usesMutableContractRouting(for: sessionRoutingContract)
        return sessionKey == snapshot.key &&
            sessionGeneration == snapshot.generation &&
            (!usesMutableAgentRouting || activeAgentId == snapshot.agentID) &&
            (!contractSensitive || sessionRoutingContract == snapshot.sessionRoutingContract)
    }

    private func isCurrentBootstrap(_ context: BootstrapContext) -> Bool {
        bootstrapGeneration == context.id && isCurrentSession(context.session)
    }

    private func canApplyHistory(_ request: HistoryRequest) -> Bool {
        request.id >= latestAppliedHistoryRequestID &&
            isCurrentSession(request.session)
    }

    private func advanceSessionGeneration() {
        sessionGeneration &+= 1
    }

    func invalidateRunSnapshots() {
        runOwnershipGeneration &+= 1
    }

    func invalidateHistorySnapshots() {
        historyMutationGeneration &+= 1
    }

    func beginHistoryRequest(
        for sessionSnapshot: SessionSnapshot? = nil,
        captureLatestUserTurn: Bool = true
    ) -> HistoryRequest {
        lastIssuedHistoryRequestID &+= 1
        return HistoryRequest(
            id: lastIssuedHistoryRequestID,
            session: sessionSnapshot ?? currentSessionSnapshot(),
            pendingRunIDs: pendingRuns,
            visibleMessagesByID: Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) }),
            historyMutationGeneration: historyMutationGeneration,
            runOwnershipGeneration: runOwnershipGeneration,
            latestUserTurn: captureLatestUserTurn ? Self.latestUserTurn(in: messages) : nil
        )
    }

    private func markHistoryRequestApplied(_ request: HistoryRequest) {
        latestAppliedHistoryRequestID = max(latestAppliedHistoryRequestID, request.id)
    }

    @discardableResult
    func applyHistoryPayload(
        _ payload: OpenClawChatHistoryPayload,
        for request: HistoryRequest,
        preservingOptimisticLocalMessages: Bool,
        syncThinkingOptions: Bool = false
    ) -> Bool {
        guard canApplyHistory(request) else { return false }
        let incoming = adoptingProvisionalFinalMessageIDs(
            in: Self.decodeMessages(payload.messages ?? [])
        )
        let unmatchedProvisionalFinalIDs = Set(provisionalFinalMessagesMissing(from: incoming).map(\.id))
        var retainedMessageIDs = unmatchedProvisionalFinalIDs
        if request.historyMutationGeneration != historyMutationGeneration {
            for message in messages where request.visibleMessagesByID[message.id] != message {
                let isMatchedProvisional = self.provisionalFinalMessagesByID[message.id] != nil &&
                    !unmatchedProvisionalFinalIDs.contains(message.id)
                if !isMatchedProvisional {
                    retainedMessageIDs.insert(message.id)
                }
            }
        }
        // Durable outbox rows remain authoritative until canonical history
        // confirms their idempotency key. Keep their bubbles through lagging
        // snapshots, including across app relaunches and session switches.
        retainedMessageIDs.formUnion(outboxCommandIDsByMessageID.keys)
        var nextMessages = if preservingOptimisticLocalMessages {
            Self.reconcileRunRefreshMessages(
                previous: messages,
                incoming: incoming,
                pendingLocalUserEchoIDs: Set(pendingLocalUserEchoMessageIDsByRunID.values)
            )
        } else {
            Self.reconcileMessageIDs(previous: messages, incoming: incoming)
        }
        let reconciledMessageIDs = Set(nextMessages.map(\.id))
        nextMessages.append(contentsOf: messages.filter { message in
            retainedMessageIDs.contains(message.id) && !reconciledMessageIDs.contains(message.id)
        })
        nextMessages = Self.dedupeMessages(nextMessages)
        replaceMessages(nextMessages)
        confirmOutboxCommands(in: incoming)
        prunePendingLocalUserEchoMessageIDs()
        clearProvisionalFinalMarkersAdoptedByHistory(incoming)
        pruneProvisionalFinalMessages()
        pruneRunMessageScopes()
        rescopeRunsAdoptedAfterHistoryRequest(request)
        sessionId = payload.sessionId
        applyInFlightRunSnapshot(payload.inFlightRun, for: request)
        // Incomplete refreshes can arrive before durable assistant history.
        // The latest visible user turn must survive answered before it can reject older replies.
        let canInvalidateOlderHistory = if let latestUserTurn = request.latestUserTurn {
            Self.hasAnsweredUser(latestUserTurn, in: messages)
        } else {
            !Self.hasUnansweredLatestUser(in: messages)
        }
        if canInvalidateOlderHistory {
            markHistoryRequestApplied(request)
        }
        clearActiveSessionRunIndicatorIfLatestUserAnswered()
        let appliedThinkingLevel = !prefersExplicitThinkingLevel
            ? Self.normalizedThinkingLevel(payload.thinkingLevel)
            : nil
        if let level = appliedThinkingLevel {
            preferredThinkingLevel = level
            thinkingLevel = level
        }
        if syncThinkingOptions || appliedThinkingLevel != nil {
            syncThinkingLevelOptions()
        }
        // Live history is the source of truth: it clears the cached marker and
        // is written through so the next cold open pre-paints current rows.
        hasAppliedLiveHistory = true
        isShowingCachedTranscript = false
        // An empty post-send refresh is incomplete by contract: reconciliation
        // preserves the visible transcript, so preserve its last canonical cache too.
        if !preservingOptimisticLocalMessages || !incoming.isEmpty {
            // Persist the reconciled transcript, including durable outbox
            // rows retained while canonical history catches up.
            persistTranscriptToCache(
                sessionKey: request.session.key,
                agentID: request.session.agentID,
                messages: nextMessages,
                canonicalMessageIdempotencyKeys: Set(incoming.compactMap(\.idempotencyKey))
            )
        }
        // Wholesale history replacement drops local-only queued bubbles;
        // re-adopt or re-append them from the durable outbox.
        restoreOutboxMessages(session: request.session)
        applyDeferredExternalStateIfReady()
        return true
    }

    private func provisionalFinalMessagesMissing(
        from incoming: [OpenClawChatMessage]
    ) -> [OpenClawChatMessage] {
        let incomingRunIds = Set(incoming.compactMap { Self.normalizedIdempotencyKey($0.idempotencyKey) })
        return messages.filter { message in
            guard let provisional = provisionalFinalMessagesByID[message.id] else { return false }
            if let runId = provisional.runId, incomingRunIds.contains(runId) {
                return false
            }
            guard Self.containsUserTurn(provisional.scope.latestUserTurn, in: incoming) else {
                return true
            }
            let searchRange = Self.messageRange(after: provisional.scope.latestUserTurn, in: incoming)
            return !incoming[searchRange].contains { incomingMessage in
                Self.finalMessageReconciliationKey(for: incomingMessage) == provisional.reconciliationKey
            }
        }
    }

    private func rescopeRunsAdoptedAfterHistoryRequest(_ request: HistoryRequest) {
        for runId in pendingRuns {
            let scope = runMessageScopesByRunID[runId]
            if !request.pendingRunIDs.contains(runId) || scope?.latestUserTurn == nil {
                runMessageScopesByRunID[runId] = currentRunMessageScope()
            }
        }
    }

    private func applyInFlightRunSnapshot(
        _ snapshot: OpenClawChatInFlightRun?,
        for request: HistoryRequest
    ) {
        guard request.runOwnershipGeneration == runOwnershipGeneration,
              request.id >= latestAppliedRunSnapshotRequestID
        else {
            return
        }
        latestAppliedRunSnapshotRequestID = request.id
        guard let snapshot,
              let runId = Self.normalizedRunID(snapshot.runId)
        else {
            return
        }

        isApplyingRunSnapshot = true
        defer { self.isApplyingRunSnapshot = false }
        updateActiveSessionRunWithoutChatSnapshot(false)
        adoptRun(runId: runId, bufferedText: snapshot.text)
    }

    func adoptRun(runId: String, bufferedText: String) {
        let canonicalPendingRuns = Set([runId])
        if pendingRuns != canonicalPendingRuns {
            // Gateway snapshots and live deltas are canonical for this session.
            // Replace stale local ownership so only that run consumes later events.
            clearPendingRuns(reason: nil)
            pendingRuns.insert(runId)
            pendingToolCallsById = [:]
            updateStreamingAssistantText(nil)
            clearPlan()
        }
        if runMessageScopesByRunID[runId] == nil {
            runMessageScopesByRunID[runId] = currentRunMessageScope()
        }
        if pendingRunOwnerArmIDs[runId] == nil {
            armPendingRunOwner(runId: runId)
        }
        if !bufferedText.isEmpty {
            updateStreamingAssistantText(bufferedText)
        }
        logDiagnostic(
            "chat.ui adopted in-flight run sessionKey=\(sessionKey) "
                + "runId=\(runId) bufferedTextLen=\(bufferedText.count)"
        )
    }

    private func startBootstrap(sessionKey requestedSessionKey: String? = nil) {
        let sessionKey = requestedSessionKey ?? self.sessionKey
        guard sessionKey == self.sessionKey else { return }
        bootstrapGeneration &+= 1
        bootstrapTask?.cancel()
        isLoading = true
        errorText = nil
        invalidateSessionMetadataReadiness()
        healthOK = false
        clearPendingRuns(reason: nil)
        pendingToolCallsById = [:]
        updateStreamingAssistantText(nil)
        clearPlan()
        updateActiveSessionRunWithoutChatSnapshot(false)
        sessionId = nil
        let historyRequest = beginHistoryRequest(captureLatestUserTurn: requestedSessionKey == nil)
        let context = BootstrapContext(
            id: bootstrapGeneration,
            historyRequest: historyRequest
        )
        paintFromCacheIfNeeded(session: context.session)
        restoreOutboxMessages(session: context.session)
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.bootstrap(context: context)
        }
    }

    private func bootstrap(context: BootstrapContext) async {
        guard isCurrentBootstrap(context) else { return }
        defer {
            if self.isCurrentBootstrap(context) {
                self.isLoading = false
            }
        }
        do {
            await syncActiveSessionSubscription(startingWith: context.session.key)
            guard isCurrentBootstrap(context) else { return }

            let payload = try await transport.requestHistory(sessionKey: context.session.key)
            guard isCurrentBootstrap(context) else { return }
            _ = applyHistoryPayload(
                payload,
                for: context.historyRequest,
                preservingOptimisticLocalMessages: false,
                syncThinkingOptions: true
            )
            await pollHealthIfNeeded(
                force: true,
                sessionSnapshot: context.session,
                refreshSessionsOnReconnect: false
            )
            guard isCurrentBootstrap(context) else { return }
            await fetchSessions(limit: 50, sessionSnapshot: context.session)
            guard isCurrentBootstrap(context) else { return }
            await fetchModels(sessionSnapshot: context.session)
            guard isCurrentBootstrap(context) else { return }
            errorText = nil
        } catch {
            guard isCurrentBootstrap(context) else { return }
            errorText = error.localizedDescription
            chatUILogger.error("bootstrap failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func syncActiveSessionSubscription(startingWith sessionKey: String) async {
        var nextSessionKey = sessionKey
        while true {
            do {
                // Subscribe requests are gateway side effects. If a stale request finishes
                // after a newer switch, immediately reassert the latest visible session.
                try await transport.setActiveSessionKey(nextSessionKey)
            } catch {
                let currentSessionKey = self.sessionKey
                guard currentSessionKey != nextSessionKey else {
                    // Best-effort only; history/send/health still work without push events.
                    return
                }
                nextSessionKey = currentSessionKey
                continue
            }
            let currentSessionKey = self.sessionKey
            guard currentSessionKey != nextSessionKey else { return }
            nextSessionKey = currentSessionKey
        }
    }

    private func refreshRunStateAfterForeground() async {
        let context = beginHistoryRequest()
        logDiagnostic(
            "chat.ui foreground refresh sessionKey=\(context.session.key) "
                + "pending=\(pendingRunCount)"
        )
        let refresh = await refreshHistoryAfterRun(historyRequest: context)
        guard isCurrentSession(context.session) else { return }
        if refresh.applied,
           refresh.runSnapshotApplied,
           context.runOwnershipGeneration == runOwnershipGeneration,
           !isSending,
           refresh.supportsInFlightRunState,
           !refresh.hasInFlightRun
        {
            if refresh.sessionHasActiveRun,
               Self.hasUnansweredLatestUser(in: messages)
            {
                pendingToolCallsById = [:]
                updateStreamingAssistantText(nil)
                clearPlan()
                // Keep a known run ID authoritative so its stream and terminal
                // events still route here. Synthesize activity only after the
                // client has no run identity to preserve.
                updateActiveSessionRunWithoutChatSnapshot(pendingRuns.isEmpty)
            } else {
                updateActiveSessionRunWithoutChatSnapshot(false)
                clearPendingRuns(
                    reason: nil,
                    hapticEvent: assistantHapticEventAfterLatestUser()
                )
                pendingToolCallsById = [:]
                updateStreamingAssistantText(nil)
                clearPlan()
            }
        }
        await pollHealthIfNeeded(force: true, sessionSnapshot: context.session)
    }

    private func performAbort() async {
        guard !pendingRuns.isEmpty else { return }
        guard !isAborting else { return }
        isAborting = true
        defer { self.isAborting = false }

        let runIds = Array(pendingRuns)
        for runId in runIds {
            do {
                try await transport.abortRun(sessionKey: sessionKey, runId: runId)
            } catch {
                // Best-effort.
            }
        }
    }

    func fetchSessions(limit: Int?, sessionSnapshot: SessionSnapshot? = nil) async {
        nextSessionsFetchRequestID &+= 1
        let sessionsFetchRequestID = nextSessionsFetchRequestID
        let session = sessionSnapshot ?? currentSessionSnapshot()
        let target = modelPatchTarget(
            sessionKey: session.key,
            canonicalSessionKey: isCurrentSession(session) ? currentSessionEntry()?.key : nil,
            agentID: session.deliveryAgentID,
            sessionRoutingContract: session.sessionRoutingContract
        )
        var overlappingSuccessfulSettingsPatchRequestID: UInt64?
        // Request IDs start at one, so zero represents no earlier success.
        var pendingSettingsPatchOverlapBaseline: UInt64?
        while true {
            await waitForPendingSessionSettings(for: target)
            if let pendingBaseline = pendingSettingsPatchOverlapBaseline {
                let completedRequestID = lastSuccessfulSettingsPatchRequestIDsByTarget[target] ?? 0
                if completedRequestID != pendingBaseline {
                    overlappingSuccessfulSettingsPatchRequestID = completedRequestID
                }
                pendingSettingsPatchOverlapBaseline = nil
            }
            if let sessionSnapshot, !self.isCurrentSession(sessionSnapshot) {
                return
            }
            let metadataGeneration = sessionMetadataGeneration
            let settingsPatchRevision = settingsPatchRevisionsByTarget[target, default: 0]
            let successfulSettingsPatchRequestID = lastSuccessfulSettingsPatchRequestIDsByTarget[target]
            let res: OpenClawChatSessionsListResponse
            do {
                res = try await transport.listSessions(limit: limit, search: nil, archived: false)
            } catch {
                if outbox != nil, healthOK, !hasCurrentSessionMetadata {
                    applyTransportHealth(false)
                }
                return
            }
            if let sessionSnapshot, !self.isCurrentSession(sessionSnapshot) {
                return
            }
            guard sessionsFetchRequestID > latestAppliedSessionsFetchRequestID else { return }
            // A list that straddles a patch or reconnect is stale. Retry in this
            // owner so bootstrap cannot discard its only authoritative refresh.
            guard metadataGeneration == sessionMetadataGeneration else {
                overlappingSuccessfulSettingsPatchRequestID = nil
                pendingSettingsPatchOverlapBaseline = nil
                continue
            }
            guard settingsPatchRevision == settingsPatchRevisionsByTarget[target, default: 0],
                  inFlightSettingsPatchCountsByTarget[target] == nil
            else {
                let completedRequestID = lastSuccessfulSettingsPatchRequestIDsByTarget[target]
                if let completedRequestID,
                   completedRequestID != successfulSettingsPatchRequestID
                {
                    overlappingSuccessfulSettingsPatchRequestID = completedRequestID
                }
                if inFlightSettingsPatchCountsByTarget[target] != nil {
                    pendingSettingsPatchOverlapBaseline = completedRequestID ?? 0
                }
                continue
            }
            latestAppliedSessionsFetchRequestID = sessionsFetchRequestID
            let organized = OpenClawChatSessionListOrganizer.organize(res.sessions)
            sessions = organized
            sessionDefaults = res.defaults
            if let overlappingRequestID = overlappingSuccessfulSettingsPatchRequestID,
               lastSuccessfulSettingsPatchRequestIDsByTarget[target] == overlappingRequestID
            {
                // A post-patch list retry may still carry the pre-patch row.
                // Preserve only the route whose patch overlapped this fetch.
                let patchResult = lastSuccessfulSettingsPatchResultsByTarget[target]
                if let selectionID = lastSuccessfulModelSelectionIDsByTarget[target] {
                    applySuccessfulModelSelection(
                        selectionID,
                        target: target,
                        sessionEntryKey: patchResult?.key ?? target.canonicalSessionKey,
                        syncSelection: false,
                        patchResult: patchResult
                    )
                } else if let thinkingLevel = patchResult?.thinkingLevel {
                    updateCurrentSessionThinkingLevel(
                        thinkingLevel,
                        sessionKey: patchResult?.key ?? target.canonicalSessionKey
                    )
                }
            }
            hasAppliedLiveSessions = true
            syncSelectedModel()
            syncThinkingLevelOptions()
            persistSessionsToCache(organized)
            readySessionMetadataGeneration = metadataGeneration
            if healthOK {
                flushOutboxIfNeeded()
            }
            return
        }
    }

    func invalidateSessionMetadataReadiness() {
        sessionMetadataGeneration &+= 1
        readySessionMetadataGeneration = nil
    }

    var hasCurrentSessionMetadata: Bool {
        readySessionMetadataGeneration == sessionMetadataGeneration
    }

    private func fetchModels(sessionSnapshot: SessionSnapshot? = nil) async {
        do {
            let modelChoices = try await transport.listModels()
            if let sessionSnapshot, !self.isCurrentSession(sessionSnapshot) {
                return
            }
            self.modelChoices = modelChoices
            syncSelectedModel()
            syncThinkingLevelOptions()
        } catch {
            // Best-effort.
        }
    }

    private func applySessionSwitch(to sessionKey: String, intent: SessionSwitchIntent) {
        let next = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return }
        guard next != self.sessionKey else {
            if intent == .externalSync {
                deferredExternalSessionKey = nil
            }
            return
        }
        if blocksAttachmentOwnerChange {
            switch intent {
            case .externalSync:
                deferredExternalSessionKey = next
            case .userInitiated:
                errorText = String(
                    localized: "Remove attachments or wait for delivery to resolve before switching chats."
                )
            }
            return
        }
        deferredExternalSessionKey = nil
        advanceSessionGeneration()
        self.sessionKey = next
        if intent == .userInitiated {
            onSessionChanged?(next)
        }
        clearSessionOwnedState()
        startBootstrap(sessionKey: next)
    }

    func applyDeferredExternalStateIfReady() {
        guard !blocksAttachmentOwnerChange else { return }
        if let identity = deferredDeliveryIdentity {
            deferredDeliveryIdentity = nil
            syncDeliveryIdentity(
                activeAgentId: identity.activeAgentID,
                sessionRoutingContract: identity.sessionRoutingContract
            )
        }
        guard let sessionKey = deferredExternalSessionKey else { return }
        deferredExternalSessionKey = nil
        applySessionSwitch(to: sessionKey, intent: .externalSync)
    }

    func performStartNewSession(worktree: Bool) async {
        guard !blocksAttachmentOwnerChange else {
            errorText = String(
                localized: "Remove attachments or wait for delivery to resolve before starting a new chat."
            )
            return
        }
        let requested = generatedNewSessionKey()
        let parentSessionKey = sessionKey
        let next: String
        do {
            let created = try await transport.createSession(
                key: requested,
                label: nil,
                parentSessionKey: parentSessionKey,
                worktree: worktree ? true : nil
            )
            let createdKey = created.key.trimmingCharacters(in: .whitespacesAndNewlines)
            next = createdKey.isEmpty ? requested : createdKey
        } catch {
            if Self.isUnsupportedCreateSessionError(error) {
                chatUILogger.info("sessions.create unsupported; falling back to sessions.reset")
                await performReset()
                return
            }
            chatUILogger.error("sessions.create failed \(error.localizedDescription, privacy: .public)")
            errorText = error.localizedDescription
            return
        }
        guard !blocksAttachmentOwnerChange else {
            errorText = String(
                localized: "Remove attachments or wait for delivery to resolve before starting a new chat."
            )
            return
        }
        advanceSessionGeneration()
        sessionKey = next
        onSessionChanged?(next)
        clearSessionOwnedState()
        errorText = nil
        startBootstrap()
    }

    /// Clears state owned by the current session/agent before a new identity can consume events.
    private func clearSessionOwnedState() {
        modelSelectionID = Self.defaultModelSelectionID
        replaceMessages([])
        isShowingCachedTranscript = false
        hasAppliedLiveHistory = false
        pendingLocalUserEchoMessageIDsByRunID.removeAll()
        runMessageScopesByRunID.removeAll()
        provisionalFinalMessagesByID.removeAll()
        resetOutboxPresentationForSessionSwitch()
        sessionId = nil
        pendingToolCallsById = [:]
        updateStreamingAssistantText(nil)
        clearPlan()
        updateActiveSessionRunWithoutChatSnapshot(false)
        resetSlashCommandCatalog()
        clearPendingRuns(reason: nil)
    }

    private static func isUnsupportedCreateSessionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "OpenClawChatTransport"
            && nsError.localizedDescription == "sessions.create not supported by this transport"
    }

    func performReset() async {
        isLoading = true
        errorText = nil

        do {
            try await transport.resetSession(sessionKey: sessionKey)
        } catch {
            isLoading = false
            errorText = error.localizedDescription
            chatUILogger.error("session reset failed \(error.localizedDescription, privacy: .public)")
            return
        }

        runMessageScopesByRunID.removeAll()
        provisionalFinalMessagesByID.removeAll()
        startBootstrap()
    }

    func performCompact() async {
        guard !isCompacting else { return }
        guard !isSending, !hasBlockingRunActivity, !isAborting else {
            errorText = "Wait for the current response before compacting the session."
            return
        }
        if let lastCompactAt,
           Date().timeIntervalSince(lastCompactAt) < compactCooldown
        {
            errorText = "Please wait before compacting this session again."
            return
        }

        isCompacting = true
        isLoading = true
        errorText = nil
        defer {
            self.isCompacting = false
        }

        do {
            try await transport.compactSession(sessionKey: sessionKey)
        } catch {
            isLoading = false
            errorText = "Unable to compact the session. Please try again."
            let nsError = error as NSError
            chatUILogger.error(
                "compact failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            chatUILogger.error("compact details=\(String(describing: error), privacy: .private)")
            return
        }

        lastCompactAt = Date()
        startBootstrap()
    }

    private func reserveModelSelection(_ selectionID: String) -> ModelSelectionRequest? {
        let next = normalizedSelectionID(selectionID)
        guard next != modelSelectionID else { return nil }

        let session = currentSessionSnapshot()
        let sessionEntryKey = currentSessionEntry()?.key
        let target = modelPatchTarget(
            sessionKey: session.key,
            canonicalSessionKey: sessionEntryKey,
            agentID: session.deliveryAgentID,
            sessionRoutingContract: session.sessionRoutingContract
        )
        let previous = modelSelectionID
        let rollbackSelectionID = lastSuccessfulModelSelectionIDsByTarget[target] ?? previous
        let previousRequestID = latestModelSelectionRequestIDsByTarget[target]
        let requestID = reserveSessionSettingsRequest(for: target)
        let nextModelRef = modelRef(forSelectionID: next)
        latestModelSelectionRequestIDsByTarget[target] = requestID
        modelSelectionID = next
        syncThinkingLevelOptions()
        errorText = nil
        return ModelSelectionRequest(
            id: requestID,
            target: target,
            session: session,
            sessionEntryKey: sessionEntryKey,
            rollbackSelectionID: rollbackSelectionID,
            previousRequestID: previousRequestID,
            selectionID: next,
            modelRef: nextModelRef
        )
    }

    private func performSelectModel(
        _ request: ModelSelectionRequest,
        routeLease: OpenClawChatSessionSettingsRouteLease?
    ) async {
        do {
            guard let routeLease else { throw OpenClawChatTransportSendError.notDispatched }
            let patchResult = try await routeLease.patchSessionSettings(
                sessionKey: request.target.canonicalSessionKey,
                agentID: request.target.agentID,
                patch: OpenClawChatSessionSettingsPatch(model: .some(request.modelRef))
            )
            lastSuccessfulSettingsPatchRequestIDsByTarget[request.target] = request.id
            guard request.id == latestModelSelectionRequestIDsByTarget[request.target] else {
                // Keep older successful patches as rollback state, but do not replay
                // stale UI/session state over a newer queued or completed selection.
                recordSuccessfulModelPatch(
                    selectionID: request.selectionID,
                    patchResult: patchResult,
                    target: request.target
                )
                return
            }
            applySuccessfulModelSelection(
                request.selectionID,
                target: request.target,
                sessionEntryKey: patchResult?.key ?? request.sessionEntryKey,
                syncSelection: isCurrentSession(request.session),
                patchResult: patchResult
            )
            modelPickerStore.recordRecent(request.selectionID)
            modelPickerRecents = modelPickerStore.recents
        } catch {
            guard request.id == latestModelSelectionRequestIDsByTarget[request.target] else { return }
            let rollbackSelectionID = lastSuccessfulModelSelectionIDsByTarget[request.target]
                ?? request.rollbackSelectionID
            if let previousRequestID = request.previousRequestID {
                latestModelSelectionRequestIDsByTarget[request.target] = previousRequestID
            } else {
                latestModelSelectionRequestIDsByTarget.removeValue(forKey: request.target)
            }
            if lastSuccessfulModelSelectionIDsByTarget[request.target] == rollbackSelectionID {
                applySuccessfulModelSelection(
                    rollbackSelectionID,
                    target: request.target,
                    sessionEntryKey: request.sessionEntryKey,
                    syncSelection: isCurrentSession(request.session),
                    patchResult: lastSuccessfulSettingsPatchResultsByTarget[request.target]
                )
            }
            guard isCurrentSession(request.session) else { return }
            modelSelectionID = rollbackSelectionID
            syncThinkingLevelOptions()
            errorText = error.localizedDescription
            chatUILogger.error("sessions.patch(model) failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finishSettingsPatchTail(requestID: UInt64, target: ModelPatchTarget) {
        guard settingsPatchTailsByTarget[target]?.requestID == requestID else { return }
        settingsPatchTailsByTarget.removeValue(forKey: target)
    }

    func reserveSessionSettingsRequest(for target: ModelPatchTarget) -> UInt64 {
        nextSessionSettingsRequestID &+= 1
        beginSettingsPatch(for: target)
        return nextSessionSettingsRequestID
    }

    func enqueueSessionSettingsPatch(
        requestID: UInt64,
        target: ModelPatchTarget,
        operation: @escaping @MainActor (OpenClawChatSessionSettingsRouteLease?) async -> Void
    ) {
        let previousPatchTail = settingsPatchTailsByTarget[target]
        let previousTail = previousPatchTail?.task
        let previousRouteLeaseTask = previousPatchTail?.routeLeaseTask
        // Task scheduling is not FIFO. Chain lease capture separately so a
        // reconnect cannot give an older mutation a newer route than its successor.
        let routeLeaseTask = Task { [weak self] in
            _ = await previousRouteLeaseTask?.value
            return await self?.transport.acquireSessionSettingsRouteLease()
        }
        let task = Task { [weak self] in
            let routeLease = await routeLeaseTask.value
            await previousTail?.value
            guard let self else { return }
            await operation(routeLease)
            self.endSettingsPatch(for: target)
            self.finishSettingsPatchTail(requestID: requestID, target: target)
        }
        settingsPatchTailsByTarget[target] = SettingsPatchTail(
            requestID: requestID,
            routeLeaseTask: routeLeaseTask,
            task: task
        )
    }

    private func beginSettingsPatch(for target: ModelPatchTarget) {
        settingsPatchRevisionsByTarget[target, default: 0] &+= 1
        inFlightSettingsPatchCountsByTarget[target, default: 0] += 1
    }

    private func endSettingsPatch(for target: ModelPatchTarget) {
        settingsPatchRevisionsByTarget[target, default: 0] &+= 1
        let remaining = max(0, (inFlightSettingsPatchCountsByTarget[target] ?? 0) - 1)
        if remaining == 0 {
            inFlightSettingsPatchCountsByTarget.removeValue(forKey: target)
            // Rollback baselines belong to one contiguous settings lane. Once
            // drained, the next authoritative session snapshot owns state.
            acceptedSettingsPatchResultsByTarget.removeValue(forKey: target)
            acceptedThinkingLevelsByTarget.removeValue(forKey: target)
            acceptedPreferredThinkingLevelsByTarget.removeValue(forKey: target)
            acceptedExplicitThinkingPreferencesByTarget.removeValue(forKey: target)
            latestThinkingSelectionRequestIDsByTarget.removeValue(forKey: target)
            let waiters = settingsPatchWaitersByTarget.removeValue(forKey: target) ?? []
            for waiter in waiters {
                waiter.resume()
            }
            return
        }
        inFlightSettingsPatchCountsByTarget[target] = remaining
    }

    /// Internal for the outbox flush, which must honor the same ordering
    /// behind in-flight settings patches as the live send path.
    func waitForPendingSessionSettings(
        in sessionKey: String,
        canonicalSessionKey: String? = nil,
        agentID: String? = nil,
        sessionRoutingContract: String? = nil
    ) async {
        let target: ModelPatchTarget
        if canonicalSessionKey == nil,
           agentID == nil,
           sessionRoutingContract == nil,
           sessionKey == self.sessionKey
        {
            let session = currentSessionSnapshot()
            target = modelPatchTarget(
                sessionKey: session.key,
                canonicalSessionKey: currentSessionEntry()?.key,
                agentID: session.deliveryAgentID,
                sessionRoutingContract: session.sessionRoutingContract
            )
        } else {
            target = modelPatchTarget(
                sessionKey: sessionKey,
                canonicalSessionKey: canonicalSessionKey,
                agentID: agentID,
                sessionRoutingContract: sessionRoutingContract
            )
        }
        await waitForPendingSessionSettings(for: target)
    }

    private func waitForPendingSessionSettings(for target: ModelPatchTarget) async {
        guard (inFlightSettingsPatchCountsByTarget[target] ?? 0) > 0 else { return }
        await withCheckedContinuation { continuation in
            self.settingsPatchWaitersByTarget[target, default: []].append(continuation)
        }
    }

    func placeholderSession(key: String) -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: key,
            kind: nil,
            displayName: nil,
            surface: nil,
            subject: nil,
            room: nil,
            space: nil,
            updatedAt: nil,
            sessionId: nil,
            systemSent: nil,
            abortedLastRun: nil,
            thinkingLevel: nil,
            verboseLevel: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            modelProvider: nil,
            model: nil,
            contextTokens: nil
        )
    }

    func syncSelectedModel() {
        let currentSession = currentSessionEntry()
        let target = currentModelPatchTarget()
        let explicitModelID = normalizedModelSelectionID(
            currentSession?.model,
            provider: currentSession?.modelProvider
        )
        let defaultModelID = normalizedModelSelectionID(
            sessionDefaults?.model,
            provider: sessionDefaults?.modelProvider
        )
        if lastSuccessfulModelSelectionIDsByTarget[target] == Self.defaultModelSelectionID,
           explicitModelID == defaultModelID
        {
            modelSelectionID = Self.defaultModelSelectionID
            return
        }
        if let explicitModelID {
            lastSuccessfulModelSelectionIDsByTarget[target] = explicitModelID
            modelSelectionID = explicitModelID
            return
        }
        lastSuccessfulModelSelectionIDsByTarget[target] = Self.defaultModelSelectionID
        modelSelectionID = Self.defaultModelSelectionID
    }

    private func normalizedSelectionID(_ selectionID: String) -> String {
        let trimmed = selectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.defaultModelSelectionID }
        return trimmed
    }

    private func normalizedModelSelectionID(_ modelID: String?, provider: String? = nil) -> String? {
        guard let modelID else { return nil }
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let provider = Self.normalizedProvider(provider) {
            let providerQualified = Self.providerQualifiedModelSelectionID(modelID: trimmed, provider: provider)
            if let match = modelChoices.first(where: {
                $0.selectionID == providerQualified ||
                    ($0.modelID == trimmed && Self.normalizedProvider($0.provider) == provider)
            }) {
                return match.selectionID
            }
            return providerQualified
        }
        if modelChoices.contains(where: { $0.selectionID == trimmed }) {
            return trimmed
        }
        let matches = modelChoices.filter { $0.modelID == trimmed || $0.selectionID == trimmed }
        if matches.count == 1 {
            return matches[0].selectionID
        }
        return trimmed
    }

    private func modelRef(forSelectionID selectionID: String) -> String? {
        let normalized = normalizedSelectionID(selectionID)
        if normalized == Self.defaultModelSelectionID {
            return nil
        }
        return normalized
    }

    private func generatedNewSessionKey() -> String {
        let baseKey = "ios-\(UUID().uuidString.lowercased())"
        guard let agentID = OpenClawChatSessionKey.agentID(from: sessionKey) ??
            activeAgentId ??
            OpenClawChatSessionKey.agentID(from: resolvedMainSessionKey) ??
            sessions.lazy.compactMap({ OpenClawChatSessionKey.agentID(from: $0.key) }).first
        else {
            return baseKey
        }
        return "agent:\(agentID):\(baseKey)"
    }

    private func modelLabel(for modelID: String) -> String {
        modelChoices.first(where: { $0.selectionID == modelID || $0.modelID == modelID })?.displayLabel ??
            modelID
    }

    private func applySuccessfulModelSelection(
        _ selectionID: String,
        target: ModelPatchTarget,
        sessionEntryKey: String?,
        syncSelection: Bool,
        patchResult: OpenClawChatModelPatchResult? = nil
    ) {
        recordSuccessfulModelPatch(
            selectionID: selectionID,
            patchResult: patchResult,
            target: target
        )
        if target.canonicalSessionKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "global",
           let targetAgentID = target.agentID,
           targetAgentID != activeAgentId
        {
            return
        }
        let resolved: (modelID: String?, modelProvider: String?) = if selectionID == Self.defaultModelSelectionID {
            (modelID: nil, modelProvider: nil)
        } else if let model = patchResult?.model {
            (modelID: model, modelProvider: patchResult?.modelProvider)
        } else {
            resolvedSessionModelIdentity(forSelectionID: selectionID)
        }
        let modelStateKey = sessionEntryKey ?? target.canonicalSessionKey
        updateCurrentSessionModel(
            modelID: resolved.modelID,
            modelProvider: resolved.modelProvider,
            sessionKey: modelStateKey,
            syncSelection: syncSelection
        )
        if let thinkingLevels = patchResult?.thinkingLevels {
            updateCurrentSessionThinkingLevels(thinkingLevels, sessionKey: modelStateKey)
        }
        if syncSelection,
           !prefersExplicitThinkingLevel,
           Self.normalizedThinkingLevel(preferredThinkingLevel) != "ultra",
           let thinkingLevel = Self.normalizedThinkingLevel(patchResult?.thinkingLevel)
        {
            preferredThinkingLevel = thinkingLevel
        }
        if let thinkingLevel = Self.normalizedThinkingLevel(patchResult?.thinkingLevel) {
            updateCurrentSessionThinkingLevel(thinkingLevel, sessionKey: modelStateKey)
        }
        if syncSelection {
            syncThinkingLevelOptions()
        }
    }

    private func recordSuccessfulModelPatch(
        selectionID: String,
        patchResult: OpenClawChatModelPatchResult?,
        target: ModelPatchTarget
    ) {
        lastSuccessfulModelSelectionIDsByTarget[target] = selectionID
        lastSuccessfulSettingsPatchResultsByTarget[target] = patchResult
        if let thinkingLevel = Self.normalizedThinkingLevel(patchResult?.thinkingLevel) {
            acceptedThinkingLevelsByTarget[target] = thinkingLevel
            if acceptedExplicitThinkingPreferencesByTarget[target] == false {
                acceptedPreferredThinkingLevelsByTarget[target] = thinkingLevel
            }
        }
        if let patchResult {
            let previous = acceptedSettingsPatchResultsByTarget[target]
            acceptedSettingsPatchResultsByTarget[target] = OpenClawChatModelPatchResult(
                key: patchResult.key ?? previous?.key,
                modelProvider: patchResult.modelProvider ?? previous?.modelProvider,
                model: patchResult.model ?? previous?.model,
                thinkingLevel: patchResult.thinkingLevel ?? previous?.thinkingLevel,
                thinkingLevels: patchResult.thinkingLevels ?? previous?.thinkingLevels
            )
        }
        completedModelPatchTargets.insert(target)
    }

    private func resolvedSessionModelIdentity(forSelectionID selectionID: String)
        -> (modelID: String?, modelProvider: String?)
    {
        guard let modelRef = modelRef(forSelectionID: selectionID) else {
            return (nil, nil)
        }
        if let choice = modelChoices.first(where: { $0.selectionID == modelRef }) {
            return (choice.modelID, Self.normalizedProvider(choice.provider))
        }
        return (modelRef, nil)
    }
}
