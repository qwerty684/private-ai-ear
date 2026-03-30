import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _assistantChannel = MethodChannel('aihelper/assistant');
const _transcriptChannel = EventChannel('aihelper/transcript');

const _defaultApiKey = String.fromEnvironment('OPENAI_API_KEY');
const _defaultBaseUrl = String.fromEnvironment(
  'OPENAI_BASE_URL',
  defaultValue: 'https://api.openai.com/v1',
);
const _defaultModel = String.fromEnvironment(
  'AI_MODEL',
  defaultValue: 'gpt-4.1-mini',
);
const _defaultTranscriptionModel = String.fromEnvironment(
  'AI_TRANSCRIPTION_MODEL',
  defaultValue: 'gpt-4o-mini-transcribe',
);

const _recognitionOptions = <RecognitionOption>[
  RecognitionOption(
    id: 'auto-multilingual',
    label: 'Auto multilingual',
    helper:
        'Cloud transcription after stop. Best choice for mixed German, English, and Serbian.',
    languageCode: null,
    localeIdentifier: null,
    enableLocalRecognition: false,
  ),
  RecognitionOption(
    id: 'de-DE',
    label: 'German',
    helper: 'Live Apple speech recognition in German.',
    languageCode: 'de',
    localeIdentifier: 'de-DE',
    enableLocalRecognition: true,
  ),
  RecognitionOption(
    id: 'en-US',
    label: 'English',
    helper: 'Live Apple speech recognition in English.',
    languageCode: 'en',
    localeIdentifier: 'en-US',
    enableLocalRecognition: true,
  ),
  RecognitionOption(
    id: 'sr-cloud',
    label: 'Serbian',
    helper:
        'Cloud transcription after stop. Apple Speech on this Mac does not expose Serbian.',
    languageCode: 'sr',
    localeIdentifier: null,
    enableLocalRecognition: false,
  ),
];

void main() {
  runApp(const AiHelperApp());
}

class AiHelperApp extends StatelessWidget {
  const AiHelperApp({super.key});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFF28B53);
    const sand = Color(0xFFFFF5E8);
    const charcoal = Color(0xFF17181B);

    final colorScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
      surface: sand,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Private AI Ear',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme.copyWith(
          primary: accent,
          secondary: const Color(0xFF2E5B8C),
          surface: sand,
          onSurface: charcoal,
        ),
        scaffoldBackgroundColor: sand,
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.2,
          ),
          titleLarge: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
          bodyLarge: TextStyle(fontSize: 15, height: 1.45),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.82),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: accent, width: 1.4),
          ),
        ),
        cardTheme: CardThemeData(
          color: Colors.white.withValues(alpha: 0.82),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: BorderSide(color: Colors.black.withValues(alpha: 0.05)),
          ),
        ),
      ),
      home: const AssistantHomePage(),
    );
  }
}

class AssistantHomePage extends StatefulWidget {
  const AssistantHomePage({super.key});

  @override
  State<AssistantHomePage> createState() => _AssistantHomePageState();
}

class _AssistantHomePageState extends State<AssistantHomePage> {
  final _client = const AiChatClient();
  final _messages = <AssistantMessage>[];

  StreamSubscription<dynamic>? _transcriptSubscription;
  Timer? _settingsSaveDebounce;

  late final TextEditingController _apiKeyController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _transcriptionModelController;
  late final TextEditingController _transcriptController;
  RecognitionOption _selectedRecognition = _recognitionOptions.first;

