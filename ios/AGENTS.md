# Lori iOS — working rules

## Scope

Work only in this native iOS project unless the user explicitly asks otherwise:

```text
/Users/ilyaqa/Projects/Lori/ios
```

Do not modify the legacy web/bridge project in the parent `Lori` directory for an iOS task.

## Product intent

Lori is a personal iPhone app, not a desktop or calling app. Its core loop is:

1. The user creates a note, creates/selects a local folder, or imports a file.
2. The user can record audio from the iPhone microphone.
3. Lori stores its own files locally and an optional DeepSeek chat can inspect them.
4. The assistant may create/edit/move local files only when the visible settings toggle permits it.

The app must never claim access to arbitrary iPhone storage. Its writable sandbox is:

```text
Documents/Lori/Workspace
```

External documents enter it only through the iOS file picker. The user can also expose this app folder through the Files app because file sharing is enabled.

## Privacy and security

- DeepSeek keys live only in the iPhone Keychain. Never print, log, commit, copy, request, or inspect a key.
- Do not add a key to source, `Info.plist`, test fixtures, README, or shell commands.
- Keep all workspace paths sandboxed. Do not weaken traversal or symbolic-link checks in `WorkspaceStore`.
- File mutations remain an explicit in-app user choice. A model must not silently overwrite or delete a file.
- “Delete” means move to `.LoriTrash`, not irreversible deletion.
- Personal development signing is for the owner’s connected device. Do not create a fake distributable IPA or import/export certificates unless the user explicitly asks.

## Current UX requirements (do not regress)

- Home is the notes screen (**Мои заметки**) in the cream visual language from the supplied mobile references.
- There is no `Get desktop` chip and no call button.
- Settings remain in the top-right corner.
- The bottom `+` is a separate circular control, not part of the chat composer.
- Tapping `+` opens **Записать / Новая заметка / Выбрать файл**. It must not open or send a chat.
- **There is no microphone button anywhere.** Recording starts only from `+` → «Записать». The
  composer mic meant «record material» on home and «dictate a question» in the chat, and nothing on
  the button told you which — so dictation-as-a-question is gone with it. The chat's primary button
  only sends and is disabled without a draft. The recording pill still lives in both composers while
  a recording runs: it is the live state and the only way to pause, stop or cancel.
