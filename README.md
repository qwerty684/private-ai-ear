# Private AI Ear

Experimental, macOS-first Flutter desktop copilot for live calls, meetings, and interviews.

Private AI Ear listens to a selected macOS input source, turns speech into text, sends that transcript to an OpenAI-compatible API, and shows short, glanceable answers in a floating desktop window.

## Project status

This is an experimental open-source project. Expect rough edges, changing behavior, and platform-specific limitations. It is being shared so other builders can explore, improve, and adapt the idea.

## Bring your own API

This project does not include a hosted backend, bundled credits, or shared API access.

To run it, you need to provide your own:

- API key
- Base URL
- Chat model
- Transcription model, if you want cloud transcription

It is designed for OpenAI-compatible APIs, including OpenAI itself or compatible gateways that expose similar chat and transcription endpoints.

## What it does

- Captures audio from your current macOS input device
- Uses Apple Speech for supported live locales, with cloud transcription available for mixed-language or unsupported cases
- Sends transcripts to an OpenAI-compatible chat endpoint
- Shows concise answers in a floating, always-available desktop window
- Stores in-app API credentials locally in the macOS Keychain

## Privacy window behavior

Private AI Ear is built around a separate floating macOS window. When enabled, the app asks macOS not to expose that window to standard window capture by using the native window sharing restriction.

- It works best when you share a single app window in Zoom, Google Meet, or Microsoft Teams.
- Full-display sharing and third-party capture tools may behave differently.
- This behavior is best effort only and should not be treated as a guarantee that the window will never appear in a recording or share.

Use this project only in ways that are lawful, allowed by the platform you are using, and appropriate for your workplace, school, or meeting context.

## Audio input

By default, the app listens to the currently selected macOS input device.

- For your own voice, use your normal microphone.
- For speaker or meeting audio, route system output into a loopback input such as BlackHole or Loopback and set that device as the active input.

## Quick start

1. Install Flutter and confirm macOS desktop support is available.
2. Run `flutter pub get`.
3. Start the macOS app with your own API key:

```bash
flutter run -d macos --dart-define=OPENAI_API_KEY=your_key_here
```

Optional:

```bash
flutter run -d macos \
  --dart-define=OPENAI_BASE_URL=https://api.openai.com/v1 \
  --dart-define=AI_MODEL=gpt-4.1-mini \
  --dart-define=AI_TRANSCRIPTION_MODEL=gpt-4o-mini-transcribe
```

You can also enter the API key, base URL, and model values directly in the app UI.

## Permissions

On first launch, macOS should request:

- Microphone access
- Speech recognition access

If you deny them, re-enable them in System Settings before testing again.

## Sponsoring

If you want to support this project and future experiments, you can sponsor the work here:

- [GitHub Sponsors](https://github.com/sponsors/qwerty684)

## License

[MIT](LICENSE)
