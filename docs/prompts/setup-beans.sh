#!/bin/bash
# Project: deskhand
# Generated: 2026-11-12
# Source plan: docs/prompts/deskhand-a-native-macos-service-that-lets-crew-agents-in-k3s.md
# Requests: deskhand-r-waw0 (spike), deskhand-r-nkjj (v0)

set -euo pipefail

if bn list -n 0 --json --type epic | python3 -I -c 'import json,sys; sys.exit(0 if any(i.get("title")=="Epic: deskhand" for i in json.load(sys.stdin)) else 1)'; then
  echo "An open 'Epic: deskhand' already exists; refusing to create a duplicate graph." >&2
  exit 1
fi

PLAN="docs/prompts/deskhand-a-native-macos-service-that-lets-crew-agents-in-k3s.md"

mk() { # title type priority parent label description
  bn create "$1" -t "$2" -p "$3" --parent "$4" -l "$5" -d "$6" --silent --no-sync
}
dep() { bn dep add "$1" "$2" --no-sync >/dev/null; }

echo "Creating deskhand beans..."

# Epics are rollups: never a dependency edge to or from them; kept out of bn ready via in_progress.
EPIC=$(bn create "Epic: deskhand" -t epic -p 0 -l desktop-control --silent --no-sync \
  -d "Native macOS service letting Crew agents in k3s pods screenshot and control a Mac desktop over MCP. Fulfills deskhand-r-waw0 (spike) and deskhand-r-nkjj (v0). Plan: $PLAN")
bn update "$EPIC" --status in_progress --no-sync >/dev/null

sub() { local id; id=$(mk "$1" epic 0 "$EPIC" "$2" "$3"); bn update "$id" --status in_progress --no-sync >/dev/null; echo "$id"; }
E_GATE=$(sub "Epic: deskhand external gates" gate "Owner decisions and sibling-project deliverables. Gate tasks close on evidence only (closed sibling issue/request link or owner decision quoted with date).")
E_SPIKE=$(sub "Epic: deskhand spike (deskhand-r-waw0)" spike "Prove what macOS allows on both Macs. Ends in a go/no-go decision.")
E_CONTRACT=$(sub "Epic: deskhand contract" contract "Versioned docs/contract.md that Crew builds against, with amendments approved by the owner.")
E_CORE=$(sub "Epic: deskhand v0 core and server" core "Platform-independent Swift modules (Linux-testable) and the mTLS MCP server.")
E_PLAT=$(sub "Epic: deskhand platform adapters" platform "macOS-only adapters: capture, input, state probes, menu bar, kill switch, log daemon, composition.")
E_PKG=$(sub "Epic: deskhand packaging and CI" packaging "Scaffold, Linux GitHub Actions, Forgejo native-Mac CI, signed bundle, install, README.")
E_ACC=$(sub "Epic: deskhand acceptance" acceptance "Manual on-Mac checks, pod acceptance from three node types, Crew smoke test, request closure.")

# ========================================
# External gates (label: gate)
# ========================================
G_MODE=$(mk "Gate: owner decides console mode A (dedicated account) or B (owner session)" task 0 "$E_GATE" gate \
  "Owner: Matt. Source: birbhomes-r-ttg5. Mode B needs a recorded exception to birbhomes .agents/skills/k3s-worker-onboard/references/macos.md. Close with the owner's decision quoted and dated.")
G_SIGN=$(mk "Gate: owner chooses signing identity and Apple team for installed builds" task 0 "$E_GATE" gate \
  "Owner: Matt. Developer ID Application vs Apple Development; one fixed identity for every installed build (TN3127: different identities do not share TCC grants). Close with identity type, team ID and where the identity lives. Never expose it to CI without explicit approval.")
G_PCC=$(mk "Gate: owner decides whether to apply for Persistent Content Capture entitlement" task 1 "$E_GATE" gate \
  "Owner: Matt. com.apple.developer.persistent-content-capture is Apple-approved and may be the only route around the recurring screen-recording prompt (unconfirmed). Close with decision and, if applied, the request status.")
G_ALLOW=$(mk "Gate: owner decides whether deskhand keeps a node-IP allowlist" task 1 "$E_GATE" gate \
  "Owner: Matt. Plan default: no allowlist inside deskhand; pf anchor (birbhomes-r-5elb) owns source filtering, the credential is the access control. Conflicts with birbhomes-r-ttg5 passing an allowlist. Close with decision.")
