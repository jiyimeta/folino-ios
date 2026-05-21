import Domain
import LibraryLogic
import Testing

struct ImportPlanValidatorTests {
    @Test
    func `plan with no duplicates commits as new`() {
        let plan = ImportPlan.makeFake(duplicates: [])
        let decision = ImportPlanValidator.decision(for: plan)
        #expect(decision == .commitAsNew)
    }

    @Test
    func `plan with duplicate stages prompt`() {
        let item = ScoreItem.makeFake()
        let plan = ImportPlan.makeFake(duplicates: [item])
        let decision = ImportPlanValidator.decision(for: plan)
        #expect(decision == .promptForDuplicate(existing: item))
    }

    @Test
    func `plan with multiple duplicates prompts first`() {
        let first = ScoreItem.makeFake()
        let second = ScoreItem.makeFake()
        let plan = ImportPlan.makeFake(duplicates: [first, second])
        let decision = ImportPlanValidator.decision(for: plan)
        #expect(decision == .promptForDuplicate(existing: first))
    }
}
