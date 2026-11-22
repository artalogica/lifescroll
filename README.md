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

### Keeping permissions across rebuilds

macOS grants Screen Recording, Accessibility and Keychain access to one signed copy of an app.
Without a signing certificate the build is signed ad-hoc, every rebuild counts as a new app, and
System Settings goes on showing the old copy as allowed while the new one has nothing.

Create a certificate once and the build script signs with it from then on:

1. Open **Keychain Access**.
2. In the menu bar choose **Keychain Access › Certificate Assistant › Create a Certificate…**
3. Name it `Lifescroll Dev`, set Identity Type to **Self-Signed Root** and Certificate Type to
   **Code Signing**, then create it.

Then rebuild, clear the grants left by earlier builds, and allow the permissions one last time:

```bash
./scripts/build-app.sh
```

```bash
tccutil reset ScreenCapture local.lifescroll.Lifescroll
```

```bash
tccutil reset Accessibility local.lifescroll.Lifescroll
```

```bash
open build/Lifescroll.app
```

The first signed build asks whether `codesign` may use the new key; choose Always Allow. The script
prints which way it signed. To sign with a different identity, set `LIFESCROLL_SIGN_IDENTITY`.

## How it works

| Loop | How often | What it does |
|---|---|---|
| Fast | every 5 s | Logs the front app and window title. Counts time on "scrolling" apps and fires the nudge. No model. Stops, along with capture, while the screen is locked or the display is off. |
| Capture | every 10 s | Captures the display under the pointer, skipping unchanged frames and excluded apps, and stores a 1280-pixel copy. About every 30 s, and whenever a new window comes to the front, the text is read off the full-size capture on this Mac. |
| Read | every 10 min | Claude Haiku 5.5 is sent the text of up to 12 key screens, each cut down to lines not already sent, and reports commitments, completions and content seen. A line counts as already sent only within the same window. |
| Index | after each read | Projects, people, documents and topics Haiku named are matched against the index by name. Claude Sonnet 5.5 is called only for names it has not seen before. |
| Merge | after each read | Claude Sonnet 5.5 merges commitments into the task list, sets importance, links each task to its project, and writes each card's "why now" line. |
| Suggest | when fewer than 4 are on hand, at most every 2 h | Claude Sonnet 5.5 searches the web itself (up to 5 searches) for things like what you have been watching and reading, steered toward the sites you already use. The Hacker News front page is added for picks outside your interests, and Sonnet chooses up to 8 worth a card. If the web search finds nothing, it falls back to planned searches of arXiv and Hacker News. |

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
"Not for me" removes it and is fed back into the next round of choosing. Sonnet is told never to
search for your name or your private projects. Links always come from the search results, never
from text the model wrote. Anthropic charges for each web search on top of tokens; Settings counts
the searches but does not price them.

Ranking is a hand-written score in `Logic.swift` (`Ranker.score`): importance, deadline urgency, how
often and how long ago you saw it, whether someone is waiting, and your "which matters more?" picks.
Your picks can outweigh everything inferred.

The interface is dark smoked glass throughout: a blurred, dark-tinted pane with light text, so it
reads the same over a white wallpaper as a dark one and in either system appearance. Colour is used
in one place only, the blush on suggestion cards.

Each task card has one main button. **Start** marks the task in progress and opens it, if it has a
link or an app to open. A task in progress moves to the front of the feed in every mode, shows how
long it has been going, and swaps its main button to **Done**; **Pause** puts it back among the
others. Starting, pausing and finishing are all recorded in the `events` table.

The card feed is a loop. Scroll with the trackpad, mouse wheel or arrow keys; after the last card the
first one comes back. Done and Never take a card out of the loop, and Not now hides it for three hours.

Sometimes a card is not a task at all. **Not a task**, under the card's buttons, beside each choice
of a "which matters more" question, and in All tasks, removes it and keeps it as an example. Those
examples go to Sonnet with every merge, so the same thing, and things of the same kind, stop being
added. Reopening one from All tasks takes the mark back.

The index is a small knowledge graph of projects, people, documents and topics. Two entries are
linked only when Haiku reports that a screen showed them to be related, with what it saw as
evidence: a person posting in a project's channel, a paper about a topic. Being on screen in the
same ten minutes links nothing. Stating a relationship again in a later reading strengthens it.

The **Projects** button in the popover opens the index as a node graph. Entries joined by links
gather into clusters. Each cluster keeps clear space around it and sits on a faint backdrop, with
the name of its best-connected entry in bold, so one section can be told from the next. Entries
with no links yet sit around the outside. The graph is a live simulation: it opens settled, and
when something is added or linked the dots ease into their new places.

Click a dot to see its tasks, what it is linked to and how, and a dated log of what you did with
it. Drag a dot to move it, or drag empty space to move the whole picture. Scroll with two fingers
to pan; pinch, or hold Command and scroll, to zoom. Until you pan or zoom, the view keeps everything
in frame by itself; the button in the corner, or a double-click on empty space, goes back to that.

To link two entries, select one and drag the plus that appears beside it onto the other: the line
snaps to a dot when it is close. Or click the plus and then click the other dot; Esc cancels. Each
link in the panel has a button to remove it. Entries can be added by hand from the row above the
graph. A List view is one switch away. "Remove from index" hides an entry and stops it being
re-added.

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
| `Sources/Lifescroll/Views.swift` | Popover, task list, projects and settings |
| `Sources/Lifescroll/Graph.swift` | The node graph: its layout and drawing |
| `Sources/Lifescroll/Theme.swift` | The smoked-glass look: panels, cards, pill buttons, switches, chips |
| `Sources/Lifescroll/Preview.swift` | Draws the interface to images with sample data |
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

To see the interface without running the app, draw it to images over a light and a dark backdrop.
It uses invented sample data and opens nothing of yours:

```bash
.build/debug/Lifescroll --render-ui build/ui-preview
```

To see how the graph lays out a real index, draw the Projects window from a database file. Give it
a copy, because opening a file brings it up to the current schema:

```bash
.build/debug/Lifescroll --render-graph /path/to/copy.sqlite build/graph.png
```

To time text recognition on your newest stored screenshots (it prints counts, never the text):

```bash
.build/debug/Lifescroll --ocr-test 12
```