  bool _hideFromCapture = true;
  bool _alwaysOnTop = true;
  bool _autoAnswerAfterStop = true;
  bool _miniMode = true;
  bool _showApiKey = false;
  bool _listening = false;
  bool _busy = false;
  String _statusMessage = 'Ready. Ask for mic access, then start listening.';
  String _permissionSummary = 'Not checked yet';

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: _defaultApiKey);
    _baseUrlController = TextEditingController(text: _defaultBaseUrl);
    _modelController = TextEditingController(text: _defaultModel);
    _transcriptionModelController = TextEditingController(
      text: _defaultTranscriptionModel,
    );
    _transcriptController = TextEditingController();
    _apiKeyController.addListener(_scheduleSettingsSave);
    _baseUrlController.addListener(_scheduleSettingsSave);
    _modelController.addListener(_scheduleSettingsSave);
    _transcriptionModelController.addListener(_scheduleSettingsSave);

    _transcriptSubscription = _transcriptChannel
        .receiveBroadcastStream()
        .listen(
          _handleNativeEvent,
          onError: (Object error) {
            _setStatus('Native transcript bridge unavailable: $error');
          },
        );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_applyWindowMode());
      unawaited(_loadPreferences());
    });
  }

  @override
  void dispose() {
    unawaited(_transcriptSubscription?.cancel());
    _settingsSaveDebounce?.cancel();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _transcriptionModelController.dispose();
    _transcriptController.dispose();
    super.dispose();
  }

  Future<void> _applyWindowMode() async {
    try {
      await _assistantChannel.invokeMethod<void>('configureWindow', {
        'hideFromCapture': _hideFromCapture,
        'alwaysOnTop': _alwaysOnTop,
      });
    } on MissingPluginException {
      _setStatus('Window controls only work in the macOS desktop app.');
    } on PlatformException catch (error) {
      _setStatus('Window mode failed: ${error.message ?? error.code}');
    }
  }

  Future<void> _loadPreferences() async {
    try {
      final stored =
          await _assistantChannel.invokeMapMethod<String, dynamic>(
            'loadPreferences',
          ) ??
          const <String, dynamic>{};
      if (!mounted) {
        return;
      }

      final storedApiKey = stored['apiKey']?.toString() ?? '';
      final storedBaseUrl = stored['baseUrl']?.toString() ?? '';
      final storedModel = stored['model']?.toString() ?? '';
      final storedTranscriptionModel =
          stored['transcriptionModel']?.toString() ?? '';
      final storedRecognitionId = stored['recognitionOptionId']?.toString();
      final storedMiniMode = stored['miniMode'];

      setState(() {
        if (_apiKeyController.text.trim().isEmpty && storedApiKey.isNotEmpty) {
          _apiKeyController.text = storedApiKey;
        }
        if (storedBaseUrl.isNotEmpty) {
          _baseUrlController.text = storedBaseUrl;
        }
        if (storedModel.isNotEmpty) {
          _modelController.text = storedModel;
        }
        if (storedTranscriptionModel.isNotEmpty) {
          _transcriptionModelController.text = storedTranscriptionModel;
        }
        if (storedRecognitionId != null) {
          _selectedRecognition = _recognitionOptionById(storedRecognitionId);
        }
        if (storedMiniMode is bool) {
          _miniMode = storedMiniMode;
        } else if (storedMiniMode != null) {
          _miniMode = storedMiniMode.toString() == 'true';
        }
      });
    } on MissingPluginException {
      // Ignore outside macOS app runtime.
    } on PlatformException catch (error) {
      _setStatus(
        'Could not load saved settings: ${error.message ?? error.code}',
      );
    }
  }

  void _scheduleSettingsSave() {
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = Timer(
      const Duration(milliseconds: 350),
      _persistPreferences,
    );
  }

  Future<void> _persistPreferences() async {
    try {
      await _assistantChannel.invokeMethod<void>('savePreferences', {
        'apiKey': _apiKeyController.text.trim(),
        'baseUrl': _baseUrlController.text.trim(),
        'model': _modelController.text.trim(),
        'transcriptionModel': _transcriptionModelController.text.trim(),
        'recognitionOptionId': _selectedRecognition.id,
        'miniMode': _miniMode,
      });
    } on MissingPluginException {
      // Ignore outside macOS app runtime.
    } on PlatformException {
      // Keep the UI usable even if local persistence fails.
    }
  }

  RecognitionOption _recognitionOptionById(String id) {
    return _recognitionOptions.firstWhere(
      (option) => option.id == id,
      orElse: () => _recognitionOptions.first,
    );
  }

  Future<void> _requestPermissions() async {
    try {
      final result =
          await _assistantChannel.invokeMapMethod<String, String>(
            'requestPermissions',
          ) ??
          const <String, String>{};
      if (!mounted) {
        return;
      }
      setState(() {
        _permissionSummary =
            'Mic: ${result['microphone'] ?? 'unknown'}  |  Speech: ${result['speech'] ?? 'unknown'}';
        _statusMessage = 'Permissions updated.';
      });
    } on MissingPluginException {
      _setStatus(
        'Permissions can be requested only from the macOS desktop app.',
      );
    } on PlatformException catch (error) {
      _setStatus('Permission request failed: ${error.message ?? error.code}');
    }
  }

  Future<void> _startListening() async {
    try {
      await _assistantChannel.invokeMethod<void>('startListening', {
        'locale': _selectedRecognition.localeIdentifier,
        'enableLocalRecognition': _selectedRecognition.enableLocalRecognition,
      });
      if (!mounted) {
        return;
      }
      setState(() {
        _listening = true;
        _statusMessage = _selectedRecognition.enableLocalRecognition
            ? 'Listening with ${_selectedRecognition.label} recognition...'
            : 'Recording audio for cloud transcription...';
        _transcriptController.clear();
      });
    } on MissingPluginException {
      _setStatus('Listening is available only in the macOS desktop app.');
    } on PlatformException catch (error) {
      _setStatus('Could not start listening: ${error.message ?? error.code}');
    }
  }

  Future<void> _stopListening() async {
    try {
      final payload =
          await _assistantChannel.invokeMapMethod<String, dynamic>(
            'stopListening',
          ) ??
          const <String, dynamic>{};
      await _completeListeningSession(payload, silenceTriggered: false);
    } on MissingPluginException {
      _setStatus('Listening is available only in the macOS desktop app.');
    } on PlatformException catch (error) {
      _setStatus('Could not stop listening: ${error.message ?? error.code}');
    } on AiChatException catch (error) {
      _setStatus(error.message, busy: false);
    }
  }

  Future<void> _listenAgain() async {
    if (_busy || _listening) {
      return;
    }
    setState(() {
      _transcriptController.clear();
      _statusMessage = 'Listening again...';
    });
    await _startListening();
  }

  Future<void> _completeListeningSession(
    Map<String, dynamic> payload, {
    required bool silenceTriggered,
  }) async {
    final transcript = payload['transcript']?.toString() ?? '';
    final audioPath = payload['audioPath']?.toString();
    final statusMessage = payload['message']?.toString();

    if (!mounted) {
      return;
    }

    var finalTranscript = transcript.trim();
    if (finalTranscript.isEmpty && audioPath != null && audioPath.isNotEmpty) {
      finalTranscript = await _transcribeRecording(audioPath);
    } else if (!_selectedRecognition.enableLocalRecognition &&
        audioPath != null &&
        audioPath.isNotEmpty) {
      finalTranscript = await _transcribeRecording(audioPath);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _listening = false;
      _busy = false;
      if (finalTranscript.isNotEmpty) {
        _transcriptController.text = finalTranscript;
        _transcriptController.selection = TextSelection.fromPosition(
          TextPosition(offset: _transcriptController.text.length),
        );
      }
      _statusMessage =
          statusMessage ??
          (finalTranscript.isEmpty
              ? 'Listening stopped, but no transcript was produced.'
              : silenceTriggered
              ? 'Silence detected. Answering now.'
              : 'Listening stopped. Transcript ready.');
    });

    if (_autoAnswerAfterStop && finalTranscript.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _sendTranscriptToAi(overrideText: finalTranscript);
    }
  }

  Future<String> _transcribeRecording(String audioPath) async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      throw const AiChatException(
        'An API key is required for cloud transcription.',
      );
    }

    setState(() {
      _busy = true;
      _statusMessage = 'Transcribing audio...';
    });

    try {
      final transcript = await _client.createTranscription(
        apiKey: apiKey,
        baseUrl: _baseUrlController.text,
        model: _transcriptionModelController.text,
        audioFile: File(audioPath),
        languageCode: _selectedRecognition.languageCode,
      );
      return transcript;
    } finally {
      unawaited(
        File(audioPath).delete().catchError((Object _) {
          return File(audioPath);
        }),
      );
    }
  }

  Future<void> _sendTranscriptToAi({String? overrideText}) async {
    final transcript = (overrideText ?? _transcriptController.text).trim();
    if (transcript.isEmpty) {
      _setStatus('Add some transcript text first.');
      return;
    }

    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      _setStatus('Add your OpenAI-compatible API key first.');
      return;
    }

    setState(() {
      _busy = true;
      _statusMessage = 'Generating a short answer...';
    });

    try {
      final userMessage = AssistantMessage(
        role: MessageRole.user,
        content: transcript,
        timestamp: DateTime.now(),
      );

      final reply = await _client.createReply(
        apiKey: apiKey,
        baseUrl: _baseUrlController.text,
        model: _modelController.text,
        history: [..._messages, userMessage],
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _messages
          ..add(userMessage)
          ..add(
            AssistantMessage(
              role: MessageRole.assistant,
              content: reply,
              timestamp: DateTime.now(),
            ),
          );
        _busy = false;
        _statusMessage = 'Short answer ready.';
      });
    } on AiChatException catch (error) {
      _setStatus(error.message, busy: false);
    } catch (error) {
      _setStatus('Unexpected AI error: $error', busy: false);
    }
  }

  void _handleNativeEvent(dynamic event) {
    if (!mounted || event is! Map<Object?, Object?>) {
      return;
    }

    final data = event.map((key, value) => MapEntry(key.toString(), value));

    final type = data['type']?.toString();
    switch (type) {
      case 'transcript':
        final text = data['text']?.toString() ?? '';
        setState(() {
          _transcriptController.text = text;
          _transcriptController.selection = TextSelection.fromPosition(
            TextPosition(offset: _transcriptController.text.length),
          );
        });
        break;
      case 'status':
        setState(() {
          _statusMessage = data['message']?.toString() ?? _statusMessage;
          final nativeStatus = data['status']?.toString();
          _listening =
              nativeStatus == 'listening' || nativeStatus == 'recording';
        });
        break;
      case 'auto_stop':
        unawaited(_completeListeningSession(data, silenceTriggered: true));
        break;
      case 'error':
        _setStatus(data['message']?.toString() ?? 'Native audio error.');
        break;
      default:
        break;
    }
  }

  void _setStatus(String message, {bool? busy}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _statusMessage = message;
      _listening = false;
      if (busy != null) {
        _busy = busy;
      }
    });
  }

  AssistantMessage? get _latestAssistantMessage => _messages.lastWhereOrNull(
    (message) => message.role == MessageRole.assistant,
  );

  AssistantMessage? get _latestUserMessage =>
      _messages.lastWhereOrNull((message) => message.role == MessageRole.user);

  String get _currentQuestionText {
    final liveTranscript = _transcriptController.text.trim();
    if (liveTranscript.isNotEmpty) {
      return liveTranscript;
    }
    return _latestUserMessage?.content ??
        'Your question or transcript appears here.';
  }

  Widget _buildModeToggle() {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment<bool>(
          value: true,
          label: Text('Mini'),
          icon: Icon(Icons.picture_in_picture_alt),
        ),
        ButtonSegment<bool>(
          value: false,
          label: Text('Full'),
          icon: Icon(Icons.dashboard_customize),
        ),
      ],
      selected: {_miniMode},
      onSelectionChanged: (selection) {
        final nextValue = selection.first;
        setState(() {
          _miniMode = nextValue;
        });
        unawaited(_persistPreferences());
      },
      showSelectedIcon: false,
    );
  }

  Widget _buildMiniMode(ThemeData theme) {
    final latestReply = _latestAssistantMessage;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Mini call mode',
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      _buildModeToggle(),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Language: ${_selectedRecognition.label}. The app auto-stops when you go quiet, then answers.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _statusMessage,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.black.withValues(alpha: 0.72),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: _listening ? null : _startListening,
                        icon: const Icon(Icons.mic),
                        label: const Text('Start'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _listening ? _stopListening : null,
                        icon: const Icon(Icons.stop_circle),
                        label: const Text('Stop'),
                      ),
                      TextButton.icon(
                        onPressed: _listening || _busy ? null : _listenAgain,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Listen again'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Question', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Text(
                        _currentQuestionText,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('Answer', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: const Color(0xFF17181B),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            latestReply?.content ??
                                'The short answer appears here after you finish speaking.',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: Colors.white,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent(ThemeData theme) {
    if (_miniMode) {
      return _buildMiniMode(theme);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final useCompactLayout =
            constraints.maxWidth < 1100 || constraints.maxHeight < 900;

        if (useCompactLayout) {
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildInputPanel(theme, compact: true),
                const SizedBox(height: 16),
                _buildPrivacyPanel(theme),
                const SizedBox(height: 16),
                _buildSettingsPanel(theme),
                const SizedBox(height: 16),
                _buildAnswersPanel(theme, compact: true),
              ],
            ),
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 6,
              child: Column(
                children: [
                  Expanded(child: _buildInputPanel(theme, compact: false)),
                  const SizedBox(height: 16),
                  _buildPrivacyPanel(theme),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 5,
              child: Column(
                children: [
                  _buildSettingsPanel(theme),
                  const SizedBox(height: 16),
                  Expanded(child: _buildAnswersPanel(theme, compact: false)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildInputPanel(ThemeData theme, {required bool compact}) {
    return _GlassCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final useScrollableBody = compact || constraints.maxHeight < 620;
          final content = Column(
            mainAxisSize: useScrollableBody
                ? MainAxisSize.min
                : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Private input', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Use your microphone directly, or route meeting audio into a loopback input device if you want the assistant to hear speakers.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 18),
              DropdownButtonFormField<String>(
                key: ValueKey(_selectedRecognition.id),
                initialValue: _selectedRecognition.id,
                decoration: const InputDecoration(
                  labelText: 'Recognition language',
                ),
                items: _recognitionOptions
                    .map(
                      (option) => DropdownMenuItem<String>(
                        value: option.id,
                        child: Text(option.label),
                      ),
                    )
                    .toList(),
                onChanged: _listening
                    ? null
                    : (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          _selectedRecognition = _recognitionOptionById(value);
                        });
                        unawaited(_persistPreferences());
                      },
              ),
              const SizedBox(height: 8),
              Text(
                _selectedRecognition.helper,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _listening ? null : _startListening,
                    icon: const Icon(Icons.mic),
                    label: const Text('Start listening'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _listening ? _stopListening : null,
                    icon: const Icon(Icons.stop_circle),
                    label: const Text('Stop'),
                  ),
                  TextButton.icon(
                    onPressed: _listening || _busy ? null : _listenAgain,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Listen again'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _requestPermissions,
                    icon: const Icon(Icons.security),
                    label: const Text('Setup access'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                _permissionSummary,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.black.withValues(alpha: 0.68),
                ),
              ),
              const SizedBox(height: 18),
              if (useScrollableBody)
                SizedBox(height: 180, child: _buildTranscriptField())
              else
                Expanded(child: _buildTranscriptField()),
              const SizedBox(height: 16),
              if (useScrollableBody)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tip: share a single app window in Zoom or Meet. When you stop talking for a moment, the app should answer automatically.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                )
              else
                Text(
                  'Tip: share a single app window in Zoom or Meet. When you stop talking for a moment, the app should answer automatically.',
                  style: theme.textTheme.bodyMedium,
                ),
            ],
          );

          if (useScrollableBody) {
            return SingleChildScrollView(child: content);
          }

          return content;
        },
      ),
    );
  }

  Widget _buildTranscriptField() {
    return TextField(
      controller: _transcriptController,
      expands: true,
      maxLines: null,
      minLines: null,
      textAlignVertical: TextAlignVertical.top,
      decoration: const InputDecoration(
        hintText: 'Transcript appears here. You can edit it before sending.',
      ),
    );
  }

  Widget _buildPrivacyPanel(ThemeData theme) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Privacy window mode', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'This app stays in its own window, floats above other apps, and asks macOS not to expose its contents to window capture.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hide from screen capture'),
            subtitle: const Text(
              'Uses the native window sharing lock on macOS.',
            ),
            value: _hideFromCapture,
            onChanged: (value) {
              setState(() {
                _hideFromCapture = value;
              });
              unawaited(_applyWindowMode());
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep window on top'),
            subtitle: const Text('Useful while you share another app window.'),
            value: _alwaysOnTop,
            onChanged: (value) {
              setState(() {
                _alwaysOnTop = value;
              });
              unawaited(_applyWindowMode());
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto-answer after stop'),
            subtitle: const Text(
              'When you stop listening or go quiet, send the transcript immediately.',
            ),
            value: _autoAnswerAfterStop,
            onChanged: (value) {
              setState(() {
                _autoAnswerAfterStop = value;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsPanel(ThemeData theme) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AI settings', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKeyController,
            obscureText: !_showApiKey,
            decoration: InputDecoration(
              labelText: 'API key',
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() {
                    _showApiKey = !_showApiKey;
                  });
                },
                icon: Icon(
                  _showApiKey ? Icons.visibility_off : Icons.visibility,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrlController,
            decoration: const InputDecoration(labelText: 'Base URL'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelController,
            decoration: const InputDecoration(labelText: 'Model'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _transcriptionModelController,
            decoration: const InputDecoration(labelText: 'Transcription model'),
          ),
          const SizedBox(height: 12),
          Text(
            'The key and models are saved locally on this Mac. German and English can use Apple live recognition; Serbian and auto mode use cloud transcription after you stop.',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildAnswersPanel(ThemeData theme, {required bool compact}) {
    final latestReply = _messages.lastWhereOrNull(
      (message) => message.role == MessageRole.assistant,
    );

    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Latest answer', style: theme.textTheme.titleLarge),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF17181B),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Text(
              latestReply?.content ?? 'Your short answer will appear here.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: Colors.white,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (compact)
            SizedBox(height: 240, child: _buildConversationList())
          else
            Expanded(child: _buildConversationList()),
        ],
      ),
    );
  }

  Widget _buildConversationList() {
    return SelectionArea(
      child: ListView.separated(
        itemCount: _messages.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final message = _messages[index];
          return _ConversationTile(message: message);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFF7EC), Color(0xFFF7E6D7), Color(0xFFEFE1D8)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    if (!_miniMode) ...[
                      _HeroHeader(
                        listening: _listening,
                        busy: _busy,
                        statusMessage: _statusMessage,
                        trailing: _buildModeToggle(),
                      ),
                      const SizedBox(height: 18),
                    ],
                    Expanded(child: _buildMainContent(theme)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.listening,
    required this.busy,
    required this.statusMessage,
    this.trailing,
  });

  final bool listening;
  final bool busy;
  final String statusMessage;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final indicatorColor = listening
        ? const Color(0xFFE85D3F)
        : busy
        ? const Color(0xFFF0B14A)
        : const Color(0xFF3B7D4D);

    return _GlassCard(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Private AI Ear', style: theme.textTheme.headlineLarge),
                const SizedBox(height: 6),
                Text(
                  'A compact desktop copilot for meetings, interviews, and live calls.',
                  style: theme.textTheme.bodyLarge,
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 16), trailing!],
          const SizedBox(width: 16),
          Container(
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: indicatorColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(statusMessage, style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({
    required this.child,
    this.padding = const EdgeInsets.all(22),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.85),
              Colors.white.withValues(alpha: 0.72),
            ],
          ),
        ),
        padding: padding,
        child: child,
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.message});

  final AssistantMessage message;

  @override
  Widget build(BuildContext context) {
    final isAssistant = message.role == MessageRole.assistant;
    final bubbleColor = isAssistant
        ? const Color(0xFFFFE3CF)
        : const Color(0xFFEBF2FA);

    return Align(
      alignment: isAssistant ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          crossAxisAlignment: isAssistant
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Text(
              isAssistant ? 'Assistant' : 'You',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              message.content,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class RecognitionOption {
  const RecognitionOption({
    required this.id,
    required this.label,
    required this.helper,
    required this.languageCode,
    required this.localeIdentifier,
    required this.enableLocalRecognition,
  });

  final String id;
  final String label;
  final String helper;
  final String? languageCode;
  final String? localeIdentifier;
  final bool enableLocalRecognition;
}

enum MessageRole { user, assistant }

class AssistantMessage {
  const AssistantMessage({
    required this.role,
    required this.content,
    required this.timestamp,
  });

  final MessageRole role;
  final String content;
  final DateTime timestamp;
}

class AiChatException implements Exception {
  const AiChatException(this.message);

  final String message;
}

class AiChatClient {
  const AiChatClient();

  Future<String> createReply({
    required String apiKey,
    required String baseUrl,
    required String model,
    required List<AssistantMessage> history,
  }) async {
    final trimmedBaseUrl = _normalizedBaseUrl(baseUrl);
    if (model.trim().isEmpty) {
      throw const AiChatException('Model is required.');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.postUrl(
        Uri.parse('$trimmedBaseUrl/chat/completions'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');

      final recentHistory = history.length <= 6
          ? history
          : history.sublist(history.length - 6);

      final messages = <Map<String, String>>[
        const {
          'role': 'system',
          'content':
              'You are a private meeting copilot. Answer in one or two short sentences, under 45 words. Be direct, useful, and calm. If the transcript is unclear, ask for the single most important missing detail in under 12 words.',
        },
        ...recentHistory.map(
          (message) => {
            'role': message.role == MessageRole.assistant
                ? 'assistant'
                : 'user',
            'content': message.content,
          },
        ),
      ];

      request.add(
        utf8.encode(
          jsonEncode({
            'model': model.trim(),
            'messages': messages,
            'max_tokens': 120,
          }),
        ),
      );

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiChatException(
          _extractErrorMessage(responseBody) ??
              'AI request failed with status ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, dynamic>) {
        throw const AiChatException('Unexpected AI response shape.');
      }

      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const AiChatException('AI response did not contain any choices.');
      }

      final firstChoice = choices.first;
      if (firstChoice is! Map<String, dynamic>) {
        throw const AiChatException('AI response choice was invalid.');
      }

      final message = firstChoice['message'];
      if (message is! Map<String, dynamic>) {
        throw const AiChatException('AI response message was missing.');
      }

      final content = message['content'];
      final text = switch (content) {
        String value => value,
        List<dynamic> value =>
          value
              .whereType<Map<String, dynamic>>()
              .map((part) => part['text']?.toString() ?? '')
              .join(' ')
              .trim(),
        _ => '',
      };

      final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (cleaned.isEmpty) {
        throw const AiChatException('AI response was empty.');
      }
      return cleaned;
    } on SocketException {
      throw const AiChatException('Network error while contacting the AI API.');
    } on HandshakeException {
      throw const AiChatException('TLS handshake failed for the AI API.');
    } on FormatException {
      throw const AiChatException('AI response was not valid JSON.');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> createTranscription({
    required String apiKey,
    required String baseUrl,
    required String model,
    required File audioFile,
    required String? languageCode,
  }) async {
    final trimmedBaseUrl = _normalizedBaseUrl(baseUrl);
    if (model.trim().isEmpty) {
      throw const AiChatException('Transcription model is required.');
    }
    if (!await audioFile.exists()) {
      throw const AiChatException('Recorded audio file was not found.');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.postUrl(
        Uri.parse('$trimmedBaseUrl/audio/transcriptions'),
      );
      final boundary =
          '----private-ai-ear-${DateTime.now().millisecondsSinceEpoch}';
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );

      final audioBytes = await audioFile.readAsBytes();
      final fileName = audioFile.uri.pathSegments.isEmpty
          ? 'recording.wav'
          : audioFile.uri.pathSegments.last;
      final body = BytesBuilder();

      void writeTextField(String name, String value) {
        body.add(utf8.encode('--$boundary\r\n'));
        body.add(
          utf8.encode(
            'Content-Disposition: form-data; name="$name"\r\n\r\n$value\r\n',
          ),
        );
      }

      writeTextField('model', model.trim());
      writeTextField('response_format', 'json');
      if (languageCode != null && languageCode.isNotEmpty) {
        writeTextField('language', languageCode);
      }

      body.add(utf8.encode('--$boundary\r\n'));
      body.add(
        utf8.encode(
          'Content-Disposition: form-data; name="file"; filename="$fileName"\r\n',
        ),
      );
      body.add(utf8.encode('Content-Type: audio/wav\r\n\r\n'));
      body.add(audioBytes);
      body.add(utf8.encode('\r\n--$boundary--\r\n'));

      request.add(body.takeBytes());

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiChatException(
          _extractErrorMessage(responseBody) ??
              'Transcription failed with status ${response.statusCode}.',
        );
      }

      final decoded = _parseJsonMap(responseBody);
      final text = decoded['text']?.toString().trim() ?? '';
      if (text.isEmpty) {
        throw const AiChatException('Transcription response was empty.');
      }
      return text.replaceAll(RegExp(r'\s+'), ' ').trim();
    } on SocketException {
      throw const AiChatException(
        'Network error while contacting the transcription API.',
      );
    } on HandshakeException {
      throw const AiChatException(
        'TLS handshake failed for transcription API.',
      );
    } on FormatException {
      throw const AiChatException('Transcription response was not valid JSON.');
    } finally {
      client.close(force: true);
    }
  }

  String _normalizedBaseUrl(String baseUrl) {
    final trimmedBaseUrl = baseUrl.trim().replaceFirst(RegExp(r'/$'), '');
    if (trimmedBaseUrl.isEmpty) {
      throw const AiChatException('Base URL is required.');
    }
    return trimmedBaseUrl;
  }

  Map<String, dynamic> _parseJsonMap(String responseBody) {
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, dynamic>) {
      throw const AiChatException('Unexpected AI response shape.');
    }
    return decoded;
  }

  String? _extractErrorMessage(String responseBody) {
    try {
      final decoded = _parseJsonMap(responseBody);
      final error = decoded['error'];
      if (error is Map<String, dynamic>) {
        final message = error['message']?.toString();
        if (message != null && message.isNotEmpty) {
          return message;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T element) test) {
    for (var index = length - 1; index >= 0; index -= 1) {
      final element = this[index];
      if (test(element)) {
        return element;
      }
    }
    return null;
  }
}