G_AMEND=$(mk "Gate: owner approves contract amendments (gated state, no internal allowlist)" task 0 "$E_GATE" gate \
  "Owner: Matt. Approval = an owner note on every affected request (deskhand-r-nkjj, crew-r-yqso, birbhomes-r-5elb, birbhomes-r-ttg5). Screenshot-limit amendment already approved 2026-11-12. Close with links to the notes.")
G_NET=$(mk "Gate: birbhomes delivers Service, EndpointSlice and pf anchor per Mac" task 1 "$E_GATE" gate \
  "Owner: birbhomes (birbhomes-r-5elb). Selectorless Service + EndpointSlice deskhand-<mac> in namespace forge; NetworkPolicy forge-deskhand; pf anchor admitting node IPs. Close with link to closed birbhomes issue.")
G_CERTS=$(mk "Gate: birbhomes issues CA, server certs, shared client cert and per-Mac tokens" task 1 "$E_GATE" gate \
  "Owner: birbhomes (birbhomes-r-5elb, scripts/forge-production.py). Server SANs deskhand-<mac>.forge.svc and .forge.svc.cluster.local; 90-day leaves; Mac-side owner-only files. Close with link to closed birbhomes issue. No credentials in evidence.")
G_ALLOWANCE=$(mk "Gate: birbhomes ships allowance publisher and per-Mac deskhand config" task 1 "$E_GATE" gate \
  "Owner: birbhomes (birbhomes-r-ttg5). Root-owned allowance file in the format proposed by the contract task, atomic rename publish; per-Mac config (listen address, app policy, credential paths). Close with link.")
G_CREW=$(mk "Gate: Crew client speaks MCP 2026-07-28 and contract v1.0" task 2 "$E_GATE" gate \
  "Owner: crew (crew-r-yqso). Executor holds credentials, sends call ID as operation_id, renews lease. Close with link to closed crew issue.")
G_FORGEJO=$(mk "Gate: Forgejo mirror of deskhand with Actions enabled" task 1 "$E_GATE" gate \
  "Owner: Matt / birbhomes Ferry. Mirror at git.birb.homes with Actions enabled so runner birb-optin-lunus-macbook-pro-macos-arm64 can run .forgejo/workflows. Close with mirror URL and a passing run link.")
G_ACCESS=$(mk "Gate: schedule physical access to both Macs for spike and manual tests" task 1 "$E_GATE" gate \
  "Owner: Matt. lunus-macbook-pro (10.0.0.149) and m1max2021 (10.0.0.96). Needed for TCC grants, lock/lid/user-switch trials and manual checklist. Close with owner note.")

# ========================================
# Packaging and CI: scaffold first
# ========================================
SCAFFOLD=$(mk "Scaffold Swift 6 package, module layout, swift-format, gitignore" task 0 "$E_PKG" packaging \
  "Package.swift (swift-tools 6.x, strict concurrency) with targets: DeskhandCore (pure, Linux-buildable), DeskhandServer (SwiftNIO + NIOSSL, Linux-buildable), DeskhandPlatform (macOS only), DeskhandApp (macOS), and test targets using Swift Testing. Add .swift-format, .gitignore (build outputs, generated test binaries), README skeleton. Files: Package.swift, Sources/*, Tests/*, .swift-format, .gitignore. Done when swift build and swift test pass on macOS and on Linux (pure targets).")
CI_LINUX=$(mk "Linux GitHub Actions: lint, build and test pure modules, docs checks" task 1 "$E_PKG" ci \
  "ubuntu-* runners only, never GitHub macOS runners. Jobs: swift-format lint, swift build/test for DeskhandCore and DeskhandServer, markdownlint, link check. Pin actions by commit. Files: .github/workflows/**. Done with a green run link.")
dep "$CI_LINUX" "$SCAFFOLD"
CI_MAC=$(mk "Forgejo native-Mac workflow: build and test macOS targets" task 1 "$E_PKG" ci \
  "File: .forgejo/workflows/mac.yml, runs-on: birb-optin-lunus-macbook-pro-macos-arm64 (exact label). Pin actions by commit, no credentials in argv/logs/artifacts. Tests needing TCC, a GUI session or a real display are tagged and excluded. Done with a passing run link on git.birb.homes.")
