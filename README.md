# MyChatBuddy

A native macOS chat app that decides, for every message you send, *which model should answer it* — a free on-device model, a fast cloud model, or an advanced cloud model — so you only pay for the heavy hitters when a question actually needs them.

Everything runs on your Mac except the cloud calls you choose to enable. Your chats live in a local database, and your API keys live in the macOS Keychain.

## Features

- **Automatic routing.** A small on-device model classifies each message and picks a tier:
  - **Local** — an MLX model running on your Mac (free, private, works offline).
  - **Cloud Fast** — a quick, cheap cloud model (default: Claude Sonnet or GPT-4o mini).
  - **Cloud Advanced** — a stronger cloud model for hard questions (default: Claude Opus or GPT-4o).
  - If the classifier is unavailable or you're offline, it falls back to the local model rather than risking an unwanted cloud call. A routing-sensitivity setting (prefer local / balanced / prefer cloud, under Settings → Routing) biases the choice.
- **Model badge on every reply** showing which model answered and how many tokens it used.
- **Usage limits.** Optional per-conversation token soft cap, daily and monthly dollar budgets, and per-tier daily call caps. When a cap is hit the app downgrades the tier and tells you; the Settings → Usage tab shows spend.
- **Web search** for current-events questions, using Anthropic's web search tool, with a sources list under the answer. Currently Anthropic-only; there is a global on/off toggle. If a search is needed but you're over budget, the app asks before spending one more cloud call.
- **File attachments.** Attach `.txt`, `.pdf`, `.docx` and source-code files; their text is included as context for the conversation. Combined size is capped (default 50,000 characters, adjustable in Settings → Limits). This is plain text extraction, not retrieval/embedding.
- **Image understanding (local vision).** Attach an image and a local vision model describes or answers questions about it, entirely on-device. Images bypass routing and cost nothing. Once a conversation contains an image, follow-up questions stay on the vision model and re-send the latest image. One image per message for now; large images are downscaled (longest edge 1568 px) and a source-size cap applies (default 10 MB).
- **Markdown rendering** of assistant replies.
- **Menu bar item** for quick access.
- **Swappable local models.** Pick the active text and vision models in Settings → Local Model; each downloads independently from Hugging Face into the shared cache (`~/.cache/huggingface/hub`).

### Local models (curated list)

| Slot | Options | Default |
|---|---|---|
| Text | Llama 3.2 3B Instruct, Qwen2.5 3B Instruct, Qwen2.5 7B Instruct (all 4-bit) | Llama 3.2 3B |
| Vision | Qwen2.5-VL 7B Instruct (4-bit) | Qwen2.5-VL 7B |

The vision model is about 5 GB, the text models 2–4 GB each.

## Requirements

- A Mac with **Apple silicon** (MLX runs on the Apple GPU)
- **macOS 14** or later
- **Xcode** (recent version with Swift 6 support)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Disk space for the local models you download
- Optional: an Anthropic and/or OpenAI API key for the cloud tiers. Without keys, the app still works with local models only.

## Getting started

```sh
git clone https://github.com/sayantan92sanyal/MyChatBuddy.git
cd MyChatBuddy
xcodegen generate
open AIChatRouter.xcodeproj
```

Then in Xcode choose the `AIChatRouter` scheme and run. (The project and folder names still say `AIChatRouter`; the built app is named MyChatBuddy.)

If the command-line build complains about package plugin validation, build with:

```sh
xcodebuild -project AIChatRouter.xcodeproj -scheme AIChatRouter -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation build
```

### First run

1. **Settings → Local Model** — download the text model (and the vision model if you want image support). Local features need these downloaded first.
2. **Settings → API Keys** — optionally add your Anthropic and/or OpenAI keys. They are saved in the macOS Keychain, never in files.
3. **Settings → Routing** — choose which provider handles Cloud Fast and Cloud Advanced, and how strongly routing should favor local or cloud.
4. **Settings → Limits** — optionally set budgets and caps.
5. Start chatting. Use the paperclip to attach files or images.

## How routing works

1. You send a message.
2. If it carries an image, or the conversation already has one, it goes straight to the local vision model (no routing, no cost).
3. Otherwise the on-device classifier labels the message as local / fast / advanced and whether it needs web search.
4. The coordinator applies your settings: web-search toggle, usage caps (which may downgrade the tier), and offline status (forces local).
5. The chosen provider streams the reply. Every decision (query, tier, reasoning, latency) is logged locally for tuning.

## Project layout

```
AIChatRouter/          SwiftUI app: views, view models, app environment
AIChatRouterKit/       Swift package with all the logic (no UI)
  Router/              classifier, routing coordinator
  Providers/           Anthropic, OpenAI, local MLX providers, provider registry
  LocalModel/          model catalog, download + load management
  Persistence/         SQLite stores (GRDB): conversations, messages, attachments, usage
  Usage/               limits, pricing table
  Attachments/         file text extraction, image downscaling
  Security/            Keychain wrapper
docs/superpowers/      design specs and implementation plans for major features
project.yml            XcodeGen project definition
```

Main dependencies: [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (on-device models), [GRDB](https://github.com/groue/GRDB.swift) (SQLite), [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui), and Hugging Face's `swift-huggingface` / `swift-transformers` (model download and tokenizers).

## Testing

```sh
cd AIChatRouterKit
swift test
```

The logic layer has an automated test suite. The SwiftUI app target has no automated tests; UI changes are checked by hand. Note that tests which run real MLX models can't run under `swift test` (Metal isn't available there) — those are checked by running the app.

## Where your data lives

| What | Where |
|---|---|
| Chats, attachments, usage, routing log | `~/Library/Application Support/AIChatRouter/db.sqlite` |
| API keys | macOS Keychain (service `com.sayantan.aichatrouter`) |
| Settings | the app's UserDefaults |
| Downloaded models | `~/.cache/huggingface/hub` |

## Known limitations

- One image per message (multiple images are planned).
- Web search works with Anthropic only.
- Selecting a local text model you haven't downloaded will download it automatically on the next local-tier message.
- The routing classifier always uses Llama 3.2 3B regardless of which text model you select for answers.
- File attachments are inserted as plain text context; there is no chunking or semantic retrieval yet.
- Internal folder, target and identifier names still use the earlier project name `AIChatRouter`.

## License

Released under the [MIT License](LICENSE). The local models the app downloads (Llama, Qwen) and the cloud APIs it can call (Anthropic, OpenAI) are separate and carry their own terms.
