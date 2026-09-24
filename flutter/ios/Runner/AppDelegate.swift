import UIKit
import Flutter
import Speech
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  // NelDesk: background task that keeps the connection alive for the ~30 s
  // iOS grants after leaving the app, so a quick app switch does not drop it.
  private var nelBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var nelDictation: NelDictation?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    dummyMethodToEnforceBundling();
    if let registrar = self.registrar(forPlugin: "NelDictation") {
      nelDictation = NelDictation(messenger: registrar.messenger())
    }
    // Notifications work with both the AppDelegate and the UIScene lifecycles.
    NotificationCenter.default.addObserver(
      self, selector: #selector(nelDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(nelWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @objc private func nelDidEnterBackground() {
    nelEndBackgroundTask()
    nelBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NelDeskKeepAlive") {
      [weak self] in self?.nelEndBackgroundTask()
    }
  }

  @objc private func nelWillEnterForeground() {
    nelEndBackgroundTask()
  }

  private func nelEndBackgroundTask() {
    if nelBackgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(nelBackgroundTask)
      nelBackgroundTask = .invalid
    }
  }

  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
  }
}

// NelDesk: continuous dictation. While controlling the Mac there is no text
// field, so the iPadOS dictation mic never shows up. This listens with the
// Speech framework (Spanish) and, after each short pause, hands the phrase to
// Flutter, which types it on the Mac. It keeps listening until "stop".
// Channel "neldesk/dictation": start -> true | error, stop -> true.
// Native -> Dart: "partial"(text) while speaking, "phrase"(text) to type.
final class NelDictation {
  private static let pause: TimeInterval = 1.5
  private let channel: FlutterMethodChannel
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
  // Created per dictation, after the session switches to record: an engine made
  // while the session was playback-only has an input with no format (0 Hz) and
  // installTap raises an uncatchable NSException (crash 24-sep-2026).
  private var audioEngine: AVAudioEngine?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var generation = 0
  private var lastText = ""
  private var silenceTimer: Timer?
  private var active = false
  private var previousCategory: AVAudioSession.Category?
  private var previousMode: AVAudioSession.Mode?
  private var previousOptions: AVAudioSession.CategoryOptions = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "neldesk/dictation", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "start": self.start(result)
      case "stop":
        self.commitPhrase(restart: false)
        self.teardown()
        result(true)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func start(_ result: @escaping FlutterResult) {
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else {
          result(FlutterError(code: "speech", message: "Sin permiso de reconocimiento de voz", details: nil))
          return
        }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async {
            guard granted else {
              result(FlutterError(code: "mic", message: "Sin permiso de micrófono", details: nil))
              return
            }
            do {
              try self.begin()
              result(true)
            } catch {
              self.teardown()
              result(FlutterError(code: "start", message: error.localizedDescription, details: nil))
            }
          }
        }
      }
    }
  }

  private func begin() throws {
    teardown()
    guard let recognizer = recognizer, recognizer.isAvailable else {
      throw NSError(domain: "NelDictation", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reconocimiento de voz no disponible"])
    }
    let session = AVAudioSession.sharedInstance()
    previousCategory = session.category
    previousMode = session.mode
    previousOptions = session.categoryOptions
    try session.setCategory(.playAndRecord, mode: .measurement,
                            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let engine = AVAudioEngine()
    audioEngine = engine
    let input = engine.inputNode
    let hwFormat = input.inputFormat(forBus: 0)
    guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
      throw NSError(domain: "NelDictation", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "El micrófono no está disponible"])
    }
    active = true
    startRecognition(recognizer)
    // nil format = the node's own format, so it always matches the hardware.
    input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
      self?.request?.append(buffer)
    }
    engine.prepare()
    try engine.start()
  }

  // One recognition task per phrase: also avoids the ~1 min limit per task.
  private func startRecognition(_ recognizer: SFSpeechRecognizer) {
    generation += 1
    let gen = generation
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    if #available(iOS 16.0, *) { req.addsPunctuation = true }
    request = req
    lastText = ""
    task = recognizer.recognitionTask(with: req) { [weak self] res, err in
      DispatchQueue.main.async {
        guard let self = self, self.active, gen == self.generation else { return }
        if let res = res {
          let text = res.bestTranscription.formattedString
          if !text.isEmpty {
            self.lastText = text
            self.channel.invokeMethod("partial", arguments: text)
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: NelDictation.pause,
                                                     repeats: false) { [weak self] _ in
              self?.commitPhrase(restart: true)
            }
          }
          if res.isFinal { self.commitPhrase(restart: true) }
        } else if err != nil {
          // Nothing heard / recognizer hiccup: listen again shortly.
          self.commitPhrase(restart: false)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.active, gen == self.generation,
                  let r = self.recognizer else { return }
            self.task?.cancel()
            self.startRecognition(r)
          }
        }
      }
    }
  }

  private func commitPhrase(restart: Bool) {
    silenceTimer?.invalidate()
    silenceTimer = nil
    let text = lastText
    lastText = ""
    if !text.isEmpty { channel.invokeMethod("phrase", arguments: text) }
    if restart, active, let r = recognizer {
      task?.cancel()
      startRecognition(r)
    }
  }

  private func stopEngine() {
    guard let engine = audioEngine else { return }
    audioEngine = nil
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
  }

  private func teardown() {
    active = false
    generation += 1
    silenceTimer?.invalidate()
    silenceTimer = nil
    stopEngine()
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    let session = AVAudioSession.sharedInstance()
    if let cat = previousCategory {
      try? session.setCategory(cat, mode: previousMode ?? .default, options: previousOptions)
      previousCategory = nil
    }
  }
}