- Tapping the top-left folder opens the lightweight folder drawer: create/select/search folders. Selecting a folder opens its local contents.
- Chat is opened by sending a non-empty text prompt; it is not the default action of `+`.
- Before reading or changing a file, the DeepSeek system prompt requires `list_files` and exact returned relative paths. Do not reintroduce invented file paths.
- A note opens in an editable `TextEditor`, not a read-only view. Text is saved by **Готово** and also on swipe-to-dismiss, so typing is never lost.
- **Новая заметка** opens the editor for an unsaved draft. The file is created only when non-empty text is saved, and its name comes from the first line (date fallback). Never create an empty placeholder file.
- The user can rename and move to trash from the UI: context menu on the home card, swipe or context menu in the browser, `…` menu in the editor. Do not leave file mutations available only to the model.
- The agent loop runs up to `AssistantStore.maxToolRounds` tool rounds per message and reports the limit to the user. One round is not enough for the `list_files` → `list_files` → read sequence the system prompt demands.
- Chat history is persisted by `ConversationArchive` to Application Support, not `Documents` — `UIFileSharingEnabled` would otherwise expose the JSON in «Файлы» next to notes.
- Chat autoscroll targets `ChatTranscript.bottomAnchor`. Do not scroll to `bubbles.last?.id`: user bubbles need their own `.id` and the sending indicator sits below them.
- The composer background is opaque. A translucent one let cards show through and read as tappable while the tap went to the composer.
- The interface language is Russian, including headings. `My notes` / `Today` / `Ask anything` / `Hi Илья, ask anything` came from the Granola reference and were the app's most visible defect: English chrome around Russian content. Reverting to English is a per-string change, not an architectural one — ask the owner before doing either.
- Note rows show the name without its extension and the modification time. No file sizes (`ByteCountFormatter` printed «56 bytes» in the system locale) and no `lock.fill`: Lori has no sharing, so a padlock on every row means nothing. The «everything stays on this iPhone» fact is stated once, in the header.
- Home groups content: a `Папки` section (app-generated `Recordings` / `Transcripts` last) and then notes under real date headers. Never reintroduce a static `Today` header over an unfiltered list.
- No fake calendar card. `UpcomingCard` always said «No upcoming events» and there is no calendar integration. If one is wanted, it needs EventKit, not a placeholder.
- Under an assistant answer there is one action — copy. Thumbs up/down wrote to a local `@State` and «развернуть» printed a hardcoded sentence about sources.
- All text uses semantic fonts or `relativeTo:` (`LoriFont`), and rows size from padding, not fixed heights, so Dynamic Type works. The palette is cream-only and the app pins `.preferredColorScheme(.light)`: without it `Form`/`List` followed system colors and the status bar went white on cream.
- There is exactly one `AudioCaptureStore`, owned by `ContentView`. Home and chat had separate instances plus `onDisappear { cancel() }`, so recording died on every screen switch.
- The recording pill shows pause, live level, elapsed time and «Отмена». Cancelling moves the partial `.m4a` to `.LoriTrash` rather than deleting it.
- `Спросить про заметку` / `Спросить про папку` prefill the chat composer and let the human press send. Do not make them send on their own.
- Audio rows show a `waveform` icon and a «Запись · <дата>» subtitle. Tapping one opens `RecordingSheet` — the player. It must not start recognition on its own: before the player existed there was no way to hear your own recording at all, because the tap went straight to transcription. The sheet holds playback (play/pause, ±15 s, scrubber) and, below it, `TranscriptCard` — the segmented «Важное ↔ Расшифровка» switch with one bottom action («Расшифровать» → «Обработать» → «Открыть заметку», whichever is next). The row context menu keeps the transcription commands as shortcuts.
- One `.sheet` per screen, driven by the `EntrySheet` enum (`editor` / `recording`). Two `.sheet` modifiers on one view are as unreliable as two `.alert` modifiers; do not add a second one.
- «Готово» sits top-leading in every sheet — editor, browser, recording. Do not move one of them to the trailing side.
- A running transcription must never take the composer away. It shows as `TranscriptionStatusLine` above the field; typing and sending stay available. The old «microphone disabled while transcribing» rule went away with the microphone button: recognition reads a file (Core ML for GigaAM, `SFSpeechURLRecognitionRequest` for Apple) and does not hold the input session, so a new recording during transcription is safe.
- While recording, every sheet carries `RecordingBanner` at the top: the composer pill is hidden behind the sheet, and without the banner the user edits a note not knowing the microphone is live. Tapping the banner closes the sheet (saving the note first) and returns to the pill.
- Stopping a recording on the home screen opens the recording card and starts transcription there, so the progress is visible on the screen the result lands on. It does not open the raw transcript file and does not send the text to the model as a question. Recording is always material, never a question — there is no dictation path into the chat any more.
- Only one `.alert` per SwiftUI view is presented. Workspace and transcription errors share one alert in `ContentView`; adding a second one silently kills both.
- `.environmentObject` must sit **outside** every `.sheet` on the same view. The recorder was injected before the `.sheet(isPresented:)` modifiers, so the browser and the settings sheet opened without it and `RecordingBanner` crashed the app on `EnvironmentObject.error()`. `WorkspaceStore` never showed the problem because the app injects it above `ContentView`.
- A sheet that carries a value uses `.sheet(item:)`, never `.sheet(isPresented:)` plus a separate `@State` path. Tapping a folder opened the workspace root: the content closure captured the path from the body evaluated *before* the tap. `WorkspacePath` exists only to make the browser's sheet `item`-driven.
- Home has search — the magnifier next to the settings gear. It walks the whole workspace, not just the root, and matches names **and** note text; a result row shows the matching line and the folder it lives in. The composer is hidden while searching: over the keyboard it ate half the results. Notes inside folders were invisible from home before this.
- The folder browser uses `List` rows styled as the home cards (`FolderRow` / `NoteCard`), with `listRowSeparator(.hidden)` and a clear row background. `List` stays for the swipe actions — a plain `ScrollView` would drop them, and swipe is a required mutation entry point. A folder opens under a big Georgia header with a `2 папки · 4 файла` count line; the 17 pt inline navigation title was the thing that read as a web view.
- The app icon is a Georgia capital `L` on the cream canvas, in the exact `LoriPalette` colours. It is generated by `design/icon/RenderIcon.swift` (CoreText, glyph-path centring) as a full-bleed 1024×1024 PNG with no alpha and no pre-rounded corners. Keep `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `project.yml`; without it the asset catalog is built but never referenced.

The interaction references are the owner's screen recordings of **Granola for iPhone**, the app
Lori's interface is modelled on:

```text
/Users/ilyaqa/Downloads/ScreenRecording_08-24-2026 16-36-42_1.MP4
/Users/ilyaqa/Downloads/ScreenRecording_08-24-2026 18-03-21_1.MP4
```

Read them with `ffmpeg -i <file> -vf "fps=1/6,scale=300:-1,tile=5x3" sheet.jpg` and inspect the sheet.
Adopted from them: date-grouped note list with times, recording pill with pause/level/cancel,
`Chat with note` / `Chat with folder`, note detail as a serif title plus metadata line, history rows
with a right-aligned relative time.
Deliberately **not** adopted: the calendar card (Granola has a real calendar, Lori does not),
per-row padlocks (Granola shows sharing state, Lori has no sharing), thumbs up/down (Granola sends
feedback to its own backend), `Get desktop` and the call button (removed by the owner earlier).
Still missing versus the reference: folder description and access fields. The folder hero header exists now.
The persistent recording bar exists now — `RecordingBanner`, on every sheet.

## Audio and transcription truth

- `AudioCaptureStore` records `.m4a` files into `Workspace/Recordings` and does **nothing else**. It asks
  for the microphone only. Recording used to be gated behind `speech.prepare()`, so a device without
  recognition models could not even save audio — never reintroduce that coupling.
- Transcription is a separate step in `TranscriptionService`, works on any audio file already in the
  workspace (recorded or imported), and writes `Transcripts/<name>.md`. A failed transcription must
  leave the audio in place.
- `AppleSpeechTranscriber` uses iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` (built for long files) and
  falls back to `SFSpeechURLRecognitionRequest` below iOS 26. Two hard-won details:
  - the locale must be reserved with `AssetInventory.reserve(locale:)` **before**
    `assetInstallationRequest(supporting:)`, otherwise the system answers
    `Cannot check the download status, … is not subscribed to transcription.<lang>`;
  - do **not** call `SFSpeechRecognizer.requestAuthorization` on the `SpeechAnalyzer` path. It shows a
    system dialog that nothing answers in tests and the call then hangs forever. The old permission is
    only needed by the legacy path.
