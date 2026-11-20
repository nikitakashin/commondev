# commondev for macOS

This directory contains the SwiftUI app, the agent core, and the bundled FreeLLMAPI gateway. Start a chat with Cmd+N and use the folder picker above the message field to choose a project. In a chat without a project folder, commands start in your home directory and file tools accept absolute paths. By default, the agent asks before editing files or running shell commands. Use the model menu beside the message field to choose a model and work mode.

## Installation

The app requires macOS 13 or later. The published 0.1 disk image is for Apple silicon. Open the DMG, drag Commondev.app to Applications, and launch it from there. Running the app directly from a protected folder such as Documents may trigger a macOS privacy prompt. Installation and first launch on a separate clean Mac still need testing.

The app bundles FreeLLMAPI and Node.js. The free model gateway needs network access to prepare its catalog on first launch. Model availability depends on the upstream providers. Project commands may need additional development tools, such as Swift for `swift test`.

## Custom models and file tools

If your endpoint and model support `reasoning_effort`, you can enable it in Settings. The setting defaults to off and resets when you change the endpoint or model. X-High sends `high` to the provider and gives the agent a larger local budget.

Harness² uses the model identity returned by the endpoint. If the server omits the routing header, Harness² associates the experiment with the configured URL and model. A provider change behind that endpoint may go undetected.

The agent reads large UTF-8 files in chunks. The built-in `replace_text` tool supports files up to 1 MB. For a larger file, the agent can propose another editing method and request approval.

## Build locally

Install Xcode Command Line Tools and Git. Building the gateway requires network access. Run these commands from the repository root using fresh output paths.

```sh
bash macos/scripts/build-gateway.sh "$PWD/macos/.build/FreeLLMAPI"
bash macos/scripts/build-app.sh "$PWD/macos/.build/Commondev.app"
open "$PWD/macos/.build/Commondev.app"
```

Each build script requires its destination to be absent. To reuse an existing gateway, set `COMMONDEV_GATEWAY_DIR` and give the app a new destination.

```sh
COMMONDEV_GATEWAY_DIR="$PWD/macos/.build/FreeLLMAPI" \
  bash macos/scripts/build-app.sh "$PWD/macos/.build/Commondev-next.app"
```

The gateway build pins the FreeLLMAPI revision and the Node.js 22 version and verifies the Node.js download checksum. Both scripts build for the host architecture. The app defaults to an optimized release build targeting macOS 13. Set `COMMONDEV_BUILD_CONFIGURATION=debug` for a debug build. Before packaging, the script checks the architecture of the bundled Node.js executable and loads the native SQLite and sharp modules. If these checks fail, rebuild the gateway for the target Mac.

## Signing and third-party notices

The build script applies an ad hoc signature. The 0.1 release has not been notarized by Apple, so Gatekeeper may block its first launch on another Mac. The FreeLLMAPI and Node.js licenses are in `Contents/Resources/FreeLLMAPI` inside the app. Selection of the commondev license and review of third-party distribution terms are still pending.

To inventory the dependencies in a packaged app, run the following command.

```sh
python3 macos/scripts/inventory-licenses.py /path/to/Commondev.app/Contents/Resources/FreeLLMAPI > inventory.json
```

New gateway builds record esbuild inputs in `server-metafile.json`. The companion `server-input-inventory.json` lists the packages, declared licenses, notice files, external imports, and server bundle SHA-256. The inventory script verifies that hash against `server.mjs`. It reports `unavailable` for older builds that lack these records. Rebuild those gateways to obtain an exact input list.

The inventory covers package metadata and nearby license files. The audited arm64 build includes LGPL and MPL dependencies and several packages without their own license files. Reviewing a distribution also requires identifying the native components, their notices, and their corresponding sources.

For the verified sharp-libvips 1.3.2 binary, the app includes the upstream notices and the packaging scripts' license in `Contents/Resources/ThirdParty`, with links to the pinned revision. The libraries in that binary have their own license and source requirements.

Generate a working copy of the collected notices for review with the following command. Review missing texts, native components, and source requirements before using the draft for distribution.

```sh
python3 macos/scripts/draft-notices.py /path/to/Commondev.app/Contents/Resources/FreeLLMAPI > THIRD_PARTY_NOTICES.draft.txt
```

## Development checks

```sh
swift test --package-path macos
bash macos/scripts/verify-demo.sh
python3 -m unittest discover -s macos/Tests/ScriptTests -v
```

The demo copies `Fixtures/FailingCalculator` to a temporary directory. It checks that declining a proposed edit leaves the file intact and that approving the fix makes the next `swift test` pass. The CLI uses a deterministic provider for this scenario. To run it manually, make a copy of the fixture first.

```sh
swift run --package-path macos commondev-cli /path/to/copy/FailingCalculator
```

To test one streaming request against an existing OpenAI-compatible endpoint, use the server's port and model name. Set `COMMONDEV_API_KEY` if the server requires a key.

```sh
swift run --package-path macos commondev-model http://127.0.0.1:8080/v1/chat/completions auto:fast "Hello"
```

For a full agent run, use the app or `commondev-live`.

## Sessions and upgrades

The app stores sessions, gateway data, and gateway logs in `~/Library/Application Support/Commondev/`. One process holds the store lock while the app is running. Opening the app again brings its existing window forward. Quit the old version before opening an upgrade.

On the first save after upgrading from the older storage format, the app writes each chat from `sessions.json` to its own file in `Sessions/`, then writes the new index.

The macOS Keychain stores custom API keys by scheme, host, and port. When upgrading from a build that used a shared key, enter the key once for the intended server. Changing the connection or model pauses queued messages. You can switch back and resume, explicitly send the first queued message through the new connection, or return it to an empty draft. Queued messages from older versions also require a connection choice.
