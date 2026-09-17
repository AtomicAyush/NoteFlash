# NoteFlash

A Quizlet-style flashcard app for iPhone and iPad. Paste notes, import a PDF or PowerPoint file, or link a Google Doc, Google Slides presentation, or file in Google Drive, and NoteFlash turns them into a deck of flashcards. Linked Drive files stay in sync: when the file changes, only the affected cards are updated, and new cards are added for new material.

## Features

- **Three ways to add notes:**
  - **Text:** type or paste notes.
  - **File:** import a PDF (scanned pages go through on-device text recognition) or a PowerPoint (.pptx) file. Slides contribute their titles, text, tables, and speaker notes.
  - **Google Drive:** use a Google Doc, Google Slides presentation, PDF, or PowerPoint file from Drive. Browse your Drive like the Drive app (My Drive folders, Shared, Starred, Recent), search by name or text, sort by name or date, switch between list and grid, and preview the text before using a file. You can also paste a link.
- **AI-written cards:** Apple Intelligence runs on the device by default (free, private, works offline). Claude is available as an option in Settings.
- **Google Drive sync:** linked files are checked every 2 minutes while the app is open, and again through iOS background app refresh. Edits update, remove, or add only the cards they affect. Files shared by link that aren't Docs have to be downloaded in full to check them, so they're checked every 15 minutes unless you tap **Check Now**.
  - Cards you write or edit by hand are locked and never overwritten.
  - Changed cards get a "New" or "Updated" badge.
- **Study modes:**
  - **Flashcards:** flip cards and swipe them into Know or Still learning.
  - **Learn:** rounds that start with multiple choice and move to typed or self-graded recall.
  - **Match:** a timed matching game with penalties for wrong matches and a best time.
- **Background processing:** new decks, regenerated decks, note edits, and Google Drive updates all run as background jobs. The deck list shows each job's progress and time left.
  - **Leaving the app:** jobs keep running, with progress in the Dynamic Island and on the Lock Screen.
  - **If iOS stops background work:** the job pauses and picks up again when you open NoteFlash.
  - **When a job finishes in the background:** a notification lets you open the deck.
  - **Time estimates:** they learn how fast your device (or Claude) actually is.
  - **Troubleshooting:** a failed job shows the error details, and Settings → Processing Log keeps a history you can copy. The log screen's **Check Apple Intelligence** button sends a few test requests to the on-device model and records the results.
- **Deck tools:** stars, a "study starred only" filter, search, editing notes (text decks), regenerating a deck, and resetting progress.

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
| PDF and PowerPoint text | `PDFTextExtractor.swift`, `PowerPointTextExtractor.swift`, `ZipArchive.swift` |
| Drive picker (folders, sort, grid, preview) | `NoteFlash/Views/DocPicker` |
| Sync, note edits, regeneration | `DocSyncService.swift` |
| Screens and study modes | `NoteFlash/Views` |

**Card writing with Apple Intelligence.**
- **Sections:** long notes are split into sections that fit the model's 4,096-token context.
- **Card format:** each card is generated fact → question → answer, which gives the small model better questions.
- **Refused sections:** Apple's default safety filter often refuses ordinary history or health notes when it has to return structured output. Those sections are retried as plain-text Q/A under the permissive safety setting.
- **Thin sections:** a section that yields fewer cards than expected gets a second pass.
- **Other failures:** if structured output fails or times out, the section is split or retried as plain text. iOS 26 (`LanguageModelSession.GenerationError`) and iOS 27 (`LanguageModelError`, `LanguageModelSession.Error`, `SystemLanguageModel.Error`, `GeneratedContent.ParsingError`) errors are grouped by `AppleModelFailure`. A model that can't be loaded, such as while it's downloading after an iOS update, gets its own message.

**Reading files.**
- **PowerPoint:** `PowerPointTextExtractor` unzips the .pptx (`ZipArchive`, using the Compression framework) and reads slides in presentation order. Titles become headings, body text becomes bullets, tables become rows, and speaker notes are kept. Dates, footers, and slide numbers are skipped.
- **Google Drive:** `DriveFileReader` reads each file type through the Google APIs when signed in:
  - **Docs:** the Docs API.
  - **Slides:** exported as .pptx, or as plain text for decks over Drive's 10 MB export limit.
  - **PDFs and PowerPoint files:** downloaded.
  - **Shared by link:** without sign-in, or when the signed-in account can't open a file, public export and download links are used. Their type is detected from the downloaded bytes.

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
- **Fallback:** if iOS declines the request or later withdraws the time, the job keeps running in the app. If the app is in the background when the short grace period runs out, the job pauses and resumes the next time the app becomes active.
- **Model limits:** Apple's model is rate-limited in the background, so requests wait and retry for about a minute before giving up.
- **Diagnostics:** `DiagnosticsLog` records job events and full error descriptions to the system log (subsystem `com.ayushkansal.NoteFlash`) and to `Documents/NoteFlash-processing-log.txt`.
- **Time estimates:** `ProcessingEstimator` starts from a per-engine rate (seconds per 1,000 characters), blends in the observed pace as progress arrives, and saves the rate it measures when each job finishes.

**Apple's cloud model (optional).** On iOS 27, `AppConfig.usePrivateCloudCompute` sends notes too long for one on-device request to Apple's larger Private Cloud Compute model. It needs the Private Cloud Compute managed entitlement from Apple ([details](https://developer.apple.com/private-cloud-compute/)), so it's off by default.

## Development notes

- Launch with the `-uiTesting` argument (Debug builds only) to use an in-memory store with a sample deck and an offline sample Drive (Docs, Slides, a PDF, and a PowerPoint file) for the picker.
- The on-device model's behavior varies from run to run, so check prompt changes against several kinds of notes.
- Launch with `-appleModelSelfTest` (Debug builds) to run the Apple Intelligence check at startup. The results go to `Documents/NoteFlash-processing-log.txt` in the app's data container. On a macOS 26 Mac, the iOS 27 Simulator can't load the on-device model, so every request fails with a model manager error.
- `-uiTesting` also swaps in a slow sample engine, so processing progress can be checked in the Simulator. The Simulator can't run continued-processing tasks or Apple's on-device model, so try the Live Activity on a real iPhone.