- `SpeechTranscriber.supportedLocale(equivalentTo:)` returns a locale even where no models exist, so
  availability is decided by `SpeechTranscriber.supportedLocales` being non-empty.
- **The iOS Simulator has no speech models at all** — `supportedLocales` is empty for every language,
  so transcription can only be verified on a physical iPhone. Measured on 24 August 2026 on
  iPhone 17 Pro Max / iOS 26.5. In the simulator the app must say so plainly, which is what
  `TranscriptionError.assetsUnavailable` is for.
- `GigaAMCoreMLTranscriber` is only a stub. Do not say GigaAM runs on the iPhone until a real Core ML
  model is bundled, loaded, and tested on device. The owner's GigaAM v3 lives at
  `/Users/ilyaqa/Projects/GigaAM` (428 MB checkpoint, production model `v3_e2e_rnnt`, no ONNX export —
  `triton_scripts/repos/*_onnx` hold only `config.pbtxt`). Resource check of 24 August 2026: 16 GB RAM
  with 0.7 GB free and 11 GB free disk — **not enough to start a Core ML conversion**. Re-measure before
  trying, and get the owner's word first. The prepared route is in `design/gigaam/`: take the CTC
  variant, keep the log-mel front end on the Swift side, and read the preprocessing numbers from the
  model config — `gigaam/preprocess.py` defaults (win 400, `center=True`) do **not** match v3
  (win 320, `center=false`).
