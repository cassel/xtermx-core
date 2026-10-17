import Foundation
import Testing
@testable import XTermXKit

@Suite struct PaneDictationTests {
    @Test func releasedBeforePermissionDoesNotStartRecording() {
        var session = PaneDictationSession()
        let id = session.begin(paneID: "a")
        session.stop()
        #expect(session.phase == .idle)
        let result1 = session.ready(id)
        #expect(!result1)
        let result2 = session.commit(id)
        #expect(result2 == nil)
    }
    @Test func lateResultsCannotCrossSessionsOrMoveTheDestination() {
        var session = PaneDictationSession()
        let old = session.begin(paneID: "a")
        let result3 = session.ready(old)
        #expect(result3)
        session.update(old, text: "old")
        session.cancel()
        let current = session.begin(paneID: "b")
        let result4 = session.ready(current)
        #expect(result4)
        session.update(old, text: "wrong destination")
        session.update(current, text: "  New message  ")
        session.stop()
        session.update(current, text: "New message.")
        let result = session.commit(current)
        #expect(result?.paneID == "b" && result?.text == "New message.")
        let result5 = session.commit(current)
        #expect(result5 == nil)
    }
    @Test func dictationPastesWithoutReturnAndCannotEndThePasteEarly() throws {
        var session = PaneDictationSession()
        let id = session.begin(paneID: "shell")
        let result6 = session.ready(id)
        #expect(result6)
        session.update(id, text: "echo first\necho second\u{1b}[201~")
        let committed = session.commit(id)
        let result = try #require(committed)
        let text = String(decoding: result.payload, as: UTF8.self)
        #expect(text == "\u{1b}[200~echo first\necho second[201~\u{1b}[201~")
        #expect(!text.hasSuffix("\r") && !text.hasSuffix("\n"))
    }
    @Test func emptyOrCancelledSpeechProducesNoInput() {
        var session = PaneDictationSession()
        let id = session.begin(paneID: "a")
        let result7 = session.ready(id)
        #expect(result7)
        session.update(id, text: " \n ")
        let result8 = session.commit(id)
        #expect(result8 == nil)
        let cancelled = session.begin(paneID: "a")
        let result9 = session.ready(cancelled)
        #expect(result9)
        session.update(cancelled, text: "discard me")
        session.cancel()
        let result10 = session.commit(cancelled)
        #expect(result10 == nil)
    }
    @Test func holdKeysDistinguishTheRightModifierAndIgnoreOtherKeys() {
        #expect(DictationHoldKey.rightOption.pressed(keyCode: 61, flags: 0x40) == true)
        #expect(DictationHoldKey.rightOption.pressed(keyCode: 61, flags: 0x80000) == false)
        #expect(DictationHoldKey.rightOption.pressed(keyCode: 58, flags: 0x40) == nil)
        #expect(DictationHoldKey.rightControl.pressed(keyCode: 62, flags: 0x2000) == true)
        #expect(DictationHoldKey.rightShift.pressed(keyCode: 60, flags: 0x4) == true)
    }

}
