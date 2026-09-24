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

// NelDesk: one-tap dictation. While controlling the Mac there is no text field,
// so the iPadOS dictation mic never shows up. This listens with the Speech
// framework (Spanish) and hands the text to Flutter, which types it on the Mac.
// Channel "neldesk/dictation": start -> true | error, stop -> final text.
// Native -> Dart: "partial"(text) while listening, "ended"(text) if iOS stops
// by itself (errors, ~1 min limit). The final text is delivered exactly once.
final class NelDictation {
  private let channel: FlutterMethodChannel
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
  // Created per dictation, after the session switches to record: an engine made
  // while the session was playback-only has an input with no format (0 Hz) and
  // installTap raises an uncatchable NSException (crash 24-sep-2026).
  private var audioEngine: AVAudioEngine?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var lastText = ""
  private var pendingStop: FlutterResult?
  private var delivered = true
  private var previousCategory: AVAudioSession.Category?
  private var previousMode: AVAudioSession.Mode?
  private var previousOptions: AVAudioSession.CategoryOptions = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "neldesk/dictation", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "start": self.start(result)
      case "stop": self.stop(result)
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

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    if #available(iOS 16.0, *) { req.addsPunctuation = true }
    request = req
    lastText = ""
    delivered = false

    let engine = AVAudioEngine()
    audioEngine = engine
    let input = engine.inputNode
    let hwFormat = input.inputFormat(forBus: 0)
    guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
      throw NSError(domain: "NelDictation", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "El micrófono no está disponible"])
    }
    // nil format = the node's own format, so it always matches the hardware.
    input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
      req.append(buffer)
    }
    engine.prepare()
    try engine.start()

    task = recognizer.recognitionTask(with: req) { [weak self] res, err in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if let res = res {
          self.lastText = res.bestTranscription.formattedString
          if !res.isFinal { self.channel.invokeMethod("partial", arguments: self.lastText) }
        }
        if err != nil || (res?.isFinal ?? false) { self.finish() }
      }
    }
  }

  private func stop(_ result: @escaping FlutterResult) {
    if delivered { result(""); return }
    pendingStop = result
    stopEngine()
    request?.endAudio()
    // Give the recognizer a moment to settle the last words.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish() }
  }

  private func finish() {
    if delivered { return }
    delivered = true
    let text = lastText
    if let r = pendingStop {
      pendingStop = nil
      r(text)
    } else {
      channel.invokeMethod("ended", arguments: text)
    }
    teardown()
  }

  private func stopEngine() {
    guard let engine = audioEngine else { return }
    audioEngine = nil
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
  }

  private func teardown() {
    stopEngine()
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