dep "$CI_MAC" "$SCAFFOLD"; dep "$CI_MAC" "$G_FORGEJO"

# ========================================
# Spike (deskhand-r-waw0)
# ========================================
SP_APP=$(mk "Spike: throwaway signed probe app bundle" task 0 "$E_SPIKE" spike \
  "Under spike/ (excluded from the main package). Probes for: SCK capture + exclusion, CGEvent posting, permission preflights (screen, post-event, AX), session/lock/display-asleep signals, IOPMAssertionDeclareUserActivity, IsSecureEventInputEnabled, RegisterEventHotKey, an inbound TCP listener, HID seconds-since-last-event. Signed with the identity chosen in the signing gate. Files: spike/**.")
dep "$SP_APP" "$G_SIGN"
SP_MBP=$(mk "Spike: run items 1-9 and research additions on lunus-macbook-pro" task 0 "$E_SPIKE" spike \
  "Record pass/fail/inconclusive with evidence per item in docs/spike-results.md (section lunus-macbook-pro). Includes: macOS version; recurring prompt; Event Synthesizing / Device Control grants; Remote Desktop setting; permission persistence across same-identity upgrade; locked/asleep/lid/clamshell/user-switch/login-window behavior; power assertion; secure input targets; capture exclusion of real password manager and messaging apps; Retina/external/left-placed display mapping; Local Network prompt; wallpaper-only capture from LaunchAgent; own posts vs HID idle counter; modifier chords vs global hot keys; held synthetic input after process exit.")
dep "$SP_MBP" "$SP_APP"; dep "$SP_MBP" "$G_ACCESS"
SP_M1=$(mk "Spike: run items 1-9 and research additions on m1max2021" task 0 "$E_SPIKE" spike \
  "Same checklist as the lunus-macbook-pro spike run, recorded under the m1max2021 section of docs/spike-results.md.")
dep "$SP_M1" "$SP_APP"; dep "$SP_M1" "$G_ACCESS"
SP_LOCK=$(mk "Spike: lock-detection qualification, 20/20 trials per lock path on both Macs" task 0 "$E_SPIKE" spike \
  "Paths: menu, hot corner, lid, idle timeout, fast user switching. Zero false 'unlocked'. Pick the signal or conclude fail-closed (uncertain = locked). Record trial logs in docs/spike-results.md.")
dep "$SP_LOCK" "$SP_APP"; dep "$SP_LOCK" "$G_ACCESS"
SP_NET=$(mk "Spike: item 10, Lima guest reachability to own host and other Mac" task 1 "$E_SPIKE" spike \
  "From each Mac's Lima guest across socket_vmnet bridged mode, test reaching its own host LAN address and the other Mac's. Record results; own-host failure is a documented limitation, not a blocker.")
dep "$SP_NET" "$SP_APP"
SP_DECIDE=$(mk "Spike: go/no-go decision and recommendations for open v0 decisions" task 0 "$E_SPIKE" "spike,decision" \
  "Write recommendations in docs/spike-results.md for: minimum macOS, lock signal, blank-frame detection, permission set, log writer (root daemon vs sappnd), held-input recovery. If capture or input is impossible in a required state, escalate to owner and keep dependent v0 tasks blocked. On go: bn request update deskhand-r-waw0 --status done after the doc is merged.")
dep "$SP_DECIDE" "$SP_MBP"; dep "$SP_DECIDE" "$SP_M1"; dep "$SP_DECIDE" "$SP_LOCK"; dep "$SP_DECIDE" "$SP_NET"

# ========================================
# Contract
# ========================================
C_DRAFT=$(mk "Draft docs/contract.md: tools, schemas, errors, states, limits, amendments" task 0 "$E_CONTRACT" contract \
  "MCP revision 2026-07-28; tools status/displays/screenshot/pointer/keyboard with input/output JSON Schemas; error-code table (isError tool results vs JSON-RPC errors); state table with precedence and transition effects; handle scoping; operation outcome model; screenshot constants (max_long_edge 2576, max_pixels 3,750,000, verify against computer-use docs); coordinate mapping; allowance file format; deadline bound 1 s; user_active 250 ms; 'Changes from the shared contract' section. Files: docs/contract.md, docs/schemas/**.")
