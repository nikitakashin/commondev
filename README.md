# commondev

Commonwealth of Developers (commondev) is a macOS coding agent. Start a chat, optionally attach a project folder, and review the agent’s proposed edits and shell commands. The SwiftUI app can use its bundled FreeLLMAPI gateway or a custom OpenAI-compatible streaming endpoint.

## Run locally

Use macOS 13 or later with Xcode Command Line Tools and Git. Building the gateway requires network access. From the repository root, run the following commands with fresh output paths.

```sh
bash macos/scripts/build-gateway.sh "$PWD/macos/.build/FreeLLMAPI"
bash macos/scripts/build-app.sh "$PWD/macos/.build/Commondev.app"
open "$PWD/macos/.build/Commondev.app"
```

The app includes its own Node.js runtime and targets the build machine’s architecture. The build script uses ad-hoc signing. See the [macOS build guide](macos/README.md) for rebuilding with an existing gateway, distribution status and third-party notices.

## Inside the repository

- [Public documentation](docs/index.md) covers connections, sessions and the agent’s execution model.
- [macos/Sources](macos/Sources) contains the SwiftUI app, agent core, model gateway, evaluation tools and command-line programs.
- [macos/Tests](macos/Tests) contains Swift integration and unit tests and Python tests for packaging scripts.
- `docs_internal/` holds Git-ignored Russian working notes. Public project documentation is in English.

## Contributing

Describe the problem in an issue or pull request, include a focused change and explain how you verified it. Run the checks from the repository root.

```sh
swift test --package-path macos
python3 -m unittest discover -s macos/Tests/ScriptTests -v
bash macos/scripts/verify-demo.sh
```

The demo exercises an approved and a declined edit on temporary copies of a deliberately failing Swift package. It uses a deterministic provider. The project license is pending.
