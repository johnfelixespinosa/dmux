# dmux v1 — Implementation Handoff

## What Is dmux

A fork of [cmux](https://github.com/manaflow-ai/cmux) (AGPL-3.0) — a native macOS terminal multiplexer built with Swift/AppKit/Ghostty. dmux adds context-transfer gestures: drag a pane into another to merge Claude/Codex session context, or drag into empty space to fork a new pane with context.

**Repo:** https://github.com/johnfelixespinosa/dmux

---

## What Was Built (11 commits)

### 1. Staged Rebrand (`d4425ccb`)
- All user-facing strings, env vars, bundle IDs renamed from cmux → dmux
- `DMUX_*` env vars are primary, `CMUX_*` kept as backward-compatible aliases
- Socket path: `dmux.sock`, directory: `dmux`
- Bundle ID: `com.dmuxterm.app`
- **Files:** `GhosttyTerminalView.swift`, `SocketControlSettings.swift`, `cmuxApp.swift`, `CLI/cmux.swift`, `project.pbxproj`

### 2. Agent Provider Substrate (`30eb0cd4`)
- `AgentKind` enum (`.claude`, `.codex`)
- `TrackedAgentSession` struct — stores agent type, session ID, cwd, transcript path, panel/workspace IDs
- `TransferMessage` struct — normalized `{role, content}` from any agent
- `TransferPayload` enum — `.verbatim(String)`, `.summarized(original, summary)`, `.empty(reason)`
- `AgentContextProvider` protocol — `discoverSession()`, `extractMessages()`, `resolveTranscriptPath()`
- `AgentSessionRegistry` — singleton registry keyed by panel UUID
- **File:** `Sources/DmuxAgentProvider.swift`

### 3. Claude Provider (`cf73c199`)
- Implements `AgentContextProvider` for Claude Code
- Reads JSONL from `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`
- Parses `type: "user"` and `type: "assistant"` entries, skips progress/hooks/file-history-snapshot
- Handles both string content and content-block arrays
- Session discovery: finds latest `.jsonl` by modification date, excludes subagent files
- **File:** `Sources/DmuxClaudeProvider.swift`

### 4. Codex Provider (`95eda24d`)
- Implements `AgentContextProvider` for Codex CLI
- Reads JSONL from `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`
- Parses `response_item` (role: user/assistant), `turn_context` (user messages)
- Skips `session_meta`, `event_msg`, and `role: "developer"` (system prompts)
- Session discovery via `~/.codex/session_index.jsonl`
- **File:** `Sources/DmuxCodexProvider.swift`

### 5. Transfer Coordinator (`22044231`)
- Orchestrates context extraction → payload preparation → injection
- Short conversations (< 2000 tokens): injected verbatim
- Long conversations: summarized via Claude API (`claude-haiku-4-5-20251001`)
- API key resolution: `ANTHROPIC_API_KEY` env var → `~/.anthropic/api_key` file
- Fallback: if API unavailable, truncates to last 10 messages
- `inject(payload:into:)` writes to terminal PTY via `panel.surface.sendText()`
- **File:** `Sources/DmuxTransferCoordinator.swift`

### 6. Directional Split Shortcuts (`9f7af371`)
- Added `Ctrl+Shift+Arrow` for splitting in all 4 directions
- New `KeyboardShortcutSettings.Action` cases: `dmuxSplitLeft/Right/Up/Down`
- Routed through `AppDelegate.performSplitShortcut(direction:)` — same as existing `Cmd+D`
- **NOTE: These don't work** — `Ctrl+Shift+Arrow` is consumed by the terminal before reaching AppDelegate
- **Files:** `KeyboardShortcutSettings.swift`, `AppDelegate.swift`

### 7. Drag Coordinator (`4958e12e` + `729081c4`)
- `DmuxDragCoordinator` — workspace-level gesture engine
- Distance-based intent detection:
  - Drag stays inside source pane → **split** (direction from drag vector)
  - Drag crosses into another pane → **merge**
  - Drag crosses into empty space (no target pane) → **fork**
- Published properties: `isDragging`, `currentIntent`, `dragProgress` (0-1), `dragModeActive`
- Activation: `dragModeActive` toggled by clicking the arrow icon in pane header
- Auto-exits drag mode after completing a gesture
- **File:** `Sources/DmuxDragCoordinator.swift`

### 8. Drag Event Wiring (`255406c7`) — **BROKEN**
- Added `DmuxNotifications.swift` with `.dmuxDragStarted`, `.dmuxDragMoved`, `.dmuxDragEnded`
- `GhosttyTerminalView.mouseDown` — when `dragModeActive`, posts `.dmuxDragStarted` notification and returns
- `GhosttyTerminalView.mouseDragged` — posts `.dmuxDragMoved` notification
- `GhosttyTerminalView.mouseUp` — posts `.dmuxDragEnded` notification
- `Workspace.executeMerge()` and `Workspace.executeFork()` — async methods that extract context via provider and inject into target
- `WorkspaceContentView` — added `DmuxDragOverlayView` overlay (with empty `paneFrames: [:]`)
- **THE PROBLEM:** Notifications are posted but **nobody observes them**. No `NotificationCenter.addObserver` exists anywhere. The coordinator's `beginDrag()`, `computeIntent()`, and `endDrag()` are never called. The drag never actually starts.
- **Files:** `Sources/DmuxNotifications.swift`, `Sources/GhosttyTerminalView.swift`, `Sources/Workspace.swift`, `Sources/WorkspaceContentView.swift`

### 9. Drag Animation Overlay (`40a38e08`)
- `DmuxDragOverlayView` — SwiftUI overlay driven by coordinator's published state
- Split: glowing line (purple for horizontal, violet for vertical)
- Merge: orange border highlight on target pane
- Fork: green line at pane edge
- Renders nothing currently because `paneFrames` is always `[:]`
- **File:** `Sources/DmuxDragOverlayView.swift`

### 10. Context Card (`dd3e94d9`)
- `DmuxContextCardView` — floating card showing context preview during merge/fork
- Scales in from 0.5→1.0 based on `progress`, fades in
- Orange accent for merge, green for fork
- Not integrated into any view yet
- **File:** `Sources/DmuxContextCardView.swift`

### 11. Drag Toggle Button (`88012ef5`)
- Added 5th icon to pane tab bar: `arrow.up.and.down.and.arrow.left.and.right`
- Calls `requestNewTab(kind: "dmux-drag-toggle")` which Workspace handles to toggle drag mode
- **File:** `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift` (submodule)

### Tests (6 files)
- `DmuxAgentProviderTests.swift` — 5 tests
- `DmuxClaudeProviderTests.swift` — 3 tests
- `DmuxCodexProviderTests.swift` — 3 tests
- `DmuxDragCoordinatorTests.swift` — 10 tests
- `DmuxTransferCoordinatorTests.swift` — 4 tests
- `DmuxIntegrationTests.swift` — 9 tests

---

## What's Broken / Needs Fixing

### Critical: Drag gestures don't work
**Root cause:** The notification-based event wiring is a dead end. `GhosttyTerminalView` posts `.dmuxDragStarted`/`.dmuxDragMoved`/`.dmuxDragEnded` notifications, but nothing observes them. The `DmuxDragCoordinator.beginDrag()`, `computeIntent()`, and `endDrag()` methods are never called.

**The fix:** Replace the notification approach with **direct coordinator calls** in `GhosttyTerminalView`:

1. In `mouseDown` (when `dragModeActive`): directly call `workspace.dmuxDragCoordinator.beginDrag(at:sourcePanelId:sourcePaneBounds:)` and set a local `dmuxDragActive` flag on the view
2. In `mouseDragged` (when `dmuxDragActive`): call `workspace.dmuxDragCoordinator.computeIntent(currentPoint:targetPanelId:)` — need to implement target pane hit-testing
3. In `mouseUp` (when `dmuxDragActive`): call `workspace.dmuxDragCoordinator.endDrag()`, then execute the returned intent (split/merge/fork)

**Challenge:** The terminal view needs to:
- Know its own panel ID (available via `terminalSurface?.id`)
- Know its own bounds in window coordinates (available via `convert(bounds, to: nil)`)
- Determine which panel is under the current mouse point (needs hit-testing across sibling panes — requires workspace-level lookup)
- Access the workspace to call `executeMerge`/`executeFork`/`newTerminalSplit`

### Secondary: Overlay has no pane frames
`DmuxDragOverlayView` is mounted with `paneFrames: [:]` so it never renders anything. Needs to be populated with actual pane geometry from Bonsplit's layout.

### Secondary: Keyboard shortcuts don't work
`Ctrl+Shift+Arrow` is consumed by the terminal. Either use a different modifier combo or remove these shortcuts entirely since the drag toggle button replaces the need.

### Minor: Shell eval error
The `DMUX_*` env vars cause `(eval):[:2: too many arguments` in zsh startup. Likely a conditional in the user's `.zshrc` that doesn't handle the new variable names.

---

## Architecture Reference

```
User clicks drag icon → Workspace.dmuxDragCoordinator.toggleDragMode()
                                    ↓
                         dragModeActive = true
                                    ↓
User clicks in pane → GhosttyTerminalView.mouseDown
                                    ↓
                    coordinator.beginDrag(point, panelId, bounds)
                                    ↓
User drags → GhosttyTerminalView.mouseDragged
                                    ↓
              coordinator.computeIntent(point, targetPanelId?)
                        ↓                    ↓                ↓
                    .split(dir)        .merge(targetId)    .fork(dir)
                                    ↓
User releases → GhosttyTerminalView.mouseUp
                                    ↓
                    coordinator.endDrag() → (panelId, intent)
                        ↓                    ↓                ↓
              Workspace.newTerminalSplit   .executeMerge    .executeFork
                                    ↓
                         dragModeActive = false (auto-exit)
```

### Context Transfer Flow
```
executeMerge(source, target)
  → AgentSessionRegistry.session(forPanelId: source)
  → provider.extractMessages(from: transcriptPath)     // reads JSONL from disk
  → DmuxTransferCoordinator.preparePayload(messages)    // verbatim or summarize
  → DmuxTransferCoordinator.inject(payload, into: target) // sendText to PTY
  → closePanel(source)
```

### Key Files
| File | Role |
|------|------|
| `Sources/DmuxDragCoordinator.swift` | Intent detection engine |
| `Sources/DmuxAgentProvider.swift` | Shared types + provider protocol |
| `Sources/DmuxClaudeProvider.swift` | Claude JSONL reader |
| `Sources/DmuxCodexProvider.swift` | Codex JSONL reader |
| `Sources/DmuxTransferCoordinator.swift` | Verbatim/summarized delivery |
| `Sources/DmuxDragOverlayView.swift` | Split/merge/fork visual overlay |
| `Sources/DmuxContextCardView.swift` | Floating context card |
| `Sources/DmuxNotifications.swift` | Notification names (currently unused) |
| `Sources/GhosttyTerminalView.swift` | Mouse event interception (**broken**) |
| `Sources/Workspace.swift` | executeMerge/executeFork + drag coordinator property |
| `Sources/WorkspaceContentView.swift` | Overlay mounting |
| `vendor/bonsplit/.../TabBarView.swift` | Drag toggle button |

### Build & Run
```bash
git submodule update --init --recursive
./scripts/download-prebuilt-ghosttykit.sh   # or ./scripts/setup.sh with zig installed
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug build
CMUX_TAG=dmux-v1 "/path/to/DerivedData/.../Debug/dmux DEV.app/Contents/MacOS/dmux DEV"
```