C_VALIDATE=$(mk "Contract schema validation script and CI check" task 2 "$E_CONTRACT" "contract,ci" \
  "Validate docs/schemas/** are valid JSON Schema and examples in docs/contract.md conform. Wire into Linux CI. Files: scripts/validate-contract.*, docs/schemas/**.")
dep "$C_VALIDATE" "$C_DRAFT"; dep "$C_VALIDATE" "$CI_LINUX"
C_NOTES=$(mk "Post contract amendments and allowance format on sibling requests" task 1 "$E_CONTRACT" contract \
  "Add notes to deskhand-r-nkjj, crew-r-yqso, birbhomes-r-5elb, birbhomes-r-ttg5 describing each amendment and the allowance JSON format, linking docs/contract.md.")
dep "$C_NOTES" "$C_DRAFT"
C_PUBLISH=$(mk "Publish docs/contract.md v1.0" task 0 "$E_CONTRACT" contract \
  "Incorporate spike recommendations, mark v1.0, tag the commit. Blocked on amendment approval.")
dep "$C_PUBLISH" "$C_DRAFT"; dep "$C_PUBLISH" "$C_NOTES"; dep "$C_PUBLISH" "$G_AMEND"; dep "$C_PUBLISH" "$SP_DECIDE"

# ========================================
# Core (pure, Linux-testable)
# ========================================
K_TYPES=$(mk "Core: contract types, error codes, canonical JSON and request digest" task 0 "$E_CORE" core \
  "Codable types mirroring docs/contract.md; canonical JSON encoding and SHA-256 request digest (tool + arguments, no transport metadata). Files: Sources/DeskhandCore/Contract/**, Tests/DeskhandCoreTests/Contract*.")
dep "$K_TYPES" "$SCAFFOLD"; dep "$K_TYPES" "$C_DRAFT"
K_STATE=$(mk "Core: state reducer with precedence and transition effects" task 0 "$E_CORE" core \
  "Pure reducer: conditions -> reported state + active conditions; precedence gated > paused > disarmed > not_console > locked > display_asleep > permission_missing > permission_stale > secure_input > ok; effects of leaving ok (cancel, release, invalidate frames), lease drop for gated/paused/disarmed, paused leaves disarmed. Exhaustive table-driven tests. Files: Sources/DeskhandCore/State/**.")
dep "$K_STATE" "$K_TYPES"
K_FRAME=$(mk "Core: frame store, screenshot sizing math and coordinate mapping" task 0 "$E_CORE" core \
  "Frame record (display ID, global-point rect with negative origins, source/output size, pointPixelScale, config generation); scale = min(1, max_long_edge/long, sqrt(max_pixels/(w*h))) with floor and min 1; caller max_long_edge >= 256 else invalid_argument; mapping rect.origin + (x+0.5)*rect.size/output_size; out_of_frame; stale_frame rules (not latest, too old, config changed, pixels around target changed via hook). Files: Sources/DeskhandCore/Frames/**.")
dep "$K_FRAME" "$K_TYPES"
K_LEASE=$(mk "Core: lease manager scoped to principal and holder ID" task 1 "$E_CORE" core \
  "Acquire/renew/release/expire with TTL; one holder per desktop; principal = client cert subject; lease_not_held errors; survives token replacement. Files: Sources/DeskhandCore/Lease/**.")
dep "$K_LEASE" "$K_TYPES"
K_OPS=$(mk "Core: durable operation store with payload binding and restart recovery" task 0 "$E_CORE" core \
  "Lifecycle accepted -> executing -> completed/aborted/failed with events-posted count; fsync before first event and after final state; operation_id_conflict on digest mismatch; operation_in_progress; no eviction inside 24 h window, operation_capacity at 10,000 per principal; restart marks accepted failed_before_execution and executing aborted_by_restart. Owner-only file. Files: Sources/DeskhandCore/Operations/**.")
dep "$K_OPS" "$K_TYPES"
K_LEDGER=$(mk "Core: durable held-input ledger with fault-injection tests" task 0 "$E_CORE" core \
  "Write 'possibly held' + fsync before each down event, clear + fsync after matching up; recovery releases conservatively; crash during cleanup leaves remaining entries. Fault-injection tests at each boundary (before write, between write and post, after post, during cleanup). Files: Sources/DeskhandCore/Ledger/**.")
