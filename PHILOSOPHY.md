# Design Philosophy: Folio for KOReader

## The Single Sentence

> We build for the moment just before a reader disappears into a book — and the moment just after they surface from one.

Everything else follows from this.

---

## I. Why This Exists

Every design decision in a consumer product is, underneath, a philosophical position. Amazon's Kindle UI takes a position: *the reader is a customer first, a reader second.* Every screen is an opportunity to sell. The home screen is a storefront. The lock screen is an advertisement. The "library" is a catalog.

KOReader takes the opposite position and overshoots: *the reader is a power user.* Every feature is exposed. Every preference is configurable. The UI is a control panel. It respects the user's intelligence but punishes their patience.

Folio exists in the gap between these two failures.

We are not building a storefront. We are not building a control panel. We are building a **reading instrument** — precise, quiet, and entirely in service of the text.

---

## II. The Three Rejections

Before stating what we are, it is necessary to state what we refuse to be.

### Rejection 1: The App

Modern app design assumes color, animation, variable refresh rates, and a user who is in a state of perpetual scroll. None of these assumptions hold on an E-Ink device. An app mindset produces UI that fights the hardware. Every gradient is a lie the screen cannot tell. Every animation is a promise the display cannot keep. We reject the app paradigm entirely.

### Rejection 2: The Template

Template UI — rounded cards, subtle shadows, pastel accents, centered everything — is the visual equivalent of a form letter. It communicates nothing about the thing it contains. A reading interface built from templates produces the sensation of interacting with *software about books* rather than with *books themselves.* We reject the template.

### Rejection 3: The Feature List

The instinct to add is the enemy of the reading experience. Every feature added to a home screen is a micro-interruption demanding attention. A reading streak widget says: *think about your habits.* A recommendation row says: *think about what you haven't read.* A social feed says: *think about other people.* None of these are the book. We reject feature accumulation as a design value.

---

## III. The Foundational Belief: Friction Has a Direction

Not all friction is bad. The question is: which direction does it point?

**Friction toward the book is bad.** Any tap, swipe, load time, or decision that stands between the reader and the current page is a failure. This is why the bottom bar exists. This is why the "Currently Reading" card is the largest element on the home screen. This is why the power menu requires a deliberate tap rather than an accidental swipe. Every navigation decision is audited against this principle: does this friction pull the reader *away* from the book or *toward* it?

**Friction away from the book is sometimes necessary.** A reader should not accidentally close a book. A reader should not accidentally change their reading settings mid-chapter. Some resistance protects the reading state. This friction is intentional and kept invisible — you feel it only when you try to break the reading flow, which is exactly when you should feel it.

---

## IV. The E-Ink Constraint as Creative Mandate

Most software treats hardware constraints as problems to solve. We treat the E-Ink constraint as a **creative mandate** — a forcing function that produces better design.

E-Ink cannot do gradients. Therefore we use tonal layering — color shifts so subtle they feel like the difference between fresh paper and aged paper. The result is depth that feels physical rather than digital.

E-Ink cannot do animation. Therefore transitions are instantaneous. The reader does not watch the UI move; the UI simply *is* in the new state. This is closer to turning a page than to swiping a screen.

E-Ink has a refresh cycle that produces a brief black flash. Therefore we minimize full refreshes. Partial refresh artifacts — the slight ghosting, the faint echo of previous content — are not bugs to be hidden. They are the texture of the medium, as natural as the slight impression of type on the verso of a thin page.

E-Ink is grayscale. Therefore typography carries everything. The choice between `Newsreader` and `Public Sans` is not aesthetic preference — it is the primary mechanism for communicating the difference between content and tool. Serif means *read this.* Sans-serif means *use this.* The reader never has to think about this distinction; they feel it.

---

## V. Typographic Rhythm as Primary Structure

In print editorial design, the grid is invisible but felt everywhere. Column widths, baseline grids, and margin ratios create a sense of order that the reader experiences as trust — trust that someone organized this space with intention.

Folio imports this principle directly. The vertical rhythm of the home screen is not arbitrary. Elements are spaced so that the eye moves in a single continuous downward flow: status → time → book → actions → stats → navigation. There are no orphaned elements. There is no visual dead space that forces the eye to search. The reader's gaze arrives at the screen and slides, without interruption, to the currently reading card — which is always the largest, most prominent element, because the currently reading book is always the most important thing on the screen.