- Long audio is chunked by `AudioChunker` before the legacy recognizer sees it, and **all** recognition
  results are collected through `SFSpeechRecognitionTaskDelegate`, not just the first `isFinal` one.
  Resuming on the first result cost a 346-second recording 90% of its text (132 characters instead of 1233).
- Тайминги слов считаются как в `gigaam/timestamps_utils.py`: слово открывает кусок с `▁`,
  начало — кадр первого токена, конец — кадр последнего плюс один, шаг кадра берётся
  по факту (длительность куска / число кадров энкодера), без поправки на задержку RNN-T.
- Куски аудио **перекрываются** (`AudioChunker.overlapSeconds`), иначе слово на стыке
  теряется целиком. Перекрытие ограничено половиной цели: иначе нарезка не продвигается
  и плодит куски по одному отсчёту. Дубли из перекрытия отбрасываются по времени
  в `TranscriptAssembler.merge`, а не сравнением строк.
- **Core ML переиспользует буферы своих выходов.** Состояние LSTM предсказательной сети
  нельзя передавать обратно тем же `MLMultiArray`, который вернула модель: оно затирается
  при следующем вызове. `GigaAMCoreMLNetwork.State` хранит собственные копии `[Float]`.
  Симптом был обманчивым: декодер надолго уходил в blank и терял начало записи.
- **Окно энкодера — 25 секунд**, это `LONGFORM_THRESHOLD` из библиотеки GigaAM. На окне
  45 секунд модель теряла начало: дольше 25 секунд за раз она не рассчитана обрабатывать.
- **Настоящую длину куска обязательно передавать в энкодер**: из неё строится маска паддинга,
  а внимание в Conformer глобальное. С константной длиной паддинг портил реальные кадры.
- Audio must stay local in the current path; do not add cloud ASR as a fallback without explicit user
  approval. Handing audio to the owner's own Mac over the LAN is also "leaving the device" and needs
  the same explicit approval.

## Files brought into the chat

- The paperclip **brings a file into the conversation**, it does not quietly copy it away. Before
  this, it imported into `Inbox` and left no message, no card and no transcript — the file simply
  vanished. Never restore that behaviour.
- **Motion in the chat follows what the owner picked** on the live mockups
  (`design/motion/index.html`, variants 1Б / 4В): a real progress ring with percentages while
  transcription runs, a shimmering status line where there is no honest number (a digest is one
  request), and text that reveals line by line instead of landing as a wall. All of it is native
  SwiftUI — `trim`, `TimelineView`, `transition`; the project has no animation dependency and does
  not need one. `TranscriptionService.progressFraction` exists so the ring never parses «3 из 10»
  back out of a localized string.
- Preview lines in the card are **real text**, not grey placeholder bars, and the cut is marked with
  an ellipsis. Drawing bars over text that already exists hides content for decoration.
- A brought file appears as `ChatBubble.Role.attachment` with the workspace `path`, rendered by
  `ChatAttachmentCard`: state («Расшифровываю… 3 из 10» → «Расшифровка готова» → «Важное готово ·
  тема»), a three-line preview and at most two actions. Reading in full happens in the recording card
  or the note, not inside the bubble — no nested scroll views.
- `ChatIngest.decide` is the only fork: audio → transcribe, readable text → straight to context,
  anything else → an honest line in the chat that Lori cannot read it. Do not pretend an image was
  understood.
- The text of an attachment goes to the model as a **system message** (`AssistantStore.addContext`),
  capped at `maxContextCharacters`, and the cap is stated inside the message. It is never a user
  bubble: the human already sees the card, and a wall of transcript in the feed is noise.
- Restoring a conversation from history does **not** put attachment text back into the model context
  (`case .system, .attachment: nil`). Bring the file again rather than inventing history.
- An audio attachment follows the same road as a recording: transcript in `Transcripts/`, digest in a
  theme folder, front matter pointing back at the file wherever it lies (`Inbox/…` included).
- The chat has exactly one sheet, driven by `ChatSheet` (`history` / `entry`). Audio opens
  `RecordingSheet`, everything else the note editor.

## Digest, memory, wiki — the second-brain layer

