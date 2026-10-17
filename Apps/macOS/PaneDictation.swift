import AppKit
@preconcurrency import AVFoundation
import Observation
@preconcurrency import Speech
import SwiftUI
import XTermXKit

@MainActor @Observable final class PaneDictationController {
    var holdEnabled = UserDefaults.standard.bool(forKey: "xtermx.dictation.hold") {
        didSet { UserDefaults.standard.set(holdEnabled, forKey: "xtermx.dictation.hold"); if !holdEnabled { held = false; cancel() } }
    }
    var holdKey = DictationHoldKey(rawValue: UserDefaults.standard.string(forKey: "xtermx.dictation.key") ?? "") ?? .rightOption {
        didSet { UserDefaults.standard.set(holdKey.rawValue, forKey: "xtermx.dictation.key"); held = false; cancel() }
    }
    var language = UserDefaults.standard.string(forKey: "xtermx.dictation.language") ?? Locale.current.identifier {
        didSet { UserDefaults.standard.set(language, forKey: "xtermx.dictation.language"); cancel() }
    }
    var allowSpeechService = UserDefaults.standard.bool(forKey: "xtermx.dictation.service") {
        didSet { UserDefaults.standard.set(allowSpeechService, forKey: "xtermx.dictation.service"); cancel() }
    }
    private(set) var session = PaneDictationSession()
    var error: String?
    @ObservationIgnored var target: (() -> String?)?
    @ObservationIgnored var deliver: ((DictatedText) -> Bool)?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var held = false
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    var active: Bool { session.phase != .idle }

    func flagsChanged(_ event: NSEvent) {
        guard holdEnabled, let down = holdKey.pressed(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) else { return }
        guard down != held else { return }
        held = down
        if down {
            holdTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.held else { return }
                self.start()
            }
        } else { holdTask?.cancel(); holdTask = nil; stop() }
    }
    func toggle() { active ? stop() : start() }
    func start() {
        guard !active, let paneID = target?() else { if !active { error = "Select a terminal before starting dictation." }; return }
        error = nil
        let id = session.begin(paneID: paneID)
        Task { @MainActor [weak self] in
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard let self, self.session.id == id else { return }
            guard speech else { self.fail("Allow Speech Recognition for XTermX in System Settings to use dictation."); return }
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            guard self.session.id == id else { return }
            guard microphone else { self.fail("Allow microphone access for XTermX in System Settings to use dictation."); return }
            do { try self.record(id) } catch { self.fail(error.localizedDescription) }
        }
    }
    private func record(_ id: UUID) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            fail("Speech recognition is not available for this language."); return
        }
        guard recognizer.supportsOnDeviceRecognition || allowSpeechService else {
            fail("This language needs Apple's speech service. Choose another language or allow the service in Terminal settings."); return
        }
        guard recognizer.isAvailable else { fail("Speech recognition is unavailable right now."); return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail("No microphone input is available."); return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        guard session.ready(id) else { return }
        self.engine = engine; self.request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.session.id == id else { return }
                if let text { self.session.update(id, text: text) }
                if final { self.finish(id) }
                else if let message {
                    if self.session.phase == .finishing { self.finish(id) } else { self.fail(message) }
                }
            }
        }
        engine.prepare()
        try engine.start()
    }
    func stop() {
        holdTask?.cancel(); holdTask = nil
        guard let id = session.id else { return }
        session.stop()
        guard session.id == id else { tearDown(); return }
        stopAudio()
        request?.endAudio()
        recognition?.finish()
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.finish(id)
        }
    }
    func cancel() { holdTask?.cancel(); holdTask = nil; session.cancel(); tearDown() }
    private func finish(_ id: UUID) {
        guard session.id == id else { return }
        let text = session.commit(id)
        tearDown()
        if let text, deliver?(text) != true { error = "The destination pane is no longer available for input." }
    }
    private func fail(_ message: String) { cancel(); error = message }
    private func stopAudio() {
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
    }
    private func tearDown() {
        finishTask?.cancel(); finishTask = nil
        stopAudio(); request?.endAudio(); recognition?.cancel()
        request = nil; recognition = nil
    }
}

struct PaneDictationSettings: View {
    @Environment(AppModel.self) private var model
    private var locales: [Locale] { SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier } }
    var body: some View {
        SettingsCard("Speak into a pane", "Dictation inserts text into the selected terminal without pressing Return.") {
            Toggle("Hold a key to dictate", isOn: Binding(get: { model.dictation.holdEnabled }, set: { model.dictation.holdEnabled = $0 }))
                .toggleStyle(.switch)
            Picker("Hold key", selection: Binding(get: { model.dictation.holdKey }, set: { model.dictation.holdKey = $0 })) {
                ForEach(DictationHoldKey.allCases) { key in Text(key.title).tag(key) }
            }
            Picker("Speech language", selection: Binding(get: { model.dictation.language }, set: { model.dictation.language = $0 })) {
                ForEach(locales, id: \.identifier) { locale in Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier) }
            }
            Toggle("Allow Apple's speech service when needed", isOn: Binding(get: { model.dictation.allowSpeechService }, set: { model.dictation.allowSpeechService = $0 }))
                .toggleStyle(.switch)
            Text("Uses on-device recognition when available. Allowing the service lets Apple process speech for languages without local support.").font(.caption)
            HStack {
                Button(model.dictation.active ? "Finish dictation" : "Start dictation · ⌘⇧L") { model.dictation.toggle() }
                if model.dictation.active { Button("Cancel") { model.dictation.cancel() } }
            }
            if !model.dictation.session.text.isEmpty { Text(model.dictation.session.text).font(.callout).textSelection(.enabled) }
            if let error = model.dictation.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Microphone and speech permission are requested only when you start. The destination stays the pane where dictation began.").font(.caption)
        }
    }
}
