import Foundation
import OpenClawKit

/// Live plan-checklist state: full-snapshot semantics scoped to the owning run.
extension OpenClawChatViewModel {
    func applyPlanSnapshot(runId: String, data: [String: AnyCodable]) {
        let steps = OpenClawChatPlanStep.parseSteps(data["steps"])
        guard !steps.isEmpty else {
            self.clearPlan(for: runId)
            return
        }
        let explanation = (data["explanation"]?.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExplanation = explanation?.isEmpty == false ? explanation : nil
        guard planRunId != runId ||
            planSteps != steps ||
            planExplanation != normalizedExplanation
        else {
            return
        }
        planRunId = runId
        planSteps = steps
        planExplanation = normalizedExplanation
        markTimelineChanged()
    }

    func clearPlan(for runId: String? = nil) {
        if let runId, planRunId != runId {
            return
        }
        guard planRunId != nil || !planSteps.isEmpty || planExplanation != nil else { return }
        planRunId = nil
        planSteps = []
        planExplanation = nil
        markTimelineChanged()
    }
}
