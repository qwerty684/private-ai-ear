import AVFoundation
import Cocoa
import FlutterMacOS
import Security
import Speech

class MainFlutterWindow: NSWindow {
  private var assistantBridge: AssistantBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    assistantBridge = AssistantBridge(
      messenger: flutterViewController.engine.binaryMessenger,
      window: self
    )
    assistantBridge?.configureWindow(hideFromCapture: true, alwaysOnTop: true)

    super.awakeFromNib()
  }
}

final class AssistantBridge: NSObject, FlutterStreamHandler {
  private weak var window: NSWindow?
  private let speechController = SpeechController()
  private let preferenceStore = PreferenceStore()
  private var eventSink: FlutterEventSink?

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    super.init()

    let methodChannel = FlutterMethodChannel(
      name: "aihelper/assistant",
      binaryMessenger: messenger
    )
    let eventChannel = FlutterEventChannel(
      name: "aihelper/transcript",
      binaryMessenger: messenger
    )

    eventChannel.setStreamHandler(self)
    speechController.onEvent = { [weak self] event in
      self?.eventSink?(event)
    }

    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func configureWindow(hideFromCapture: Bool, alwaysOnTop: Bool) {
    guard let window else {
      return
    }

    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.backgroundColor = .clear
    window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
    window.level = alwaysOnTop ? .floating : .normal
    window.sharingType = hideFromCapture ? .none : .readOnly
    window.minSize = NSSize(width: 960, height: 700)
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configureWindow":
      let arguments = call.arguments as? [String: Any]
      configureWindow(
        hideFromCapture: arguments?["hideFromCapture"] as? Bool ?? true,
        alwaysOnTop: arguments?["alwaysOnTop"] as? Bool ?? true
      )
      result(nil)

    case "loadPreferences":
      result(preferenceStore.load())

    case "savePreferences":
      let arguments = call.arguments as? [String: Any] ?? [:]
      preferenceStore.save(arguments)
      result(nil)

    case "requestPermissions":
      requestPermissions(result: result)

    case "startListening":
      let arguments = call.arguments as? [String: Any]
      do {
        try speechController.startListening(
          localeIdentifier: arguments?["locale"] as? String,
          enableLocalRecognition: arguments?["enableLocalRecognition"] as? Bool ?? true
        )
        result(nil)
      } catch let error as SpeechControllerError {
        result(
          FlutterError(
            code: error.code,
            message: error.message,
            details: nil
          )
        )
      } catch {
        result(
          FlutterError(
            code: "start_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }

    case "stopListening":
      result(speechController.stopListening())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestPermissions(result: @escaping FlutterResult) {
    requestMicrophonePermission { microphoneStatus in
      self.requestSpeechPermission { speechStatus in
        DispatchQueue.main.async {
          result(
            [
              "speech": speechStatus,
              "microphone": microphoneStatus
            ]
          )
        }
      }
    }
  }

  private func requestMicrophonePermission(completion: @escaping (String) -> Void) {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    guard status == .notDetermined else {
      completion(microphoneAuthorizationLabel(status))
      return
    }

    AVCaptureDevice.requestAccess(for: .audio) { granted in
      completion(granted ? "authorized" : "denied")
    }
  }

  private func requestSpeechPermission(completion: @escaping (String) -> Void) {
    let status = SFSpeechRecognizer.authorizationStatus()
    guard status == .notDetermined else {
      completion(speechAuthorizationLabel(status))
      return
    }

    SFSpeechRecognizer.requestAuthorization { status in
      completion(self.speechAuthorizationLabel(status))
    }
  }

  private func speechAuthorizationLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch status {
    case .authorized:
      return "authorized"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .notDetermined:
      return "not determined"
    @unknown default:
      return "unknown"
    }
  }

  private func microphoneAuthorizationLabel(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized:
      return "authorized"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .notDetermined:
      return "not determined"
    @unknown default:
      return "unknown"
    }
  }
}

struct SpeechControllerError: Error {
  let code: String
  let message: String
}

final class SpeechController {
  var onEvent: (([String: Any]) -> Void)?

  private let audioEngine = AVAudioEngine()
  private var hasInstalledTap = false
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var speechRecognizer: SFSpeechRecognizer?
  private var recordingFile: AVAudioFile?
  private var recordingURL: URL?
  private var transcript = ""
  private var localRecognitionEnabled = true
  private let silenceThreshold: Float = 0.015
  private let silenceDuration: TimeInterval = 1.0
  private var silenceWorkItem: DispatchWorkItem?
  private var hasDetectedSpeech = false
  private var isSessionActive = false
  private var isStopping = false

  func startListening(localeIdentifier: String?, enableLocalRecognition: Bool) throws {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw SpeechControllerError(
        code: "microphone_permission",
        message: "Microphone permission is required."
      )
    }

    if enableLocalRecognition && SFSpeechRecognizer.authorizationStatus() != .authorized {
      throw SpeechControllerError(
        code: "speech_permission",
        message: "Speech recognition permission is required for live local transcription."
      )
    }

    deleteRecordingIfNeeded()
    cleanUpRecognition()

    localRecognitionEnabled = enableLocalRecognition
    transcript = ""
    hasDetectedSpeech = false
    isSessionActive = true
    isStopping = false

    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    let recordingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("private-ai-ear-\(UUID().uuidString)")
      .appendingPathExtension("wav")

    do {
      recordingFile = try AVAudioFile(
        forWriting: recordingURL,
        settings: inputFormat.settings,
        commonFormat: inputFormat.commonFormat,
        interleaved: inputFormat.isInterleaved
      )
      self.recordingURL = recordingURL
    } catch {
      throw SpeechControllerError(
        code: "recording_setup_failed",
        message: "Could not prepare audio recording: \(error.localizedDescription)"
      )
    }

    if enableLocalRecognition {
      let locale = localeIdentifier.flatMap(Locale.init(identifier:))
      speechRecognizer =
        locale.flatMap(SFSpeechRecognizer.init(locale:))
        ?? SFSpeechRecognizer(locale: Locale.current)

      guard let speechRecognizer else {
        throw SpeechControllerError(
          code: "speech_unavailable",
          message: "No speech recognizer is available for this locale."
        )
      }

      guard speechRecognizer.isAvailable else {
        throw SpeechControllerError(
          code: "speech_busy",
          message: "Speech recognizer is currently unavailable."
        )
      }

      recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
      guard let recognitionRequest else {
        throw SpeechControllerError(
          code: "request_failed",
          message: "Could not create a speech recognition request."
        )
      }

      recognitionRequest.shouldReportPartialResults = true
      recognitionRequest.requiresOnDeviceRecognition = false
    }

    if hasInstalledTap {
      inputNode.removeTap(onBus: 0)
      hasInstalledTap = false
    }

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
      [weak self] buffer, _ in
      guard let self else {
        return
      }

      do {
        try self.recordingFile?.write(from: buffer)
      } catch {
        self.onEvent?(
          [
            "type": "error",
            "message": "Could not write recorded audio: \(error.localizedDescription)"
          ]
        )
      }

      self.recognitionRequest?.append(buffer)
      self.handleSilenceDetection(buffer)
    }
    hasInstalledTap = true

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      cleanUpRecognition()
      throw SpeechControllerError(
        code: "audio_start_failed",
        message: "Could not start audio capture: \(error.localizedDescription)"
      )
    }

