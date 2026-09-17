# NoteFlash

A Quizlet-style flashcard app for iPhone and iPad. Paste notes, import a PDF, or link a Google Doc, and NoteFlash turns them into a deck of flashcards. Linked Google Docs stay in sync: when the doc changes, only the affected cards are updated, and new cards are added for new material.

## Features

- **Three ways to add notes:** type or paste text, import a PDF (scanned pages go through on-device text recognition), or add a Google Doc. Browse your Drive like the Drive app (My Drive folders, Shared, Starred, Recent), search by name or text, sort by name or date, switch between list and grid, and preview a doc before using it. You can also paste a link.
- **AI-written cards:** Apple Intelligence runs on the device by default (free, private, works offline). Claude is available as an option in Settings.
- **Google Doc sync:** linked docs are checked every 2 minutes while the app is open, and again through iOS background app refresh. Edits update, remove, or add only the cards they affect.
  - Cards you write or edit by hand are locked and never overwritten.
  - Changed cards get a "New" or "Updated" badge.
- **Study modes:**
  - **Flashcards:** flip cards and swipe them into Know or Still learning.
  - **Learn:** rounds that start with multiple choice and move to typed or self-graded recall.
  - **Match:** a timed matching game with penalties for wrong matches and a best time.
- **Background processing:** new decks, regenerated decks, note edits, and Google Doc updates all run as background jobs. The deck list shows each job's progress and time left.
  - **Leaving the app:** jobs keep running, with progress in the Dynamic Island and on the Lock Screen.
  - **If iOS stops background work:** the job pauses and picks up again when you open NoteFlash.
  - **When a job finishes in the background:** a notification lets you open the deck.
  - **Time estimates:** they learn how fast your device (or Claude) actually is.
  - **Troubleshooting:** a failed job shows the error details, and Settings → Processing Log keeps a history you can copy.
- **Deck tools:** stars, a "study starred only" filter, search, editing notes (text decks), regenerating a deck, and resetting progress.

## Requirements

- Xcode 27, iOS 26.0 or later.
- Apple Intelligence engine: an iPhone that supports Apple Intelligence, with it turned on. The on-device model usually can't run in the iOS Simulator.
- The project is signed with the **Ayush Kansal (Personal Team)** (`Z8Q7299GJV`). Bundle ID: `com.ayushkansal.NoteFlash`.
  - Apps signed with a free personal team expire after 7 days. Re-run from Xcode to reinstall.

## Setup

1. Open `NoteFlash.xcodeproj`, choose your iPhone, and press Run.
2. (Optional) To use **Claude**, open Settings, switch "Write cards with" to Claude, and paste an API key from [console.anthropic.com](https://console.anthropic.com/settings/keys). The key is stored only in the device Keychain. The model is set in `AppConfig.claudeModel`.
3. **Google Docs, no setup needed:** share the doc by link, then paste the link into NoteFlash's **Google Doc** tab. In Google Docs, tap **Share**, set **General access** to **Anyone with the link** (Viewer), and tap **Copy link**. NoteFlash reads the doc's text and name from the link and keeps checking it for changes. Anyone with the link can read the doc, so use the setup below for private notes.

### Google Docs setup (private docs, optional)

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and enable the **Google Docs API** and the **Google Drive API**.
2. Under **Google Auth Platform → Branding / Audience**, choose *External*, fill in the app name, and add your Google account as a **test user**.
   Under **Data Access**, add `…/auth/documents.readonly` and `…/auth/drive.metadata.readonly`.
3. Under **Credentials**, create an **OAuth client ID** of type **iOS**, with bundle ID `com.ayushkansal.NoteFlash`.
4. Paste the client ID (`…apps.googleusercontent.com`) into `AppConfig.googleClientID`.
5. In the app, open the Google Doc tab and choose **Choose from Google Drive** (or go to Settings and choose **Sign in with Google**).
   - NoteFlash asks for read-only access to your Docs and to your Drive file list (names and dates only), which it uses to show your Docs.
   - If you signed in before the file-list permission was added, tap **Allow Access** when the picker asks.

While the consent screen is in *Testing* mode, Google expires refresh tokens after 7 days, so you'll need to sign in again weekly. Publishing the app removes that limit.

## How it works

| Piece | Where |
| --- | --- |
| Data model (SwiftData) | `NoteFlash/Models` |
| AI engines (shared protocol, Apple, Claude) | `NoteFlash/Services/Engines` |
| Line diffing and section splitting | `TextDiff.swift`, `NoteChunker.swift` |
| Google sign-in (OAuth + PKCE, no SDK), Docs reading, Drive browsing | `GoogleAuth.swift`, `GoogleDocsClient.swift`, `GoogleDriveClient.swift`, `DriveDataSource.swift` |
| Drive picker (folders, sort, grid, preview) | `NoteFlash/Views/DocPicker` |
| Sync, note edits, regeneration | `DocSyncService.swift` |
| Screens and study modes | `NoteFlash/Views` |

**Card writing with Apple Intelligence.**
- **Sections:** long notes are split into sections that fit the model's 4,096-token context.
- **Card format:** each card is generated fact → question → answer, which gives the small model better questions.
- **Refused sections:** Apple's default safety filter often refuses ordinary history or health notes when it has to return structured output. Those sections are retried as plain-text Q/A under the permissive safety setting.
- **Thin sections:** a section that yields fewer cards than expected gets a second pass.

**Keeping cards in sync.**
- **Detecting changes:** the app fingerprints the notes and diffs them line by line.
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

- Launch with the `-uiTesting` argument (Debug builds only) to use an in-memory store with a sample deck and an offline sample Drive for the doc picker.
- The on-device model's behavior varies from run to run, so check prompt changes against several kinds of notes.
- `-uiTesting` also swaps in a slow sample engine, so processing progress can be checked in the Simulator. The Simulator can't run continued-processing tasks or Apple's on-device model, so try the Live Activity on a real iPhone.
