# NoteFlash

A Quizlet-style flashcard app for iPhone and iPad. Paste notes, import a PDF or PowerPoint file, or link a Google Doc, Google Slides presentation, or file in Google Drive, and NoteFlash turns them into a deck of flashcards. Linked Drive files stay in sync: when the file changes, only the affected cards are updated, and new cards are added for new material.

## Features

- **Three ways to add notes:**
  - **Text:** type or paste notes.
  - **File:** tap **Choose Notes** to take photos with the document scanner (it straightens and crops each page), choose photos from your library, or pick a PDF, PowerPoint (.pptx) file, or images from Files. Several photos become one deck, a page per photo. Slides contribute their titles, text, tables, and speaker notes.
  - **Google Drive:** use a Google Doc, Google Slides presentation, PDF, or PowerPoint file from Drive, or paste a link. Browse your Drive like the Drive app: My Drive folders, Shared, Starred, Recent, and search by name or text. Preview the text before using a file.
    - **Sorting:** Name, Last modified, Last modified by me, Last opened by me, Storage used, and (in Shared) Date shared, in either direction.
    - **View:** list or grid, with folders on top or mixed with files (list view).
- **Share from other apps:** in GoodNotes, Notability, Notes, Files, Photos, and most other apps, tap **Share** and choose **NoteFlash**. It works for text, PDFs, images, PowerPoint files, and Google Docs, Slides, or Drive links.
  - **Confirm:** the share sheet shows what was shared, with a title and card detail setting. Tap **Make Cards**.
  - **Make the cards:** NoteFlash makes the cards as soon as it opens. A notification lets you open it right away.
  - **GoodNotes:** use **Share → Export** and choose **PDF** or **Image**; `.goodnotes` notebooks can't be read directly.
  - **Handwriting:** in PDFs from note-taking apps, handwriting is read along with typed text. Several images become one deck with a page per image.
  - **Open in NoteFlash:** apps that offer "Open in…" can also send PDFs, images, PowerPoint, and text files straight to the New Deck screen.
- **AI-written cards:** Apple Intelligence runs on the device by default (free, private, works offline). Claude is available as an option in Settings.
  - **When Apple Intelligence needs a break:** iOS limits how much on-device AI an app may use in a stretch. NoteFlash waits out short limits, and with a Claude API key saved it can finish the deck with Claude instead of pausing (Settings → **Finish with Claude when limited**).
- **Comments and exam priorities (Google Docs and Slides):** comments and replies are read along with the notes, since they often hold extra notes.
  - **Exam priorities:** comments that say a point will be on the exam, test, quiz, midterm, or final (or say "important", "know this", or "high-yield") mark that point as an exam priority, and so do lines in the notes that say so.
  - **Coverage:** every exam priority gets cards, even in a compact deck.
  - **Marking:** those cards are marked **On the exam** and listed first. A deck with any of them gets an **All / On the exam / Starred** picker under the study modes, so you can study just those.
  - **Sync:** adding or editing a comment updates the deck like any other change.
