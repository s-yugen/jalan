import AVFoundation
import NavCore

/// Speaks prompts over music or podcasts, ducking them while talking.
final class VoiceGuide: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: NavLanguage) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt,
                                 options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        // Malay needs the "Amira" voice (Settings > Accessibility > Spoken Content > Voices).
        // Without it iOS reads the Malay text with the default voice.
        utterance.voice = AVSpeechSynthesisVoice(language: language.voiceCode)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
