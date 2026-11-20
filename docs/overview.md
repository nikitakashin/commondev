# Using commondev

## Start a chat

Click New Chat or press Cmd+N to start in the last project you opened. Pressing it again while that chat is empty keeps the same chat. Use the plus next to a project heading to start a chat in that project. Right-click a chat to rename, pin or delete it. The bar above a new chat's composer lets you select or remove its folder. In a chat without a folder, shell commands start in your home directory and file tools accept absolute paths. macOS permissions still apply.

For a Git project, the new chat's Git menu lets you create a local worktree from a branch or from HEAD. Commondev attaches the chat to the new checkout and groups it under the original project.

Use Cmd+Plus and Cmd+Minus to change the window's zoom by 10 percentage points, or Cmd+0 to restore 100%. One desktop process owns the session store for each macOS user. Opening the app again brings the existing app forward.

## Choose a connection

Click the model and work mode control to adjust effort. Click the model name in that panel to open the model list and settings. Automatic selection uses the local FreeLLMAPI gateway. The list also offers available gateway models that support tools and your configured custom model. The first gateway start needs network access to prepare the catalog. For a custom provider, enter its full chat completions URL, model name and optional API key. Chat history and tool results form part of the requests to the selected model.

The app stores custom API keys in the macOS Keychain for each combination of scheme, host and port. A connection on a different origin starts with its own saved key or an empty field. When upgrading from a build that used a single shared Keychain entry, enter the key once for the intended server.

## Send and queue messages

Press Enter to send and Shift+Enter for a new line. The first message gives the chat an immediate title. After its first successful reply, the selected model receives up to 2,000 characters of that message in a separate request for a short title. A manual rename takes precedence.

Messages sent while the agent is working join the session’s queue. The working indicator sits to the left of the active prompt. Click the actions row to see tool activity for that prompt, then click it again to collapse it. Each queued message records a fingerprint of its selected connection and model. If either changes, the queue pauses. Switch back and resume, explicitly choose the current connection for the first item, or return it to an empty draft. Queued messages from older versions also require a connection choice.

A request that exceeds the individual message budget stays editable. The check includes the encoded message and system instructions. Stop cancels the current run and leaves waiting items available for manual resumption.

The plus menu can attach up to four UTF-8 text files of up to 12 KB each. The selected model receives their contents when you send the message. The attachment stays with the message in the queue and local history.

The microphone button transcribes speech into the draft for editing before sending. macOS asks for microphone and speech recognition access on first use. The default language is Russian. You can switch to English in Settings.

## How a task runs

The [agent core](../macos/Sources/AgentCore) streams model responses, searches and reads project files, inspects Git changes and manages tool calls. The permission menu defaults to asking before edits and shell commands. With a folder selected, you can allow built-in file edits inside the project and keep command approvals. Full access allows edits and commands with the operating-system permissions of the app. Permission settings apply to one chat and reset when its folder changes or the app quits.

Plan mode in the plus menu uses read-only file and Git tools and returns a plan. Turn it off when you want the agent to implement the plan.

The agent checkpoints tool calls before execution and records their results afterward. An interrupted action can have an uncertain outcome. Inspect the affected files before repeating it. During a streamed reply, the app groups text updates for disk writes. Each chat has its own file in `~/Library/Application Support/Commondev/Sessions/`. The session index is `sessions.json`. On the first save after upgrading, the app writes legacy sessions to individual files before replacing the index.

The work mode menu defaults to High and controls the request budget. Ultracode adds planning, parallel research and an independent review. Its subagents use project copies for chats with a folder and read-only tools for chats without a folder. Harness² is optional for project chats. It captures project copies for qualifying tasks, evaluates proposed instructions against a held-out task, and saves a profile when the candidate improves the result without a measured regression.
