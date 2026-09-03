@testable import Editor
import Testing

@MainActor
struct EditorRevertMessageTests {
    @Test func `the message starts with the body and appends one paragraph per warning`() {
        let vm = PreviewEditorFactory.makeViewModel()
        let plain = vm.revertConfirmationMessage(hasMusicalAnnotations: false)
        let withInk = vm.revertConfirmationMessage(hasMusicalAnnotations: true)
        #expect(withInk.hasPrefix(plain))
        #expect(withInk.components(separatedBy: "\n\n").count == plain.components(separatedBy: "\n\n").count + 1)
    }
}