dep "$K_LEDGER" "$K_TYPES"
K_POLICY=$(mk "Core: app policy engine and denied-shortcut rules" task 1 "$E_CORE" core \
  "Deny-by-default allowlist by bundle ID + team ID; default denies Terminal/shells, System Settings, Keychain Access, password managers, mail, messaging, all browsers; denied chords (Cmd-Space, Cmd-Tab, Cmd-Option-Esc, Ctrl-arrows, screenshot shortcuts, configurable); capture-exclusion list; uncertain -> denied_app. Files: Sources/DeskhandCore/Policy/**.")
dep "$K_POLICY" "$K_TYPES"
K_CONFIG=$(mk "Core: config model, loader and per-minute action ceiling" task 1 "$E_CORE" core \
  "Config file schema: listen address/port (never loopback-only or all interfaces by default), Service DNS names, credential paths, allowance path, app policy, limits (request size, text size, frame max age, rate ceiling), retention. Validation errors are explicit. Token-bucket per-minute ceiling -> rate_limited. Files: Sources/DeskhandCore/Config/**.")
dep "$K_CONFIG" "$K_TYPES"
K_ALLOW=$(mk "Core: allowance file validator" task 0 "$E_CORE" core \
  "O_NOFOLLOW open; regular file; root-owned, not group/world writable, root-owned parent; JSON {version, mac, not_before, expires_at} UTC RFC 3339; mac match; configured skew; cache <= 1 s; missing/invalid/expired -> gated. Tests use injected file-owner probe. Files: Sources/DeskhandCore/Allowance/**.")
dep "$K_ALLOW" "$K_CONFIG"
K_LOG=$(mk "Core: action log entry format and fail-closed log client protocol" task 1 "$E_CORE" core \
  "Entry: time, caller node address, principal, operation_id, frame_id, frame digest, tool, frontmost app, outcome; typed text as length only; no image bytes; no credentials. Protocol for intent-before / outcome-after writes; failure -> log_unavailable. Files: Sources/DeskhandCore/Log/**.")
dep "$K_LOG" "$K_TYPES"
K_EXEC=$(mk "Core: serial input executor with abort and release" task 0 "$E_CORE" core \
  "One executor per Mac; busy when running; validates frame, lease, policy, state at start and before every event via protocols; per-operation held-input tracking via ledger; abort releases only that operation's input, honoring cleanup authorization (no releases while locked, not_console, login window, secure_input; defer instead); integrates operation store and log client. Files: Sources/DeskhandCore/Executor/**.")
dep "$K_EXEC" "$K_STATE"; dep "$K_EXEC" "$K_FRAME"; dep "$K_EXEC" "$K_LEASE"; dep "$K_EXEC" "$K_OPS"; dep "$K_EXEC" "$K_LEDGER"; dep "$K_EXEC" "$K_POLICY"; dep "$K_EXEC" "$K_LOG"
K_WATCH=$(mk "Core: execution watchdog for deadlines, revocation and user activity" task 0 "$E_CORE" core \
  "Deadline = min(allowance expires_at, lease expiry, arming expiry), checked before each event and by timer while idle; allowance file watch + 1 s poll; cancel and release within 1 s; HID activity poll every 100 ms ignoring own posts, abort with user_active within 250 ms. Tests with fake clock and fake activity source for typing, drag and chord interruption. Files: Sources/DeskhandCore/Executor/Watchdog*.")
dep "$K_WATCH" "$K_EXEC"; dep "$K_WATCH" "$K_ALLOW"
K_RESTART=$(mk "Core: restart recovery orchestration" task 1 "$E_CORE" core \
  "On start: recover operation store and ledger, invalidate frames, drop lease, post ledger releases only when cleanup is authorized, else cleanup_pending and refuse all effects until done. Files: Sources/DeskhandCore/Recovery/**.")
dep "$K_RESTART" "$K_EXEC"