- A recording produces **two** texts, and both stay: the verbatim transcript in `Transcripts/`
  and the processed note in a **theme folder** at the workspace root. The card switches between
  them; the note links back through front matter.
- The processed note is written by `DigestService` through the same model as the chat, so it needs
  a key. `autoProcessTranscripts` (on by default) runs it right after transcription; `TranscriptCard`
  also offers «Обработать» by hand. Without a key the card still shows the transcript, split into
  paragraphs locally by `TranscriptReadability` — never an empty screen when text exists.
- **Front matter is the source of truth for the audio ↔ transcript ↔ note link** (`lori: digest`,
  `audio:`, `transcript:`, `theme:`, `tags:`). Do not replace it with an external index: front matter
  survives renaming, moving and hand-editing, and an index does not. `DigestService` only caches the
  scan and re-scans when a cached path is gone.
- The theme folder is chosen by the model **out of the existing top-level folders**, matched
  case-insensitively, or a new one-to-two-word name. `Recordings` / `Transcripts` / `Inbox` / `Models`
  can never be themes.
- `TranscriptReadability` must not change words. It only drops the title line and `**[00:00–00:04]**`
  marks and groups sentences into paragraphs, and it breaks only at sentence ends — text without
  punctuation (the Apple engine) stays one paragraph rather than being cut mid-phrase.
- Memory is a **visible note**, `Память Lori.md`, not a hidden store: the owner must be able to read,
  fix and delete what was remembered. `MemoryStore.promptBlock` is injected into the system message
  before every send. The `loriMemory` toggle governs the whole feature — off means neither `remember`
  / `forget` tools nor the facts in the prompt.
- `search_notes` searches the whole workspace at once and is the agent's first step for any question
  about content; `list_topics` / `topic_notes` navigate themes and tags. It is honest keyword search
  by five-letter stems, not embeddings — do not describe it as vector RAG.
- The wiki (`WikiIndex`, `WikiSheet`) is derived, never stored: themes are folders, tags come from
  front matter and `#решётки`, links from `[[двойных скобок]]`, and backlinks are computed from the
  forward ones. `Recordings` / `Transcripts` / `Models` are excluded — that is raw material, not
  knowledge. A `[[link]]` with no note is a future topic, shown as such, not an error.
- `LLMSettings` decides where requests go. Empty settings mean DeepSeek; a valid `http`/`https`
  address with a host switches the whole app — chat, digest and the connection check — to that
  provider, with its own model name. Garbage in the field must fall back to DeepSeek instead of
  silently breaking the chat. `NSAllowsLocalNetworking` plus `NSLocalNetworkUsageDescription` exist
  only so a model on the owner's own Mac can be reached over the LAN.
- Audio still never leaves the iPhone. What can leave is text: the transcript on processing and the
  question in the chat. Say this plainly in the UI; do not weaken it.
- **Model answers are Markdown and must be rendered as such.** `MarkdownText` splits blocks
  (headings, lists, quotes, fenced code) and hands inline markup to `AttributedString`. Real DeepSeek
  answers arrived as raw «**Где это записано:**» with backticks around paths until this existed.
  Copy still copies the raw text — that is the source.
- **The chat header is pinned** (`safeAreaInset(edge: .top)`), not part of the scrolling content: a
  long answer slid under the status bar and took the close button with it.
- **The interface must name the model the request actually goes to.** With a custom provider the
  composer shows that provider's model name instead of the DeepSeek picker, the connection check
  reports the host it reached, and the settings say the DeepSeek model choice is inert. The chip used
  to read «V4 Flash» while requests went somewhere else entirely.
- A service folder can never become a theme, even if the model answers «Transcripts»: such an answer
  falls back to «Заметки». Otherwise the note lands in raw material that the wiki hides.

## Source map

