# commondev

Commondev (Commonwealth of Developers) is a native macOS coding agent. Give it a project folder and a task like “Find the failing test, fix the cause, and run the test again.” It can inspect the code, show you a proposed diff, and run the project’s own tools. By default, it asks before changing files or running shell commands.

**[Download Commondev 0.1 for Mac](https://github.com/nikitakashin/commondev/releases/download/v0.1/Commondev-0.1-macOS-arm64.dmg)** · Apple silicon (M1 or later) · macOS 13 or later

Open the DMG, drag **Commondev.app** to **Applications**, and launch it from there. This build has an ad hoc signature and has not been notarized by Apple. Gatekeeper may block the first launch. The release page includes the download checksum. [Release notes](https://github.com/nikitakashin/commondev/releases/tag/v0.1)

## Your first chat

The 0.1 interface is primarily in Russian. Voice dictation supports Russian and English.

1. Press **Cmd+N**. Choose a project folder above the message field. For a task outside a project, you can leave the folder empty.
2. Use the bundled FreeLLMAPI gateway to try free models without adding a key. To use your own model, select a custom connection in Settings and enter its OpenAI-compatible chat completions URL, model name, and API key if required.
3. Type or dictate a task, then press **Enter** to send. **Shift+Enter** adds a line. Expand the actions row beneath your message to inspect tool calls and results.

Commondev saves chat history on your Mac. The selected model provider receives the conversation context, including attached file contents and tool results. The bundled gateway needs network access, and free model availability depends on upstream providers.

## Ways to work

- **Plan mode** lets the agent inspect a project and propose an approach. Switch back to implementation when you want it to make changes.
- **Ultracode** splits a task into research questions, runs independent investigations in parallel when the budget allows, and gives the result to a separate reviewer. Commondev coordinates these steps using the model connection you selected.
- **Harness²** evaluates changes to the agent’s project instructions. It tests a candidate on a held-out task and saves it when the checks show an improvement. You can enable it for project chats.
- **Project chats and Git worktrees** let you keep conversations grouped by folder and pin the ones you return to. Start a chat in a separate worktree to keep the agent’s edits out of your current checkout.

For permissions, dictation settings, message queues, and session storage, see the [user guide](docs/overview.md).

## Build from source

Install Xcode Command Line Tools and Git. Run the following commands from the repository root, using fresh output paths. The gateway build downloads its dependencies and bundles a Node.js runtime for the build machine’s architecture.

```sh
bash macos/scripts/build-gateway.sh "$PWD/macos/.build/FreeLLMAPI"
bash macos/scripts/build-app.sh "$PWD/macos/.build/Commondev.app"
open "$PWD/macos/.build/Commondev.app"
```

The [macOS build guide](macos/README.md) covers reusing a gateway, debug builds, packaging, and third-party notices.

## Development

The SwiftUI app, agent core, gateway, and command-line tools live in [macos/Sources](macos/Sources). Run the following checks from the repository root.

```sh
swift test --package-path macos
python3 -m unittest discover -s macos/Tests/ScriptTests -v
bash macos/scripts/verify-demo.sh
```

The demo uses a deterministic provider and temporary copies of a deliberately failing Swift package. It verifies that declining an edit preserves the original file and that approving the fix makes the test pass.

Use English for public documentation, issues, pull requests, commit messages, and release notes. In a pull request, describe what changed and how you verified it. The project license is pending.