- **Sharing a deck:** **Share Deck** (in a deck's ⋯ menu, or by holding a deck in the list) sends the deck as a single web page file. To add one you've been sent, share it to NoteFlash (or "Open With" NoteFlash) and confirm.
  - **Shared with a collaborator:** if the cards came from a Google Drive file and you can open that file too, your copy links to the same file and updates when it changes — so one person can make the cards for a shared doc and everyone keeps them current. Anyone without access just gets the cards. Anyone can open it — on a phone, a computer, or in email — and study it there or print it; nothing is uploaded and no account is needed. Someone who has NoteFlash can open the same file in the app, which adds the cards exactly as written, exam priorities and notes included, with their own study progress.
- **Google Drive sync:** linked files are checked every 2 minutes while the app is open, and again through iOS background app refresh. Edits update, remove, or add only the cards they affect. Files shared by link that aren't Docs have to be downloaded in full to check them, so they're checked every 15 minutes unless you tap **Check Now**.
  - Cards you write or edit by hand are locked and never overwritten.
  - Changed cards get a "New" or "Updated" badge.
- **Study modes:**
  - **Flashcards:** flip cards and swipe them into Know or Still learning.
  - **Learn:** rounds that start with multiple choice and move to typed or self-graded recall.
  - **Match:** a timed matching game with penalties for wrong matches and a best time.
- **Background processing:** new decks, regenerated decks, note edits, and Google Drive updates all run as background jobs. The deck list shows each job's progress and time left.
  - **Leaving the app:** jobs keep running, with progress in the Dynamic Island and on the Lock Screen.
  - **Nothing is lost:** unfinished work is written down, so closing NoteFlash — or iOS stopping it — doesn't throw it away. Sections that were already written are kept, and the job picks up from there.
  - **If iOS stops background work:** NoteFlash asks iOS for more background time and carries on when it's granted, without you opening the app. Opening the app always starts it again right away.
  - **Notes shared from another app:** NoteFlash asks iOS to start it in the background and make the cards, so the notification is a shortcut, not a requirement. (iOS runs this when the device is idle, and not at all if NoteFlash was force-quit from the app switcher.)
  - **When a job pauses:** a notification says how far it got ("49% done and saved"), that the work is kept, and that you can open NoteFlash to finish it now. The system Live Activity's last line says the same. Opening the app picks it up, and the notification clears itself.
  - **While you watch it:** the screen stays awake as long as NoteFlash is open and cards are being written, so a long job isn't cut short by the screen locking. It sleeps normally again when the job finishes, when you leave the app, and while a job is only waiting out a usage limit.
  - **When a job finishes in the background:** a notification lets you open the deck.
  - **Time estimates:** they learn how fast your device (or Claude) actually is.
  - **Troubleshooting:** a failed job shows the error details, and Settings → Processing Log keeps a history you can copy. The log screen's **Check Apple Intelligence** button sends a few test requests to the on-device model and records the results.
- **Deck list sorting:** Name, Last modified, Last modified by me, Last opened by me, or Date created, in either direction. Tap the list header to flip the order.
- **Deck tools:** stars and a study filter (all cards, exam priorities, or starred), search, editing notes (text decks), regenerating a deck, and resetting progress.

## Requirements

- Xcode 27, iOS 26.0 or later.
- Apple Intelligence engine: an iPhone that supports Apple Intelligence, with it turned on. The on-device model usually can't run in the iOS Simulator.
- The project is signed with the **Ayush Kansal (Personal Team)** (`Z8Q7299GJV`). Bundle ID: `com.ayushkansal.NoteFlash`.
  - Apps signed with a free personal team expire after 7 days. Re-run from Xcode to reinstall.

## Setup

1. Open `NoteFlash.xcodeproj`, choose your iPhone, and press Run.
2. (Optional) To use **Claude**, open Settings, switch "Write cards with" to Claude, and paste an API key from [console.anthropic.com](https://console.anthropic.com/settings/keys). The key is stored only in the device Keychain. The model is set in `AppConfig.claudeModel`.
3. **Google Drive files, no setup needed:** share the file by link, then paste the link into NoteFlash's **Google Drive** tab. In Docs, Slides, or Drive, tap **Share**, set **General access** to **Anyone with the link** (Viewer), and tap **Copy link**. NoteFlash reads the file and its name from the link and keeps checking it for changes. Anyone with the link can read the file, so use the setup below for private notes.

### Google Drive setup (private files, optional)

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and enable the **Google Docs API** and the **Google Drive API**.
2. Under **Google Auth Platform → Branding / Audience**, choose *External*, fill in the app name, and add your Google account as a **test user**.
   Under **Data Access**, add `…/auth/documents.readonly`, `…/auth/drive.metadata.readonly`, and `…/auth/drive.readonly`. Google treats `drive.readonly` as a restricted scope: it works for test users now, but publishing the app requires Google's verification.
3. Under **Credentials**, create an **OAuth client ID** of type **iOS**, with bundle ID `com.ayushkansal.NoteFlash`.
4. Paste the client ID (`…apps.googleusercontent.com`) into `AppConfig.googleClientID`.
5. In the app, open the Google Drive tab and choose **Choose from Google Drive** (or go to Settings and choose **Sign in with Google**).
   - NoteFlash asks for read-only access to your Docs, your Drive file list, and the contents of Drive files. It uses the file list to show your files, and file contents to read the Slides, PDFs, and PowerPoint files you pick. It never changes your files.
   - If you signed in before a permission was added, tap **Allow Access** when the picker asks (or in Settings → Google Account).

While the consent screen is in *Testing* mode, Google expires refresh tokens after 7 days, so you'll need to sign in again weekly. Publishing the app removes that limit.

## How it works

| Piece | Where |
| --- | --- |
| Data model (SwiftData) | `NoteFlash/Models` |
| AI engines (shared protocol, Apple, Claude) | `NoteFlash/Services/Engines` |
| Line diffing and section splitting | `TextDiff.swift`, `NoteChunker.swift` |
| Google sign-in (OAuth + PKCE, no SDK), Docs reading, Drive browsing | `GoogleAuth.swift`, `GoogleDocsClient.swift`, `GoogleDriveClient.swift`, `DriveDataSource.swift` |
| Reading Drive files (Docs, Slides, PDFs, PowerPoint) | `DriveFileReader.swift` |
| PDF, PowerPoint, and image text | `PDFTextExtractor.swift`, `RecognizedText.swift`, `ImageNotes.swift`, `PowerPointTextExtractor.swift`, `ZipArchive.swift` |
| Share extension and its inbox | `NoteFlashShare/`, `Shared/SharedInbox.swift`, `SharedNotesImporter.swift` |
| Drive picker (folders, sort, grid, preview) | `NoteFlash/Views/DocPicker` |
| Sync, note edits, regeneration | `DocSyncService.swift` |
| Screens and study modes | `NoteFlash/Views` |

**Card writing with Apple Intelligence.**
- **Sections:** long notes are split into sections that fit the model's 4,096-token context.
- **Card format:** each card is generated fact → question → answer, which gives the small model better questions.
- **Refused sections:** Apple's default safety filter often refuses ordinary history or health notes when it has to return structured output. Those sections are retried as plain-text Q/A under the permissive safety setting.
- **Repetition:** the small model sometimes starts rewriting cards it already wrote. `RepetitionWatch` notices four repeats and stops the response, instead of letting it run to its card limit and never reach the section's last lines.
- **Missed lines:** after a section, `CardMatcher.uncoveredLines` finds the lines no card is about; if there are enough of them, a quick plain-text pass covers just those lines (compact decks skip minor facts on purpose). This is also how a thin section gets a second pass.
- **Mismatched questions:** a "What was the Sugar Act?" card answered only with "1764" is reworded to ask "When was…".
- **Other failures:** if structured output fails or times out, the section is split or retried as plain text. iOS 26 (`LanguageModelSession.GenerationError`) and iOS 27 (`LanguageModelError`, `LanguageModelSession.Error`, `SystemLanguageModel.Error`, `GeneratedContent.ParsingError`) errors are grouped by `AppleModelFailure`. A model that can't be loaded, such as while it's downloading after an iOS update, gets its own message.

**Reading files.**
- **PowerPoint:** `PowerPointTextExtractor` unzips the .pptx (`ZipArchive`, using the Compression framework) and reads slides in presentation order. Titles become headings, body text becomes bullets, tables become rows, and speaker notes are kept. Dates, footers, and slide numbers are skipped.
- **Google Drive:** `DriveFileReader` reads each file type through the Google APIs when signed in:
  - **Docs:** the Docs API.
  - **Slides:** exported as .pptx, or as plain text for decks over Drive's 10 MB export limit.
  - **PDFs and PowerPoint files:** downloaded.
  - **Shared by link:** without sign-in, or when the signed-in account can't open a file, public export and download links are used. Their type is detected from the downloaded bytes.

**Comments and exam priorities.**
- **Reading comments:** `DriveFileReader` reads comments and replies with the Drive API (`comments.list`, which needs the `drive.readonly` permission). For Docs shared by link, it reads them from the doc's Word export instead (`DocxComments`), since the plain-text export has none. Link-shared Slides and PDF or PowerPoint files don't get comments.
- **Placing comments:** `CommentWeaver` puts each comment on the line after the text it's attached to, as `» Comment on “…”: …`. Comments that mention an exam become `» EXAM PRIORITY — comment on “…”: …`. Comments with no matching text go in a Comments section at the end — but only when they name something to study, since "On Exam" away from its line says nothing.
- **HTML escapes:** Google returns comments and the text they're attached to with escapes still in them ("(0&#8451;)"), which would never match the notes. `HTMLText` decodes them first, so those comments anchor to their line instead of piling up at the end.
- **Asides stay off the cards:** notes about the exam that a comment added ("… , on the exam", "key definition") are stripped from answers, and the spacing they leave behind is tidied. A question that is *about* the exam rather than the subject is dropped instead of patched.
- **Change detection:** comment changes don't change a file's Drive version, so a fingerprint of the comments is part of the version NoteFlash compares.
- **Priorities:** `PriorityNotes` finds exam priorities in the notes (flagged comments, plus lines with phrases like "will be on the exam").
  - **Card writing:** both engines are told what comments and exam priorities are. Apple Intelligence also runs a short focused pass for each exam priority that's attached to text, adding up to three distinct cards.
  - **Marking:** after generating, regenerating, or updating, cards whose words match a priority (two key words, or the only one) are marked `isPriority`. New cards for priorities go first.

**Sharing a deck.**
- **Sent as a file:** the share sheet offers the page as plain file data. Offered as HTML, iOS would let apps that take text (AirDrop to a Mac, Messages, Mail) convert it to the page's words, which loses the deck embedded in it; the name still ends in `.html`, so it opens as a web page.
- **One file for both:** `DeckShare` writes a self-contained web page (`DeckSharePage` holds its CSS and script). It shows the cards, a tap-to-flip study card, and the notes, and it prints as a card list. Nothing is loaded from the network, so it works offline, in Quick Look, and in email.
- **Exactly the same deck:** the deck is also embedded in the page as JSON (`<script type="application/json" id="noteflash-deck">`), so NoteFlash rebuilds it card for card, in order, with exam priorities, the notes, and the card-detail setting. Card text is HTML-escaped, and `<` is escaped in the JSON so nothing in a card can end the element early.
- **Linking to the same file:** a deck made from Google Drive carries the file's id, kind, link, and version in the payload. On import, NoteFlash looks the file up with the recipient's own account: if they can open it, the new deck is linked and auto-syncing (starting from the shared version, with the shared notes fingerprinted so the next check diffs from there); if they can't, or aren't signed in, the cards are added as a plain copy. The sheet says which it will be, and warns when a deck for that file already exists.
- **Adding a shared deck:** the recipient taps the file (in Messages, Mail, Files, or after AirDrop) and picks **Share → NoteFlash**, or **Open With → NoteFlash**. The share extension recognizes the deck, shows "Flashcards · 10 cards · 2 on the exam" and an **Add Deck** button; the app then shows **Add Shared Deck** (`ImportSharedDeckView`) with the title and a preview. `SharedDeckImporter` adds it with no AI pass: same cards, fresh study progress, source kind `shared`.
- **Both sides read it:** `DeckShare` lives in `Shared/`, so the extension can read the deck out of the page and show what's in it instead of offering to make cards from it.
- **Any other web page** opened in NoteFlash has its text read out of the markup and becomes notes to make cards from.

**Sharing from other apps.**
- **Handoff:** a share extension can't open its app or run long jobs, so `NoteFlashShare` copies what was shared into an App Group folder (`group.com.ayushkansal.NoteFlash`). The item's manifest is written last, so the app never reads a half-written item.
- **Notification:** the extension posts a notification that opens NoteFlash.
- **Import:** `SharedNotesImporter` turns each item into a normal background job. This runs at launch, when the app becomes active, and during background runs, so shared notes don't wait for the app to be opened.
- **Starting the app:** the extension also submits the app's catch-up background task. Extensions can't launch their app themselves, but iOS launches the containing app to run a task it submitted.
- **Images:** turned into a PDF, one page per image, so they can be viewed, read with text recognition, and sent to Claude like any PDF.
- **Page images (iOS 27):** when the on-device model can read images, handwritten and scanned pages go to Apple Intelligence as images, with the Vision text as a hint, so handwriting, math, and symbols are read in context. Runs of typed pages still use text. If a page image fails, that page falls back to its recognized text.
- **Context for every section:** the document's title (unless it's a generic name like "Scan" or "IMG_1234") heads the notes, so every section knows the topic. When pages were read from handwriting, the model is told to expect misread words and symbols.
- **Handwriting:** PDF pages with little selectable text are read with Vision. For PDFs from note-taking apps, or whose first pages show much more text than they contain, every page is also read with Vision. Lines not already in the typed text are added.

**Keeping cards in sync.**
- **Detecting changes:** signed in, the app first compares the file's Drive version and skips unchanged files. Otherwise it compares a hash of the download. It then fingerprints the notes and diffs them line by line.
- **Claude:** reviews the whole deck against the edits in a single request.
- **Apple Intelligence:** handles one contiguous edit at a time:
  - For removed or changed lines, it first judges whether each related card is still correct, then keeps, updates, or removes it.
  - For added lines, it writes new cards, and near-duplicates of existing cards are dropped.
  - Large edits are split into separate changes, and each gets its own review and card limit, so a big update isn't capped at a few cards.
  - If Apple's safety filter blocks a structured review (common with history notes), the review is retried as plain text.
  - After the reviews, a check removes cards that clearly came from deleted lines: cards whose answer no longer appears in the notes, or that match a deleted line much better than any remaining one.

**Background processing.** `ProcessingCenter` runs each job as an iOS continued-processing task (`BGContinuedProcessingTask`, iOS 26+).
- **Live Activity:** the system shows it in the Dynamic Island and on the Lock Screen. The app updates its progress and subtitle ("About 40 sec left · Section 2 of 5").
- **Heartbeat:** iOS may end continued-processing tasks whose progress stalls, so the reported progress moves forward every 2 seconds, even while the model is between updates.
- **Foreground only:** iOS grants continued-processing time only to the app someone is using, so it's requested only while NoteFlash is active. Work started in the background runs on the background task's own time instead.
- **Fallback:** if iOS declines the request or later withdraws the time, the job keeps running in the app for the short grace period, then pauses with its progress saved.

**Work that outlives the app.** Nothing in flight lives only in memory.
- **Saved jobs:** `JobStore` keeps every unfinished job in the App Group: what to make, the files it needs (a shared PDF, photographed pages), how often it has been tried, and when it may continue. A job is deleted only once its cards exist.
- **Saved sections:** `SectionCache` writes finished sections to disk as well as memory, so a job that stops halfway resumes from where it stopped instead of spending the usage limit again. They're kept for three days.
- **Picking work up:** `restoreSavedJobs` runs at launch (not when a window appears — iOS also starts the app with no window), when the app becomes active, and during background runs. Jobs that can't succeed on a retry (notes NoteFlash can't read, a blocked or deleted deck, a sign-in that expired) aren't retried; the rest are, up to six times before waiting for **Retry**.
- **Catch-up task:** a `BGProcessingTask` (`com.ayushkansal.NoteFlash.catchup`) asks iOS to start NoteFlash in the background to finish the queue. It's requested when the app goes to background with work left, when a job pauses, when continued-processing time is withdrawn, and by the share extension after notes are shared. iOS runs these when the device is idle, and never for an app that was force-quit from the app switcher.
- **Handing time back:** when iOS expires the task, running jobs stop where they are, their state is saved, another catch-up is requested, and a notification tells the user how far it got. `isIdleTimerDisabled` keeps the screen on only while the app is active and a job is actually writing cards. Background app refresh also spends its ~30 seconds on the queue; with sections saved, even that makes progress.
- **Usage limits:** iOS limits how much Apple Intelligence work an app can do in a stretch, and long notes can reach that limit even while NoteFlash is open. `ModelLimits` handles it:
  - **Short limits:** it waits until the reset time iOS reports (iOS 27), or backs off from 5 seconds to 2 minutes. The job shows when it will continue.
  - **Long limits:** if the wait would be longer than 4 minutes, the job pauses. It resumes on its own at the reset time while the app is open, and a notification says when it can continue.
  - **No repeated work:** finished sections are kept (`SectionCache`), so a resumed or retried job skips them. Optional extra passes are skipped for 15 minutes after a limit.
  - **In the background:** Apple Intelligence rate-limits apps that aren't in the foreground, so background runs get through less before pausing. Each run still adds finished sections, and the job continues on the next one.
  - **Fewer requests:** every request counts against the limit, so the deck's name comes from the notes' heading or a section's own title when there is one, and exam-priority passes are skipped for points that already have a card once a limit has been hit.
  - **Finishing with Claude:** when a section hits a limit too long to wait out and a Claude API key is saved, that section is written by Claude and the job carries on instead of pausing. Sections already written on the device are kept.
  - **Shorter responses:** each request caps its response length, so a model that starts repeating itself stops early.
