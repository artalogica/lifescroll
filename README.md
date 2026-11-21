# Lifescroll

A Mac menu bar app that watches your screen, works out what you left unfinished, and shows you one
card at a time saying what to do next. When you have been scrolling too long, it pushes the top card
at you as a notification.

Everything is stored on this Mac. Screenshots go to the Claude API to be read; nothing else leaves.

## Run it

```bash
./scripts/build-app.sh
```

```bash
open build/Lifescroll.app
```

First run:

1. Allow **Screen Recording** when macOS asks, then quit Lifescroll (power icon in its popover) and open it again.
2. Allow notifications when asked.
3. Click the menu bar icon, open Settings (gear), and paste a Claude API key. It is saved in your Keychain.
4. Optional: allow Accessibility in Settings for more reliable window titles.

The build is ad-hoc signed, so macOS asks for these permissions and for Keychain access again after
every rebuild. Signing with a real developer identity (full Xcode and a free Apple ID) stops that.

## How it works

| Loop | How often | What it does |
|---|---|---|
| Fast | every 5 s | Logs the front app and window title. Counts time on "scrolling" apps and fires the nudge. No model. |
| Capture | every 10 s | Saves a 1280-pixel screenshot of the display under the pointer, skipping unchanged frames and excluded apps. |
| Read | every 10 min | Claude Haiku 5.5 reads up to 12 key frames and reports commitments, completions and content seen. |
| Index | after each read | Projects, people, documents and topics Haiku named are matched against the index by name. Claude Sonnet 5.5 is called only for names it has not seen before. |
| Merge | after each read | Claude Sonnet 5.5 merges commitments into the task list, sets importance, links each task to its project, and writes each card's "why now" line. |

Ranking is a hand-written score in `Logic.swift` (`Ranker.score`): importance, deadline urgency, how
often and how long ago you saw it, whether someone is waiting, and your "which matters more?" picks.
Your picks can outweigh everything inferred.

The card feed is a loop. Scroll with the trackpad, mouse wheel or arrow keys; after the last card the
first one comes back. Done and Never take a card out of the loop, and Not now hides it for three hours.

The index is a small knowledge graph: entries are projects, people, documents and topics, and two
entries are linked each time they appear in the same ten-minute reading. The **Projects** button in
the popover opens it. Each entry shows its open tasks, what it is connected to, and a dated log of
what you did with it. "Remove from index" hides an entry and stops it being re-added.

Modes: **Pure dopamine** never interrupts, **Balanced** nudges after 20 minutes of scrolling,
**Lock in** after 5.

## Where things are

| File | Contents |
|---|---|
| `Sources/Lifescroll/Capture.swift` | Front-window sampling and screenshots |
| `Sources/Lifescroll/Analyzer.swift` | Prompts, JSON schemas, the read and merge steps |
| `Sources/Lifescroll/ClaudeClient.swift` | Raw HTTP to the Messages API, Keychain storage |
| `Sources/Lifescroll/Logic.swift` | Ranking, nudge timing, key-frame choice, applying merge decisions |
| `Sources/Lifescroll/Store.swift` | The SQLite schema and every query |
| `Sources/Lifescroll/AppModel.swift` | Timers, card actions, notifications |
| `Sources/Lifescroll/Views.swift` | Popover, task list and settings |
| `Sources/Lifescroll/SelfTest.swift` | Checks run by `--self-test` |

Data lives in `~/Library/Application Support/Lifescroll/`: `lifescroll.sqlite` and a `frames/` folder.
Raw screenshots are deleted after three days. The `events` table records every card shown and every
response; it is the training data for a future personal ranker.

## Check it

```bash
swift build && .build/debug/Lifescroll --self-test
```

Command Line Tools ship without XCTest, so the checks are built into the app.

To confirm a new build can open your existing data, point it at a copy of the database:

```bash
.build/debug/Lifescroll --check-db /path/to/copy.sqlite
```

## Not built yet

- Recommendations (videos, papers). What you watch and read is already recorded in `content_seen`.
- Tone matching for card text.
- A learned ranker to replace the hand-written score.
- Using the index for ranking (a task inheriting urgency from its project) and for reopening a whole project.
- Reading window text through Accessibility instead of pixels.