    onEvent?(
      [
        "type": "status",
        "status": enableLocalRecognition ? "listening" : "recording",
        "message": enableLocalRecognition
          ? "Listening with local speech recognition..."
          : "Recording audio for cloud transcription..."
      ]
    )

    guard enableLocalRecognition, let recognitionRequest, let speechRecognizer else {
      return
    }

    recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) {
      [weak self] result, error in
      guard let self else {
        return
      }

      if let result {
        self.transcript = result.bestTranscription.formattedString
        self.onEvent?(
          [
            "type": "transcript",
            "text": self.transcript,
            "isFinal": result.isFinal
          ]
        )

        if result.isFinal {
          self.onEvent?(
            [
              "type": "status",
              "status": "listening",
              "message": "Transcript updated. Waiting for more speech..."
            ]
          )
        }
      }

      if let error {
        self.onEvent?(
          [
            "type": "error",
            "message": error.localizedDescription
          ]
        )
        self.cleanUpRecognition()
      }
    }
  }

  func stopListening(
    emitStatus: Bool = true,
    message: String? = nil
  ) -> [String: Any] {
    isStopping = true
    let payload = buildStopPayload(message: message)

    cleanUpRecognition()

    if emitStatus {
      onEvent?(
        [
          "type": "status",
          "status": "idle",
          "message": message ?? "Listening stopped. Transcript ready."
        ]
      )
    }

    return payload
  }

  private func cleanUpRecognition() {
    silenceWorkItem?.cancel()
    silenceWorkItem = nil
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if hasInstalledTap {
      audioEngine.inputNode.removeTap(onBus: 0)
      hasInstalledTap = false
    }
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    speechRecognizer = nil
    recordingFile = nil
    isSessionActive = false
    isStopping = false
  }

  private func deleteRecordingIfNeeded() {
    if let recordingURL {
      try? FileManager.default.removeItem(at: recordingURL)
      self.recordingURL = nil
    }
  }

  private func buildStopPayload(message: String? = nil) -> [String: Any] {
    var payload: [String: Any] = [
      "transcript": transcript.trimmingCharacters(in: .whitespacesAndNewlines),
      "audioPath": recordingURL?.path ?? "",
      "usedLocalRecognition": localRecognitionEnabled
    ]
    if let message {
      payload["message"] = message
    }
    return payload
  }

  private func handleSilenceDetection(_ buffer: AVAudioPCMBuffer) {
    let level = rmsLevel(for: buffer)
    if level > silenceThreshold {
      hasDetectedSpeech = true
      silenceWorkItem?.cancel()
      silenceWorkItem = nil
      return
    }

    guard hasDetectedSpeech, isSessionActive, !isStopping else {
      return
    }
    guard silenceWorkItem == nil else {
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      self?.handleSilenceTimeout()
    }
    silenceWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + silenceDuration,
      execute: workItem
    )
  }

  private func handleSilenceTimeout() {
    silenceWorkItem = nil

    guard hasDetectedSpeech, isSessionActive, !isStopping else {
      return
    }

    let message = "Silence detected. Answering now."
    let payload = stopListening(emitStatus: false, message: message)
    var event = payload
    event["type"] = "auto_stop"
    event["message"] = message
    onEvent?(event)
  }

  private func rmsLevel(for buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.floatChannelData else {
      return 0
    }

    let channelCount = Int(buffer.format.channelCount)
    let frameLength = Int(buffer.frameLength)
    guard channelCount > 0, frameLength > 0 else {
      return 0
    }

    var total: Float = 0
    var sampleCount = 0

    for channel in 0..<channelCount {
      let samples = channelData[channel]
      for frame in 0..<frameLength {
        let value = samples[frame]
        total += value * value
        sampleCount += 1
      }
    }

    guard sampleCount > 0 else {
      return 0
    }

    return sqrt(total / Float(sampleCount))
  }
}