# ========================================
# Server (SwiftNIO + NIOSSL, Linux-testable)
# ========================================
N_TLS=$(mk "Server: SwiftNIO mTLS listener with Host/Origin checks and limits" task 0 "$E_CORE" server \
  "NIOSSL server, certificateVerification .fullVerification, trustRoots = private CA only, PEM key/cert from owner-only files (refuse looser modes); bind configured address; 403 on any Origin; reject Host not in configured Service DNS names + port; request size limits incl. base64 overhead; keep-alive max 5 min; no CORS; 401 on bad token; principal = client cert subject. Files: Sources/DeskhandServer/Listener/**.")
dep "$N_TLS" "$K_CONFIG"
N_ROTATE=$(mk "Server: credential reload on file change and SIGHUP" task 1 "$E_CORE" server \
  "Validate new cert/key pair (match, chain to CA, in date, SANs include configured names) before swap; new connections use it, existing run until close; invalid -> keep old + credentials_warning condition; token checked per request with configurable overlap (default 0). Files: Sources/DeskhandServer/Credentials/**.")
dep "$N_ROTATE" "$N_TLS"
N_MCP=$(mk "Server: sessionless MCP 2026-07-28 JSON-RPC handler" task 0 "$E_CORE" server \
  "server/discover, tools/list, tools/call; MCP-Protocol-Version, Mcp-Method, Mcp-Name header/body match (400, -32020); version negotiation (-32022); GET/DELETE 405; resultType; explicit tool annotations; refusals as isError results with structuredContent code; closing the response stream cancels the call. Reuse swift-sdk value types only where they match 2026-07-28. Files: Sources/DeskhandServer/MCP/**.")
dep "$N_MCP" "$N_TLS"; dep "$N_MCP" "$K_TYPES"
N_TOOLS=$(mk "Server: tool handlers wired to core via platform protocols" task 0 "$E_CORE" server \
  "status (always allowed, reports state + conditions), displays, screenshot, pointer, keyboard (newline/tab refused, text size limit, secure input refusal); handles scoped to principal + holder; effect results include measured frontmost app and window title. Platform behind protocols with fakes. Files: Sources/DeskhandServer/Tools/**.")
dep "$N_TOOLS" "$N_MCP"; dep "$N_TOOLS" "$K_WATCH"; dep "$N_TOOLS" "$K_RESTART"
N_E2E=$(mk "Server: end-to-end tests with fake platform over real mTLS" task 0 "$E_CORE" "server,test" \
  "Test CA generated at test time (never committed). Cases: wrong cert, wrong token, Origin present, bad Host, each state's error, stale frame, denied app, repeated operation_id, conflicting payload, busy, cancel on disconnect, rotation. Runs on Linux CI. Files: Tests/DeskhandServerTests/**.")
dep "$N_E2E" "$N_TOOLS"; dep "$N_E2E" "$N_ROTATE"
SEC_REVIEW=$(mk "Security review of v0: auth, listener, log, policy, recovery" task 1 "$E_CORE" "security,review" \
  "Two independent reviewers against docs/contract.md and the plan's safety rules; findings fixed or rejected with reasons. Covers credential handling (never in logs/errors/fixtures), handle scoping, fail-closed paths.")
dep "$SEC_REVIEW" "$N_E2E"

# ========================================
# Platform adapters (macOS)
# ========================================
P_CAPTURE=$(mk "Platform: ScreenCaptureKit capture adapter with exclusions and encoding" task 0 "$E_PLAT" platform \
  "SCShareableContent, SCContentFilter(display:excludingApplications:exceptingWindows:), SCScreenshotManager; regions via filter + source rect only; downscale per frame math; JPEG q85 default, PNG on request, 5 MB loop to q60 then image_too_large; display config generation; blank-frame / permission check per spike. Files: Sources/DeskhandPlatform/Capture/**.")
dep "$P_CAPTURE" "$K_FRAME"; dep "$P_CAPTURE" "$K_POLICY"; dep "$P_CAPTURE" "$SP_DECIDE"; dep "$P_CAPTURE" "$G_PCC"
P_INPUT=$(mk "Platform: CGEvent pointer and keyboard poster with frontmost/window lookup" task 0 "$E_PLAT" platform \
  "Move, click, drag, scroll; type text, key, chord; frontmost app (bundle ID + team ID) and topmost window owner under point via CGWindowListCopyWindowInfo; measured window title for results; no event taps. Files: Sources/DeskhandPlatform/Input/**.")