Left-alignment is not a default. It is a decision. Centered layouts feel like posters — they announce. Left-aligned layouts feel like pages — they invite. We invite.

---

## VI. The "No-Ornament" Rule

Ornament in UI design is any visual element that communicates nothing. Rounded corners on a button are ornament. Drop shadows are ornament. Icon outlines that are three pixels wider than necessary are ornament. Decorative divider lines between sections are ornament.

Ornament on E-Ink does not merely waste space — it actively degrades the display. Every unnecessary pixel rendered is a pixel that might ghost, that might refresh poorly, that might create visual noise at the exact moment the reader is trying to settle into focus.

The "No-Ornament" rule is therefore not minimalism as aesthetic preference. It is a technical requirement that happens to produce beautiful results. When ornament is stripped away, what remains is either necessary or absent. The necessary elements become legible. The absent elements are not missed.

The single permitted exception: the thick reading progress bar. This is deliberately chunky — unmissably so — because progress through a book is the one piece of data that earns the right to visual weight. It is not ornament. It is information so important that it should be visible at a glance across a dim room.

---

## VII. Information Hierarchy: What the Screen Knows About You

The home screen knows three things about the reader:

1. What they are reading right now
2. How long they have been reading
3. What they read before this

Everything else is speculation. Recommendations are speculation. Reading goals imposed from outside are speculation. "Trending" is someone else's speculation about your taste.

The home screen presents only what it knows, in order of certainty. Currently reading: certain. Recent books: certain. Reading streak: certain. Reading goal count: uncertain — it depends on how "finished" is defined, which is why the reading goals fix was critical. Showing wrong data with confidence is worse than showing no data at all.

This hierarchy is the reason the home screen cannot grow indefinitely. Every new widget added is a new piece of data that must earn its certainty. If it cannot be calculated reliably, it does not appear.

---

## VIII. The Relationship Between Speed and Trust

A UI that loads slowly is a UI that the reader does not trust to be there when they need it. Speed on E-Ink is not about frames per second — the display cannot produce frames per second. Speed on E-Ink is about **decision latency**: the time between the reader's intent and the result of that intent.

When a reader picks up their Kindle, their intent is to read. The home screen should present the currently reading book within one second of KOReader loading. The tap to open that book should produce a response — any response, even a loading indicator — within one refresh cycle. The reading view should be stable and ready within two seconds.

Every plugin, patch, and widget added to Folio is evaluated against this latency budget. A widget that takes 800ms to query statistics.sqlite3 and render a reading streak is a widget that costs 800ms of reader attention before the book opens. This cost must be justified by the value of the information. A streak counter barely justifies it. A social feed does not.

---

## IX. Contribution Philosophy

Folio is open source because the reading experience should not be owned. The plugin exists because KOReader's default UI fails readers, and Amazon's UI betrays them. The fix is public, forkable, and improvable by anyone who cares enough to understand the constraints.

Contributing to Folio means accepting the constraints of this philosophy before writing a line of code. The question is never "can we add this?" The question is always "does this serve the moment just before a reader disappears into a book?"

If the answer is yes, clearly and demonstrably yes, the contribution belongs here.

If the answer requires justification, the contribution may belong in a separate plugin that readers can choose to install.

If the answer is no, the contribution belongs in a different project with a different philosophy — and that is not a failure. It is a recognition that different readers need different tools, and that Folio is not trying to be every tool.

---

## X. The Last Principle

The best interface for reading is no interface at all.

Every improvement to Folio is a step toward making itself invisible. The home screen should feel like the inside cover of a book — present when you need orientation, absent when you are reading. The bottom navigation bar should feel like a bookmark — there when you look for it, unfelt when you don't.

We are building toward our own irrelevance. When a reader picks up their Kindle, opens KOReader, and thinks about nothing except the book — that is when Folio has succeeded.

---

*This document is the philosophical parent of `DESIGN.md`. When a decision in `DESIGN.md` seems arbitrary, the reason lives here. When a contribution seems reasonable but feels wrong, this document is the test.*
