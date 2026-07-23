# redapp

redapp is a SwiftUI Reddit client for iPad and macOS. It uses Reddit's personal
API and adds tools for summarizing posts and comments, asking follow-up
questions, comparing communities, saving research, and listening to generated
reports.

## Features

- Browse subreddit feeds using personal Reddit API credentials
- Read posts and comment threads
- Summarize loaded posts and comments
- Ask grounded follow-up questions about Reddit content
- Save reports in the Research Library
- Compare saved reports, feeds, and communities
- Use remote AI providers or supported local MLX models
- Listen to reports with system, remote, or supported local speech engines
- Keep selected summary information available through the widget

Provider and model availability depends on the platform, device, build
configuration, and credentials configured in the app.

## Requirements

- Xcode with the iOS 26 and macOS 26 SDKs
- An Apple development team for signing
- Reddit personal API credentials
- Credentials for any remote AI provider you choose to use
- Apple silicon for MLX-backed local inference

No API keys or model weights are included in this repository.

## Build the iPad app

1. Open `redapp2.xcodeproj`.
2. Let Xcode resolve the Swift package dependencies.
3. Select the `redapp` scheme and an iPad simulator or device.
4. Set your development team if Xcode requests it.
5. Build and run.
6. Add your Reddit and AI-provider credentials in the app's settings.

## Build the macOS app

1. Open `mac/redapp2.xcodeproj`.
2. Let Xcode resolve the Swift package dependencies.
3. Select the macOS `redapp` target.
4. Set your development team if required.
5. Build and run.

The macOS app includes a helper used by scheduled summaries. Xcode builds and
signs that helper as part of the app target.

## Project layout

- `redapp/` — iPad application source
- `redappw/` — widget extension
- `redappTests/` and `redappUITests/` — iPad tests
- `mac/redapp/` — macOS application source
- `mac/SchedulerAgent/` — scheduled-summary helper
- `mac/redappTests/` — macOS tests
- `Shared/` — code shared with the widget

## Privacy and credentials

Configure credentials through the app. Do not commit API keys, Reddit client
secrets, downloaded model weights, provisioning profiles, export-option files,
or signing certificates.

Reddit content and prompts may be sent to the remote provider selected in the
app. Local-provider modes have different capabilities and device requirements.
Review the provider's privacy terms before using it with sensitive material.

## License

The original source code in this repository is available under the
[MIT License](LICENSE).

Third-party packages, services, model weights, fonts, voices, Reddit content,
and other external assets remain subject to their own licenses and terms. The
MIT License for this repository does not grant rights to redistribute those
third-party materials.