final class PreferenceStore {
  private enum DefaultsKey {
    static let apiKeyFallback = "api_key_fallback"
    static let baseURL = "base_url"
    static let model = "chat_model"
    static let transcriptionModel = "transcription_model"
    static let recognitionOptionID = "recognition_option_id"
    static let miniMode = "mini_mode"
  }

  private let defaults = UserDefaults.standard
  private let keychain = KeychainStore(service: "aihelper.private_ai_ear")

  func load() -> [String: String] {
    var values: [String: String] = [:]

    if let apiKey = keychain.read(account: "openai_api_key"), !apiKey.isEmpty {
      values["apiKey"] = apiKey
    } else if let apiKey = defaults.string(forKey: DefaultsKey.apiKeyFallback), !apiKey.isEmpty {
      values["apiKey"] = apiKey
    }
    if let baseURL = defaults.string(forKey: DefaultsKey.baseURL), !baseURL.isEmpty {
      values["baseUrl"] = baseURL
    }
    if let model = defaults.string(forKey: DefaultsKey.model), !model.isEmpty {
      values["model"] = model
    }
    if let transcriptionModel = defaults.string(forKey: DefaultsKey.transcriptionModel),
      !transcriptionModel.isEmpty
    {
      values["transcriptionModel"] = transcriptionModel
    }
    if let recognitionOptionID = defaults.string(forKey: DefaultsKey.recognitionOptionID),
      !recognitionOptionID.isEmpty
    {
      values["recognitionOptionId"] = recognitionOptionID
    }
    if defaults.object(forKey: DefaultsKey.miniMode) != nil {
      values["miniMode"] = defaults.bool(forKey: DefaultsKey.miniMode) ? "true" : "false"
    }

    return values
  }

  func save(_ values: [String: Any]) {
    if let apiKey = values["apiKey"] as? String {
      let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        keychain.delete(account: "openai_api_key")
        defaults.removeObject(forKey: DefaultsKey.apiKeyFallback)
      } else {
        let didSaveToKeychain = keychain.write(trimmed, account: "openai_api_key")
        if didSaveToKeychain {
          defaults.removeObject(forKey: DefaultsKey.apiKeyFallback)
        } else {
          defaults.set(trimmed, forKey: DefaultsKey.apiKeyFallback)
        }
      }
    }

    if let baseURL = values["baseUrl"] as? String {
      defaults.set(baseURL, forKey: DefaultsKey.baseURL)
    }
    if let model = values["model"] as? String {
      defaults.set(model, forKey: DefaultsKey.model)
    }
    if let transcriptionModel = values["transcriptionModel"] as? String {
      defaults.set(transcriptionModel, forKey: DefaultsKey.transcriptionModel)
    }
    if let recognitionOptionID = values["recognitionOptionId"] as? String {
      defaults.set(recognitionOptionID, forKey: DefaultsKey.recognitionOptionID)
    }
    if let miniMode = values["miniMode"] as? Bool {
      defaults.set(miniMode, forKey: DefaultsKey.miniMode)
    }
  }
}

final class KeychainStore {
  private let service: String

  init(service: String) {
    self.service = service
  }

  @discardableResult
  func write(_ value: String, account: String) -> Bool {
    delete(account: account)

    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data
    ]

    let status = SecItemAdd(query as CFDictionary, nil)
    return status == errSecSuccess
  }

  func read(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]

    SecItemDelete(query as CFDictionary)
  }
}