- `LoriLocal/Views/ContentView.swift` — home, chat, folder drawer/browser, import UI, settings.
- `LoriLocal/Services/WorkspaceStore.swift` — sandboxed local file access and tools.
- `LoriLocal/Services/DeepSeekAgent.swift` — DeepSeek Chat Completions client and file tools.
- `LoriLocal/Services/KeychainStore.swift` — DeepSeek key persistence.
- `LoriLocal/Services/AudioCaptureStore.swift` — microphone recording, metering, pause/cancel. No transcription.
- `LoriLocal/Services/Transcription.swift` — `LocalTranscribing`, `AppleSpeechTranscriber`, `TranscriptionService`.
- `LoriLocal/Services/NoteDigest.swift` — the digest model, its markdown and front matter, `NoteMeta`, `TranscriptReadability`.
- `LoriLocal/Services/DigestService.swift` — transcript → note through the model, theme folders, the front-matter scan.
- `LoriLocal/Views/DigestCard.swift` — `TranscriptCard`: the «Важное ↔ Расшифровка» switch and its single action.
- `LoriLocal/Views/MarkdownText.swift` — `MarkdownBlock` / `MarkdownText`: the model's Markdown, rendered.
- `LoriLocal/Views/ChatAttachment.swift` — `ChatIngest` (bring a file in: import, transcribe, context, digest) and `ChatAttachmentCard` (the card in the feed).
- `LoriLocal/Views/MotionBits.swift` — `ProgressRing`, `ShimmerLabel`, `RevealedLines`, `MotionText`: the chosen motion, native only.
- `design/motion/index.html` — the animated mockups the owner chose from (published as an artifact); keep it in step with what the app actually does.
- `LoriLocal/Services/Brain.swift` — `NoteSearchIndex`, `MemoryStore`, `BrainTools` (search, topics, memory).
- `LoriLocal/Services/Wiki.swift` — `WikiIndex`: themes, tags, links, backlinks; derived from files.
- `LoriLocal/Views/WikiSheet.swift` — the wiki screen: themes, tags, note page with connections.
- `LoriLocal/Services/LLMSettings.swift` — provider address and model name, with validation.
- `LoriLocal/Services/LocalTranscriber.swift` — the GigaAM connection point, still an explicit stub.
- `LoriLocal/Services/ConversationArchive.swift` — chat history persistence in Application Support.
- `LoriLocal/Views/LoriFormat.swift` — dates, Russian plurals, durations, with the locale pinned to `ru_RU`.
- `LoriLocal/Views/RecordingPlayer.swift` — `AudioPlaybackStore` (playback only, no delegate: the ticker catches the end) and `RecordingSheet`. `LoriPalette` / `LoriFont` are internal, not private, so this file can use them.
- `LoriLocal/Views/RecordingBanner.swift` — the «идёт запись» bar and the `.recordingBanner { }` modifier; the recorder comes from the environment (`ContentView` injects it as its outermost modifier), not through every initializer.
- `LoriLocal/Views/NotesSearch.swift` — `NotesSearchStore` (one breadth-first pass over the workspace, content read once per search session), `SearchResultRow`, `NotesSearchBar`.
- `LoriLocal/Assets.xcassets/AppIcon.appiconset` — the app icon, one 1024×1024 universal image.
- `design/gigaam/export_coreml.py` — GigaAM → Core ML export, with a resource preflight that refuses to run on a loaded Mac; `design/gigaam/README.md` — the measured model and preprocessing spec, and the remaining steps.
- `design/icon/RenderIcon.swift` — renders the icon variants; `design/icon/*.png` holds them plus the Higgsfield concept sketches.
- `LoriLocalTests/WorkspaceStoreTests.swift` — sandbox/file tests.
- `LoriLocalTests/AssistantStoreTests.swift` — agent tool loop, round limit, history persistence, via a scripted `ChatCompleting`.
- `LoriLocalTests/ConversationArchiveTests.swift` — history round-trip, broken file, cap.
- `LoriLocalTests/LoriFormatTests.swift` — date and plural formatting.
- `LoriLocalTests/TranscriptionServiceTests.swift` — transcript naming, engine failure, non-audio refusal, audio detection, all with a stub engine.
- `LoriLocalUITests/LoriLocalUITests.swift` — real simulator taps: folder, `+`, and the full note lifecycle.
- `LoriLocalUITests/NotesSearchUITests.swift` — finds a note by a word that exists only inside its text, opens the hit, cleans up after itself.
- `LoriLocalUITests/WorkspaceBrowserUITests.swift` — the folder opens as itself and not as the root, and the settings sheet opens. Both sheets are attached to `ContentView`, and both crashed on the missing environment object; keep these two tests as the guard for that.
- `LoriLocalUITests/RecordingPlayerUITests.swift` — the player screen and the recording banner. Both need a seeded audio file: `design/qa/seed-audio.sh` puts «UI sample.m4a» into the app container. Without it the test skips instead of failing. The banner test also skips in the simulator, which does not start a recording.
- `design/qa/seed-audio.sh` — makes the fixture with `say -v Milena` + `afconvert` and copies it into `Documents/Lori/Workspace`.
- `design/qa/seed-digest.sh` — the full card fixture: recording, its transcript and a processed note in `Работа/`, plus an unprocessed pair and two controlled-failure pairs. Needed by `DigestCardUITests`, `WikiUITests` and `LiveModelUITests`; without it they skip.
- `design/qa/mock-llm.py` — the stand-in provider with an OpenAI-shaped API: digest answers, tool calls, memory, and the controlled failures.
- `LoriLocalTests/NoteDigestTests.swift`, `DigestServiceTests.swift`, `BrainTests.swift`, `WikiTests.swift`, `LLMSettingsTests.swift` — the second-brain layer, all with stub clients and no network.
- `LoriLocalUITests/DigestCardUITests.swift`, `WikiUITests.swift` — real simulator taps on the card switch and the wiki.
- `LoriLocalUITests/RecordingEntryUITests.swift` — guards the single recording entry: no mic button on home or in the chat, «Записать» inside `+`, chat button sends only.
- `LoriLocalUITests/ChatAttachmentUITests.swift` — the attachment card in the chat. The document picker cannot be driven from a test, so the attachment is seeded straight into chat history by `design/qa/seed-digest.sh`; what stays unproven is only the picker → `ChatIngest.bring` glue.
- `LoriLocalTests/ChatIngestTests.swift` — the ingest fork, transcription of a brought recording, context injection and its cap, the digest of an attachment.
- `LoriLocalUITests/LiveModelUITests.swift` — the same flows against real HTTP: digest into a theme folder, chat search, memory, bad answer, provider error, tool-round limit.
- `project.yml` — XcodeGen source of truth. Regenerate the project after changing it.

