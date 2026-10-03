import XCTest
@testable import OpenClip
@testable import Core

/// Minimal fake action with a configurable chrome source, for AIToolsAction's children resolution.
private struct FakeAIAction: Action {
    let id: String
    var title: String { id }
    var icon: ActionIcon { .symbol("sparkles") }
    var chrome: ActionChrome
    init(id: String, source: ActionChrome.Source = .ai) {
        self.id = id
        self.chrome = ActionChrome(source: source)
    }
    @MainActor func isEnabled(for context: ActionContext) -> Bool { true }
    @MainActor func perform(_ context: ActionContext) async throws -> ActionResult { .success }
}

@MainActor
final class AIToolsActionSubActionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.reset()
    }

    func testStandalonePresetsAreNotDuplicatedInAITools() {
        let store = MemorySettingsStore()
        let tools = AIToolsAction(settingsStore: store)
        let presets = [FakeAIAction(id: "ai.preset.1"), FakeAIAction(id: "ai.preset.2")]
        store.set(.standaloneAIActionIDs, value: ["ai.preset.1"])
        XCTAssertEqual(tools.subActions(in: presets).map(\.id), ["ai.preset.2"])
        store.set(.standaloneAIActionIDs, value: Set(presets.map(\.id)))
        XCTAssertTrue(tools.subActions(in: presets).isEmpty, "An empty group must not resurrect presets via the fallback.")
    }

    @MainActor
    func testAIToolsResolvesAIPresets() {
        let tools = AIToolsAction(settingsStore: MemorySettingsStore())
        let preset1 = FakeAIAction(id: "ai.preset.1")
        let preset2 = FakeAIAction(id: "ai.preset.2")
        let other = FakeAIAction(id: "builtin.copy", source: .builtin)
        let ids = tools.subActions(in: [preset1, preset2, other]).map(\.id)
        XCTAssertEqual(ids, ["ai.preset.1", "ai.preset.2"])
    }

    @MainActor
    func testAIToolsResolvesFromAIServiceManagerWhenCatalogLacksPresets() {
        let tools = AIToolsAction(settingsStore: MemorySettingsStore())
        let other = FakeAIAction(id: "builtin.copy", source: .builtin)
        let subActions = tools.subActions(in: [other])
        XCTAssertFalse(subActions.isEmpty)
        XCTAssertTrue(subActions.allSatisfy { ActionIdentity.isAIPreset($0) })
    }
}