- **Stalls:** the model service sometimes stops mid-response for a minute or more. Responses are consumed on a separate task and watched. A response with no output for 20 seconds (45 before the first output) is cancelled and retried, up to twice. If it already wrote a good share of the section's cards, those are kept instead. Non-streaming requests get the same timeout.
- **Diagnostics:** `DiagnosticsLog` records job events and full error descriptions to the system log (subsystem `com.ayushkansal.NoteFlash`) and to `Documents/NoteFlash-processing-log.txt`.
- **Time estimates:** `ProcessingEstimator` starts from a per-engine rate (seconds per 1,000 characters), blends in the observed pace as progress arrives, and saves the rate it measures when each job finishes.

**Apple's cloud model (optional).** On iOS 27, `AppConfig.usePrivateCloudCompute` sends notes too long for one on-device request to Apple's larger Private Cloud Compute model. It needs the Private Cloud Compute managed entitlement from Apple ([details](https://developer.apple.com/private-cloud-compute/)), so it's off by default.

## Development notes

- Launch with the `-uiTesting` argument (Debug builds only) to use an in-memory store with a sample deck and an offline sample Drive (Docs, Slides, a PDF, and a PowerPoint file) for the picker.
- The share extension and the app must share the App Group `group.com.ayushkansal.NoteFlash` (see the `.entitlements` files). Automatic signing registers it.
- To test importing shared notes without the share sheet, add a folder with an `item.json` (see `SharedInbox.Item`) to the app group's `SharedInbox` directory. `xcrun simctl get_app_container booted com.ayushkansal.NoteFlash groups` prints its path.
- The on-device model's behavior varies from run to run, so check prompt changes against several kinds of notes.
- Launch with `-appleModelSelfTest` (Debug builds) to run the Apple Intelligence check at startup. The results go to `Documents/NoteFlash-processing-log.txt` in the app's data container. On a macOS 26 Mac, the iOS 27 Simulator can't load the on-device model, so every request fails with a model manager error.
- `-uiTesting` also swaps in a slow sample engine, so processing progress can be checked in the Simulator. The Simulator can't run continued-processing tasks or Apple's on-device model, so try the Live Activity on a real iPhone.