## Verification

The native simulator integration used by Claude Code needs a selected Xcode. If it reports
`Xcode is installed but not selected`, the owner must run
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` — an agent cannot.
Without it, use `xcodebuild` plus `xcrun simctl io <udid> screenshot`; interface taps are
only available through UI tests. UI tests that tap a list card must scroll it clear of the
composer first: `isHittable` is true even for a card covered by the composer, and the tap
is swallowed there.

Run from this directory:

```bash
xcodebuild -quiet -project LoriLocal.xcodeproj -scheme LoriLocal \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO test
```

If `project.yml` changes:

```bash
/opt/homebrew/bin/xcodegen generate
```

For a physical phone, discover it first with `xcrun devicectl list devices`. Use Xcode automatic signing with the owner’s already-configured Personal Team. Do not write a team identifier into source control or documentation. A connected phone must be unlocked before remote launch works.

A SpringBoard icon cache can show a grey placeholder right after `simctl install`. Restart it with
`xcrun simctl spawn <udid> launchctl kickstart -k system/com.apple.SpringBoard`. To see the icon
without the simulator panel, drive SpringBoard from a UI test
(`XCUIApplication(bundleIdentifier: "com.apple.springboard")`) — or just inspect
`AppIcon60x60@2x.png` inside the built `.app`, which is what the build actually produced.

Two agent sessions must not run `xcodebuild ... test` on the same simulator at the same time.
Each run terminates and relaunches `ru.ilyaqa.lori.local`, so the other run's app dies mid-test and
XCTest reports `Test crashed with signal kill` — which reads exactly like a real regression and costs
an hour of bisecting. Check first: `ps aux | grep xcodebuild`. Use a separate `-derivedDataPath`
so the two runs do not fight over build products either.

Clean up after a UI-test run: notes left in `Documents/Lori/Workspace` accumulate, push cards under
the composer and break later taps. A crashed run leaves them behind — remove them by hand.

### Model paths: test them against a local server, not only stubs

Unit tests inject `ChatCompleting`, so they never touch the network, the answer parsing or the
provider settings. Everything that involves a model is therefore also driven end-to-end through a
stand-in server with an OpenAI-shaped API, with no key and no billing:

```bash
python3 design/qa/mock-llm.py 8765 &
./design/qa/seed-digest.sh <udid>
xcodebuild -project LoriLocal.xcodeproj -scheme LoriLocal \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:LoriLocalUITests/LiveModelUITests test
```

- **Do not pass `CODE_SIGNING_ALLOWED=NO` for anything that touches the Keychain.** An unsigned
  build has no entitlements at all, and `SecItemAdd` fails with «A required entitlement isn't
  present» — so the key cannot be saved and every model path is untestable. Default signing
  («Sign to Run Locally») is enough on the simulator.
- The stand-in server drives the failure modes on purpose: a transcript containing `СБОЙ` makes it
  answer prose instead of JSON, `ПЯТЬСОТ` makes it return HTTP 500, and a chat message containing
  `ЦИКЛ` makes it call a tool forever so the `maxToolRounds` limit is actually exercised.
- **The mode is chosen by whether the stand-in server is listening**, not by an environment variable:
  `TEST_RUNNER_…` never reaches the runner, and a run that looked real was silently going to the
  stand-in. `LiveModelUITests` prints which provider it used — read that line before trusting a green
  run. Stop the server and the same tests run against whatever provider the owner configured; the
  failure-mode tests skip, because only the stand-in can fail on command.
- **A stand-in run refuses to start while a key is saved in the app**: the app reads the key from the
  Keychain for every request, so the owner's key would be sent to the local server. Delete the key in
  settings first, or run against the real provider.
- Never ask the owner for a key and never type one into a command. The owner enters it in the app;
  in real-provider mode the test only presses «Проверить подключение» and reads the answer.
- `design/qa/seed-digest.sh` is idempotent: it deletes notes whose front matter points at its own
  fixture audio, so the «process it» test can run again. Re-seed before each run.
- The provider address and model name reach the app as launch arguments (`-llmBaseURL`,
  `-llmCustomModel`), which land in the argument domain of `UserDefaults`. Nothing is left behind in
  the app's own settings. The fake key is removed in a teardown block.
- Four UI-test traps, all of which read as app bugs: a sheet leaves same-named buttons of the screen
  underneath in the tree (`firstMatch` picks the invisible one — filter by `isHittable`); the
  folder browser shows «Готово» only at the workspace root, so leaving a nested folder takes
  «Назад» first; a `LazyVStack` keeps off-screen rows out of the element tree entirely, so scroll back
  to the top before looking for a row near it; and a note's file name is not its title — characters
  forbidden in a path («Тема: смысл» → «Тема смысл») are stripped, so a list row and a heading differ.
- What a simulator still cannot prove: transcription itself, and therefore the automatic digest right
  after it. The rule behind that branch is `DigestService.shouldProcess`, unit-tested separately —
  keep it that way instead of burying the condition in the view again.
- Assertions must not depend on the model's wording. Read the title from `digestTitle` and the theme
  from the «Тема · …» line and use those; an arrived answer is proven by the «Скопировать» action
  appearing under it, not by matching text — «заметк» also matches the app's own «ищу по заметкам».
- Facts to remember must be unique per run. A fact already in `Память Lori.md` is in the system
  message, so the model answers from it and correctly does **not** call `remember` — which reads like
  a broken tool loop but is not.

Manual acceptance on iPhone is required after functional changes:

1. `+` shows the add menu, not chat.
2. Folder opens the drawer; create a folder and open it.
3. Import a harmless text file and verify it is visible in the chosen local folder.
4. In settings, save the DeepSeek key and use **Проверить подключение**. Inspect only the success/error message, never the key.
5. Ask: `Перечисли файлы в рабочей папке` and verify the answer uses actual files.
6. Record a short sample and verify the `.m4a` and transcript appear locally.

## Working style

- Inspect before editing and preserve unrelated user changes.
- Use `apply_patch` for source/doc edits.
- Keep the Mac lightweight: do not download or compile large ASR/LLM models for this app during routine work.
- Report only proven runtime/device results. A successful build does not prove the installed app works.
