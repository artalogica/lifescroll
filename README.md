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
| Capture | every 10 s | Captures the display under the pointer, skipping unchanged frames and excluded apps, and stores a 1280-pixel copy. About every 30 s, and whenever a new window comes to the front, the text is read off the full-size capture on this Mac. |
| Read | every 10 min | Claude Haiku 5.5 is sent the text of up to 12 key screens, each cut down to lines not already sent, and reports commitments, completions and content seen. A line counts as already sent only within the same window. |
| Index | after each read | Projects, people, documents and topics Haiku named are matched against the index by name. Claude Sonnet 5.5 is called only for names it has not seen before. |
| Merge | after each read | Claude Sonnet 5.5 merges commitments into the task list, sets importance, links each task to its project, and writes each card's "why now" line. |
| Suggest | when fewer than 4 are on hand, at most every 2 h | Claude Sonnet 5.5 turns what you have been watching and reading into search queries. arXiv and Hacker News are searched directly, and Sonnet picks up to 8 results worth a card. |

Capture is text-first. Text recognition runs on-device (Apple's Vision framework, with language
detection on), so Claude is sent words, not pictures, for most screens. The three screens with the
least text in a reading, if under 800 characters, also get their screenshot sent. On 12 real
screenshots this came to about half the tokens of sending every image.

What is kept out and cleaned up:

- Windows matching a "never capture" word, and Lifescroll's own windows, are removed from the
  picture by the system before it is taken, wherever they sit on screen. If such a window is in
  front, the capture is skipped altogether.
- Things shaped like API keys, tokens and card numbers are masked before the text is stored or
  sent. This is a safety net for obvious shapes, not a guarantee.
- Screen text is erased as soon as its reading is done, and erased rows are overwritten in the
  database file. Screenshots are deleted after three days.
- Screen text is sent inside `<screen_text>` tags and Haiku is told it is content to report on,
  never instructions.

Suggestions are the enjoyable half of the feed: a paper, an essay, a talk. Opening one or pressing
"Not for me" removes it and is fed back into the next round of choosing. Search queries are general
subject words only; Sonnet is told never to include names, and queries are stripped to plain words
before they are sent. Links always come from the search results, never from the model's reply.

Ranking is a hand-written score in `Logic.swift` (`Ranker.score`): importance, deadline urgency, how
often and how long ago you saw it, whether someone is waiting, and your "which matters more?" picks.
Your picks can outweigh everything inferred.

The card feed is a loop. Scroll with the trackpad, mouse wheel or arrow keys; after the last card the
first one comes back. Done and Never take a card out of the loop, and Not now hides it for three hours.

The index is a small knowledge graph: entries are projects, people, documents and topics, and two
entries are linked each time they appear in the same ten-minute reading. The **Projects** button in
the popover opens it. Each entry shows its open tasks, what it is connected to, and a dated log of
what you did with it. "Remove from index" hides an entry and stops it being re-added.

Modes set both the nudge and the blend of the feed:

| Mode | Nudge | Feed |
|---|---|---|
| Pure dopamine | never | three suggestions, then a task |
| Balanced | after 20 minutes of scrolling | one suggestion after every three tasks |
| Lock in | after 5 minutes of scrolling | tasks only, and no suggestions are fetched |

## Where things are

| File | Contents |
|---|---|
| `Sources/Lifescroll/Capture.swift` | Front-window sampling and screenshots |
| `Sources/Lifescroll/ScreenText.swift` | On-device text recognition, masking of secrets, and trimming repeated lines |
| `Sources/Lifescroll/Analyzer.swift` | Prompts, JSON schemas, the read and merge steps |
| `Sources/Lifescroll/Recommendations.swift` | arXiv and Hacker News search, and the plan and pick steps for suggestions |
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

To run one real search against arXiv and Hacker News, with no Claude calls:

```bash
.build/debug/Lifescroll --fetch-test "distributed consensus"
```

arXiv answers 429 when requests come too close together, so leave a while between runs.

To time text recognition on your newest stored screenshots (it prints counts, never the text):

```bash
.build/debug/Lifescroll --ocr-test 12
```

## Not built yet

- Searching YouTube directly. Videos currently appear only when Hacker News links to one.
- Tone matching for card text.
- A learned ranker to replace the hand-written score.
- Using the index for ranking (a task inheriting urgency from its project) and for reopening a whole project.
- A local, zero-cost mode. Now that reading is text-first, a small local text model could replace Haiku.