dep "$P_INPUT" "$K_EXEC"; dep "$P_INPUT" "$SP_DECIDE"
P_STATE=$(mk "Platform: state probes for console, lock, display, permissions, secure input, HID idle" task 0 "$E_PLAT" platform \
  "CGSessionCopyCurrentDictionary (kCGSessionOnConsoleKey), lock signal chosen by spike (fail closed), CGDisplayIsAsleep, CGPreflightScreenCaptureAccess, CGPreflightPostEventAccess, AXIsProcessTrustedWithOptions, IsSecureEventInputEnabled, CGEventSource secondsSinceLastEventType(.hidSystemState). Files: Sources/DeskhandPlatform/State/**.")
dep "$P_STATE" "$K_STATE"; dep "$P_STATE" "$SP_DECIDE"
P_MENU=$(mk "Platform: menu bar app with arming, pause and status" task 1 "$E_PLAT" platform \
  "LSUIElement accessory app; MenuBarExtra; arm for chosen duration (disarmed by default); pause; current state and conditions; permission request flows. Files: Sources/DeskhandApp/Menu/**.")
dep "$P_MENU" "$K_STATE"; dep "$P_MENU" "$SCAFFOLD"
P_KILL=$(mk "Platform: global kill-switch hot key and armed/driving indicator" task 1 "$E_PLAT" platform \
  "Carbon RegisterEventHotKey with Control or Command modifier (no event tap); pause aborts in-flight calls and drops lease; visible border or badge whenever armed or driven. Files: Sources/DeskhandApp/KillSwitch/**, Sources/DeskhandApp/Indicator/**.")
dep "$P_KILL" "$P_MENU"; dep "$P_KILL" "$K_EXEC"
P_LOGD=$(mk "Platform: root log daemon with XPC and append-only rotation" task 0 "$E_PLAT" platform \
  "SMAppService.daemon in the same bundle; /Library/Logs/deskhand/actions.log root:wheel 0644; XPC Mach service checking client designated requirement; append only; size rotation with retention; compare with sappnd in the design notes. Files: Sources/DeskhandLogDaemon/**, Sources/DeskhandPlatform/LogClient/**.")
dep "$P_LOGD" "$K_LOG"; dep "$P_LOGD" "$G_MODE"; dep "$P_LOGD" "$SP_DECIDE"
P_APP=$(mk "Platform: app composition and LaunchAgent entry point" task 0 "$E_PLAT" platform \
  "Wire config, server, executor, watchdog, recovery, adapters, menu, kill switch, log client into the accessory app run by the LaunchAgent. Files: Sources/DeskhandApp/Main*, Sources/DeskhandApp/Composition/**.")
dep "$P_APP" "$N_TOOLS"; dep "$P_APP" "$N_ROTATE"; dep "$P_APP" "$P_CAPTURE"; dep "$P_APP" "$P_INPUT"; dep "$P_APP" "$P_STATE"; dep "$P_APP" "$P_KILL"; dep "$P_APP" "$P_LOGD"

# ========================================
# Packaging
# ========================================
B_BUNDLE=$(mk "Packaging: signed app bundle assembly script" task 0 "$E_PKG" packaging \
  "Fixed bundle identifier; one fixed identity from the signing gate; hardened runtime; Info.plist LSUIElement; embedded LaunchAgent plist (Contents/Library/LaunchAgents) and daemon plist; no ad-hoc signing for installable builds. Files: scripts/build-bundle.*, Resources/**.")
dep "$B_BUNDLE" "$SCAFFOLD"; dep "$B_BUNDLE" "$G_SIGN"
B_CI=$(mk "Forgejo CI: bundle build job on native-Mac runner" task 2 "$E_PKG" ci \
  "Build the bundle unsigned or with a CI-only identity on birb-optin-lunus-macbook-pro-macos-arm64; signing identity never exposed to CI without explicit owner approval. Files: .forgejo/workflows/**.")
dep "$B_CI" "$CI_MAC"; dep "$B_CI" "$B_BUNDLE"
B_INSTALL=$(mk "Packaging: install and uninstall commands for agent and daemon" task 0 "$E_PKG" packaging \
  "SMAppService.agent / .daemon register and unregister; verify credential and config file ownership and modes; idempotent install; clean uninstall. Files: Sources/DeskhandApp/Install/**.")
dep "$B_INSTALL" "$B_BUNDLE"; dep "$B_INSTALL" "$P_APP"
B_README=$(mk "Docs: README, security model and manual on-Mac test checklist" task 1 "$E_PKG" docs \
  "Install, permissions, arming, kill switch; app policy is not a sandbox; excluded apps remain visible to input; window-level capture opt-outs not relied on; owner responsible for any added browser; no unlock. docs/manual-checklist.md for TCC-dependent tests. Files: README.md, docs/manual-checklist.md.")
dep "$B_README" "$B_INSTALL"

# ========================================
# Acceptance
# ========================================
A_CLIENT=$(mk "Acceptance: scripted MCP client and pod Job manifest" task 1 "$E_ACC" "acceptance,test" \
  "Small client (mTLS + token, MCP 2026-07-28) for list tools, screenshot, pointer move, type into a text field, and negative cases; Job manifest for namespace forge with label birb.homes/deskhand-egress: \"true\" and a nodeSelector per run. Credentials mounted from secrets, never printed. Files: acceptance/**.")
dep "$A_CLIENT" "$N_MCP"; dep "$A_CLIENT" "$C_DRAFT"
A_MBP=$(mk "Acceptance: manual on-Mac checklist on lunus-macbook-pro" task 0 "$E_ACC" acceptance \
  "Run docs/manual-checklist.md: TCC grants, permission persistence across same-identity upgrade, arming, kill switch, indicator, user_active interruption, lock/asleep/not_console states, log daemon append-only. Record evidence.")
dep "$A_MBP" "$B_README"; dep "$A_MBP" "$G_ACCESS"
A_M1=$(mk "Acceptance: manual on-Mac checklist on m1max2021" task 0 "$E_ACC" acceptance \
  "Same checklist as lunus-macbook-pro, evidence recorded separately.")
dep "$A_M1" "$B_README"; dep "$A_M1" "$G_ACCESS"
A_PODS=$(mk "Acceptance: pods on three node types drive both Macs" task 0 "$E_ACC" acceptance \
  "From pods on infra-control-master, a Raspberry Pi node and the other Mac's guest node: list tools, screenshot, move pointer, type into a text field on each Mac. Wrong cert, wrong token, stale frame, denied app, repeated operation_id each behave as specified; each state returns its error. Own-host guest path may be a documented limitation.")
dep "$A_PODS" "$A_CLIENT"; dep "$A_PODS" "$A_MBP"; dep "$A_PODS" "$A_M1"; dep "$A_PODS" "$G_NET"; dep "$A_PODS" "$G_CERTS"; dep "$A_PODS" "$G_ALLOWANCE"; dep "$A_PODS" "$C_PUBLISH"; dep "$A_PODS" "$SEC_REVIEW"
A_CREW=$(mk "Acceptance: Crew executor smoke test against both Macs" task 1 "$E_ACC" acceptance \
  "Crew's real client acquires a lease, screenshots, and performs one pointer and one keyboard action per Mac with its call ID as operation_id.")
dep "$A_CREW" "$A_PODS"; dep "$A_CREW" "$G_CREW"
A_CLOSE=$(mk "Close out deskhand-r-nkjj with acceptance evidence" task 1 "$E_ACC" acceptance \
  "After acceptance evidence is linked: bn request update deskhand-r-nkjj --status done, with a note summarizing evidence. Linking tasks alone never marks a request fulfilled.")
dep "$A_CLOSE" "$A_PODS"; dep "$A_CLOSE" "$A_CREW"

# ========================================
# Link to requests
# ========================================
bn request link deskhand-r-waw0 "$EPIC" "$E_SPIKE" "$SP_APP" "$SP_MBP" "$SP_M1" "$SP_LOCK" "$SP_NET" "$SP_DECIDE" --no-sync >/dev/null
bn request link deskhand-r-nkjj "$EPIC" "$E_CONTRACT" "$E_CORE" "$E_PLAT" "$E_PKG" "$E_ACC" "$E_GATE" --no-sync >/dev/null

bn sync

echo ""
echo "Bead graph created! View with:"
echo "  bn show $EPIC          # The parent epic and its rollup"
echo "  bn children $EPIC      # Sub-epics; bn children <sub-epic> for tasks"
echo "  bn ready               # Unblocked tasks (epics are not work)"
