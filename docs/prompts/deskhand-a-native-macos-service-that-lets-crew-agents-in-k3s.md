# Project Planning with Beans

## Agent Instructions

You are an expert software architect creating a comprehensive task breakdown. This task graph will be executed by AI agents working in parallel, coordinated through MCP Agent Mail with file reservations to prevent conflicts.

<quality_expectations>
Create a thorough, production-ready task graph. Include all necessary setup, implementation, testing, and documentation tasks. Go beyond the basics - consider edge cases, error handling, security considerations, and integration points. Each task should be specific enough for an agent to execute independently without ambiguity.
</quality_expectations>

## Project Information

### Links to Relevant Documentation
All links below were fetched or confirmed to resolve by research subagents on 2026-11-12. [C] = confirmed from source, [I] = inferred.

**Source requests (Beans hub, read these first)**
- `~/.beans/hub/projects/deskhand/requests/deskhand-r-waw0.md` (spike) and `deskhand-r-nkjj.md` (v0). Open, p1, requested by crew.
- `~/.beans/hub/projects/birbhomes/requests/birbhomes-r-5elb.md` (network path: selectorless Service + EndpointSlice per Mac in namespace `forge`, `deskhand-<mac>`; private CA from `scripts/forge-production.py`; server SANs `deskhand-<mac>.forge.svc` and `deskhand-<mac>.forge.svc.cluster.local`; one shared client cert; one token per Mac; 90-day leaves; pf anchor admitting node IPs only).
- `~/.beans/hub/projects/birbhomes/requests/birbhomes-r-ttg5.md` (Mac host prep: LAN gate publishes a root-owned, short-expiry "deskhand allowance" file that deskhand must check; Mode A dedicated console account vs Mode B owner session; birbhomes supplies per-Mac config).
- `~/.beans/hub/projects/crew/requests/crew-r-yqso.md` (Crew executor holds credentials, sends its call ID as `operation_id`, renews the lease).
- `~/.beans/hub/projects/forge/requests/forge-r-gr36.md` (approval cards; the reason for the app-policy denylist).
- The "Shared contract" block is byte-identical in deskhand-r-nkjj, birbhomes-r-5elb and crew-r-yqso [C].

**Related repos**
- https://github.com/mattsp1290/crew (`docs/in-cluster-executor.md`, `docs/standing-grants.md`, `docs/member-gateway.md`)
- https://github.com/mattsp1290/forge
- https://github.com/mattsp1290/birbhomes (private; local `~/git/birbhomes`): `.agents/skills/k3s-worker-onboard/references/forgejo.md` (runner labels and rules), `.agents/skills/k3s-worker-onboard/references/macos.md`, `.agents/skills/k3s-worker-onboard/scripts/lan-worker-gate.py`, `docs/operations.md` (Mac runner checkpoint 2026-10-18), `deploy/forgejo/backend.yaml`.

**MCP (target revision 2026-07-28)**
- https://modelcontextprotocol.io/specification/2026-07-28/changelog: no sessions, no `initialize`, mandatory `server/discover`, no resumability, `resultType` required [C].
- https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http: Origin MUST be validated (403), `MCP-Protocol-Version`/`Mcp-Method`/`Mcp-Name` headers MUST match body (400, -32020), closing the stream cancels the request [C].
- https://modelcontextprotocol.io/specification/2026-07-28/server/tools: image content, `structuredContent` + `outputSchema`, `isError` tool results vs JSON-RPC errors, server-minted handles [C].
- https://modelcontextprotocol.io/specification/2026-07-28/schema: annotation defaults, error codes -32020/-32022 [C].
- https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning and https://modelcontextprotocol.io/specification/2026-07-28/server/discover
- https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization: authorization is OPTIONAL; static bearer + mTLS is compatible but not "MCP authorization" [C].
- https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices: handles are not authentication; bind them to the caller [C].
- https://github.com/modelcontextprotocol/swift-sdk (0.12.1, implements 2025-11-25 only) [C]; open PR https://github.com/modelcontextprotocol/swift-sdk/pull/314 (2026-07-28 profile); open bugs https://github.com/modelcontextprotocol/swift-sdk/issues/265 and #254 (stateless transport cross-request leakage/hang on shared JSON-RPC ids) [C].

**Computer-use prior art**
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool: current models accept up to 2576 px long edge / ~3.75 MP; oversized images are rejected, not downscaled; coordinate scaling guidance [C].
- https://developers.openai.com/api/docs/guides/tools-computer-use
- https://github.com/openclaw/Peekaboo (`docs/permissions.md`): re-signing resets TCC; a separate "Event Synthesizing" grant for posted input; LaunchAgent captures can silently return wallpaper only [C].
- https://github.com/trycua/cua, https://github.com/mediar-ai/mcp-server-macos-use

**Apple: screen capture**
- https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager and https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration
- https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingapplications:exceptingwindows:)
- https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture (Apple-approved entitlement; only known route around the recurring prompt, undocumented whether it removes it) [C/I]
- https://developer.apple.com/forums/thread/761641, https://developer.apple.com/forums/thread/841530 ("Remote Desktop" privacy setting, no API to query) [C], https://developer.apple.com/forums/thread/839069
- https://developer.apple.com/videos/play/wwdc2023/10136/

**Apple: input, permissions, state**
- https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:), https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess(), https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()
- https://developer.apple.com/forums/thread/724603 and https://developer.apple.com/forums/thread/720840 (DTS: posting needs user approval + stable signing; preflight can stay stale until relaunch) [C]
- https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
- https://developer.apple.com/library/archive/technotes/tn2150/_index.html (secure input blocks interception, not posting) [C]
- https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:), https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid
- https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary(), https://developer.apple.com/documentation/coregraphics/kcgsessiononconsolekey, https://developer.apple.com/documentation/coregraphics/cgdisplayisasleep(_:)
- https://developer.apple.com/forums/thread/850327 (no supported lock-detection API; only protected-data notifications) [C]
- https://developer.apple.com/documentation/iokit/1557127-iopmassertiondeclareuseractivity
- https://developer.apple.com/documentation/coregraphics/cgdisplaybounds(_:), https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor

**Apple: signing, install, network**
- https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements (TCC keys on designated requirement; dev and Developer ID builds do not share grants) [C]
- https://developer.apple.com/forums/thread/721745, https://developer.apple.com/documentation/security/hardened-runtime, https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:), https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement, https://developer.apple.com/documentation/swiftui/menubarextra
- https://developer.apple.com/forums/thread/763878 (`RegisterEventHotKey` modifier rules since 15.0) [C]
- https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy (accepting inbound TCP does not need local network access; agents need `AssociatedBundleIdentifiers` if not installed via SMAppService) [C]
- https://developer.apple.com/forums/thread/773777 and https://developer.apple.com/documentation/security/ksecimporttomemoryonly (Network.framework identity without Keychain only via PKCS#12 + macOS 15) [C]

**TLS, Kubernetes, Lima**
- https://github.com/apple/swift-nio-ssl (`TLSConfiguration.swift`: server default `certificateVerification = .none`, set `.fullVerification` and `trustRoots` to the private CA; `NIOSSLServerHandler` custom verification callback) [C]
- https://kubernetes.io/docs/concepts/services-networking/service/ and https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- https://kubernetes.io/docs/concepts/services-networking/network-policies/ (ipBlock after Service rewrite is undefined) [C]
- https://docs.k3s.io/networking/basic-network-options, https://github.com/k3s-io/k3s/blob/main/pkg/agent/flannel/flannel.go (IPv4 masquerade always on) [C]
- https://lima-vm.io/docs/config/network/vmnet/ (bridged mode; guest-to-own-host reachability undocumented) [C]

**CI**
- https://forgejo.org/docs/v15.0/admin/actions/registration/ and https://forgejo.org/docs/v15.0/admin/actions/security/

### Project Description
deskhand: a native macOS service that lets Crew agents in k3s pods screenshot and control a Mac desktop over MCP. Fulfill bn requests **deskhand-r-waw0** (spike: verify macOS permission, capture, input and network behavior on both Macs, `lunus-macbook-pro` 10.0.0.149 and `m1max2021` 10.0.0.96) and **deskhand-r-nkjj** (build v0 to the shared contract: mTLS + per-Mac bearer token, tools `status`/`displays`/`screenshot`/`pointer`/`keyboard`, frame-bound effects, leases, idempotent `operation_id`, the nine-value state table, arming, per-Mac app policy, yield-to-user, kill switch and indicator, append-only action log, stable signing, LaunchAgent install/uninstall). The spike blocks every v0 task whose design depends on a spike answer. The full request texts are the source of truth for behavior; this plan adds the decisions below.

**Deliverables**
1. Spike: a throwaway signed app bundle and a results document `docs/spike-results.md` answering all ten spike items per Mac, with a recommendation for each open v0 decision. The spike also tests the new risks found in research (see Specific Requirements, "Spike additions").
2. A versioned contract document `docs/contract.md` (tool list with input/output schemas, error-code table, state table, MCP protocol version, auth, limits) that Crew builds against. Publishing it is an early milestone, so Crew can start in parallel.
3. deskhand v0: the signed accessory app, its LaunchAgent, install/uninstall commands, README, and acceptance evidence from pods on `infra-control-master`, a Raspberry Pi node and the other Mac's guest node.
4. On completion, link the created Beans issues to both requests (`bn request link`) and update request status.

**Out of scope for v0** (from the request): accessibility tree, clipboard, file transfer, shell commands, audio, video recording, more than one controller. Network path, cert issuance, pf anchor, LAN gate allowance publisher and Crew/Forge client work belong to the sibling requests; deskhand only consumes their outputs.

### Technical Stack
Chosen from research; items marked "spike decides" are provisional until `docs/spike-results.md` lands.

- **Language:** Swift 6 (strict concurrency). Confirmed by the user.
- **Packaging:** SwiftPM package for all libraries and tests; the signed `.app` bundle (accessory app, `LSUIElement`, `MenuBarExtra`/`NSStatusItem`) is assembled by a repo script or minimal Xcode project driven by `xcodebuild`, with a fixed bundle identifier and one fixed signing identity (Developer ID Application vs Apple Development: spike decides, but every installed build uses the same one; dev and Developer ID builds do not share TCC grants per TN3127). Hardened runtime on. No ad-hoc signing for installed builds.
- **Minimum macOS:** 15 (Sequoia), provisional. Driven by SCScreenshotManager (14+) and `kSecImportToMemoryOnly` (15+) as a fallback TLS path. The spike records the exact versions on both Macs (likely 26 or 27) and may raise the floor, e.g. to adopt `SCScreenshotConfiguration` (26+).
- **Capture:** ScreenCaptureKit (`SCShareableContent`, `SCContentFilter(display:excludingApplications:exceptingWindows:)`, `SCScreenshotManager`). Region captures must go through a filter plus source rect, never a bare-rect API, so exclusions apply.
- **Input:** `CGEvent` posting (`CGEvent.post(tap:)`), `CGPreflightPostEventAccess`/`CGRequestPostEventAccess`, `AXIsProcessTrustedWithOptions`. No event taps. `IsSecureEventInputEnabled()` for `secure_input`. `CGEventSource.secondsSinceLastEventType` for `user_active` (spike verifies deskhand's own posts do not reset it).
- **State detection:** `CGSessionCopyCurrentDictionary` (`kCGSessionOnConsoleKey`), `CGDisplayIsAsleep`, protected-data notifications for lock (no supported lock API; spike picks the signal), `CGPreflightScreenCaptureAccess`.
- **Kill-switch hot key:** Carbon `RegisterEventHotKey` with a Control or Command modifier (no event tap).
- **Install:** `SMAppService.agent(plistName:)` with the plist in `Contents/Library/LaunchAgents`, or a launchd plist with `AssociatedBundleIdentifiers` (TN3179). Install and uninstall commands in the app or a companion CLI.
- **HTTP + TLS server:** SwiftNIO + SwiftNIO-SSL (`NIOSSLServerHandler`, `certificateVerification: .fullVerification`, `trustRoots` set to the private CA only, PEM key and cert loaded from owner-only files). Chosen over Network.framework because NWListener needs a Keychain identity (only PKCS#12 + `kSecImportToMemoryOnly` on macOS 15 avoids it). Must support reloading the leaf cert after birbhomes' 90-day rotation without dropping the lease.
- **MCP:** target protocol revision **2026-07-28** (sessionless streamable HTTP, `server/discover`, header/body match checks). The official swift-sdk (0.12.1) only implements 2025-11-25 and its stateless HTTP transport has open cross-request bugs (#254, #265). Default: write a small sessionless JSON-RPC handler for `server/discover`, `tools/list`, `tools/call` directly on SwiftNIO, reusing swift-sdk value types only where they match 2026-07-28. Revisit when swift-sdk PR #314 lands. Crew's client must speak the same revision; record it in `docs/contract.md`.
- **Tests:** Swift Testing (`import Testing`) for unit tests; pure-logic modules (contract types, coordinate mapping, frame staleness, lease, idempotency store, state machine, app policy, rate limiter, request validation, log formatting) kept free of AppKit/ScreenCaptureKit so they also build and test on Linux. Platform adapters behind protocols with fakes. A scripted MCP client (e.g. Python or Swift) for end-to-end acceptance from pods.
- **Lint/format:** swift-format (Apple), plus markdownlint and JSON Schema validation for the contract document.
- **Credentials tooling (consumed, not owned):** the openssl-based private CA in birbhomes `scripts/forge-production.py`.
- **CI:** Linux GitHub Actions for platform-independent work; Forgejo native-Mac runner for anything that needs macOS (see Specific Requirements).

### Specific Requirements
All "Required behaviour" and "Acceptance" items of deskhand-r-nkjj apply verbatim. Additions and deliberate changes:

**CI**
- No GitHub-hosted macOS runners, ever.
- GitHub Actions on Linux (`ubuntu-*`) where appropriate: swift-format lint, `swift build`/`swift test` of the platform-independent modules on Linux, contract-document schema validation, markdownlint, link check.
- Everything needing macOS (app bundle build, signing, ScreenCaptureKit/CGEvent adapters, integration tests) runs on the self-hosted Forgejo runner via `.forgejo/workflows/`, `runs-on: birb-optin-lunus-macbook-pro-macos-arm64` (native host runner on `lunus-macbook-pro`; Linux guest runner is `birb-optin-lunus-macbook-pro-linux-arm64`). Rules from birbhomes `references/forgejo.md`: exact labels only, no generic labels, pin actions by commit, no credentials in argv/logs/artifacts, jobs run only while the Mac is on the LAN, Forgejo is reached over NetBird at `git.birb.homes`. The repo needs a Forgejo mirror with Actions enabled (Ferry). `m1max2021` has no registered runner; do not plan CI there.
- Signing identities must never be exposed to CI jobs unless explicitly approved; CI may build unsigned or with a CI-only identity, and installed builds are signed on the owner's machine with the fixed identity.
- Tests that need TCC grants, a GUI session or a real display are tagged and excluded from CI; they run as a documented manual on-Mac checklist.

**Model assumption (change from the request)**
- Callers use current models only (released within the past 6-12 months). `screenshot` default downscale targets the current computer-use limits: long edge ≤ 2576 px and ≤ ~3.75 MP, not 1568 px. Caller may request smaller. deskhand never returns an image exceeding either limit (the API rejects, it does not downscale). Record this change in `docs/contract.md` so crew-r-yqso matches.

**Contract decisions research forced**
- **Contract change control.** The request text is authoritative. Each deviation in this plan is a numbered amendment, recorded in a "Changes from the shared contract" section of `docs/contract.md`. The three deviations are the screenshot limits, the new `gated` state, and having no node allowlist inside deskhand. deskhand, crew, birbhomes and forge share one owner. An amendment is approved when the owner leaves a note on every affected request (deskhand-r-nkjj, crew-r-yqso, birbhomes-r-5elb, birbhomes-r-ttg5). The screenshot-limit amendment was approved by the owner on 2026-11-12. Until an amendment is approved, deskhand follows the request text. Publishing `docs/contract.md` v1.0 is a Beans task blocked on approval of every amendment.
- MCP revision 2026-07-28. Tool-level refusals (`stale_frame`, `user_active`, `disarmed`, each state name, `denied_app`, `rate_limited`, `lease_*`) are `isError: true` tool results with `structuredContent` carrying the code; JSON-RPC errors are reserved for protocol, header and version faults and unknown tools. Set tool annotations explicitly even though Crew ignores them.
- Bind `frame_id`, `operation_id` and lease holder to the authenticated caller (client cert + token), per MCP handle-hijacking guidance. Note all callers share one client cert (birbhomes-r-5elb), so the lease holder ID is the per-caller discriminator.
- Listener: reject any `Origin` header (403) and any `Host` not in the configured Service DNS names (exact names: `deskhand-<mac>.forge.svc`, `deskhand-<mac>.forge.svc.cluster.local`, plus port). Bind the configured LAN address, not loopback and not all interfaces; record this as a justified deviation from the spec's "SHOULD bind localhost when running locally". 401 on bad token.
- Request size limits and response size limits account for ~33% base64 overhead on images.
- Closing the HTTP response stream cancels the in-flight call (spec), which must also abort any partially posted input sequence safely.
- Refuse all tools except `status` when the birbhomes LAN-gate "deskhand allowance" file is missing or expired (birbhomes-r-ttg5); expose this as a state (name it in the contract; propose `gated`) and add it to the shared contract via a note on the sibling requests.
- Reload TLS leaf cert and token from disk on change or SIGHUP (90-day rotation).
- Do not implement a second node-IP allowlist inside deskhand unless the owner decides otherwise; the pf anchor owns source filtering and the credential is the access control (flag the conflict with birbhomes-r-ttg5).

**Spike additions (beyond the ten items in deskhand-r-waw0)**
- Whether a separate "Event Synthesizing" / "Device Control and Data Access" grant exists for posting input on the installed macOS version.
- Whether the "Remote Desktop" privacy setting exists alongside Screen Recording, and how to detect it.
- Whether a LaunchAgent capture silently returns wallpaper or a redacted image; design a blank-frame detector that reports `permission_stale`.
- Whether the Persistent Content Capture entitlement is obtainable and suppresses the recurring prompt; otherwise define how deskhand reports the pending prompt.
- Which lock-detection signal is reliable.
- Whether deskhand's own posted events reset `secondsSinceLastEventType` for `.hidSystemState`.
- Whether posted modifier chords reach apps with global hot keys under deskhand's real signing.
- Run all permission-persistence tests with the exact identity used for installed builds.

**Safety and privacy (restated, non-negotiable)**
- Disarmed by default; arming only from the menu bar for a chosen duration.
- Default app policy denies Terminal and shells, System Settings, Keychain Access, password managers, mail and messaging apps, and any browser or app signed in to Forge. README states excluded apps remain visible to input.
- No unlock, no login-window input, no event tap, no Keychain.
- Action log append-only and not editable by the session user; typed text logged as length only; no image bytes. Credentials and tokens never in logs, errors, test fixtures or CI output.

**Settled by plan review (round 1)**

- **Caller identity.** Crew's executor is the only principal (crew-r-yqso: member processes never hold the credentials). deskhand authenticates that principal per Mac by requiring both a client certificate issued by the private CA and a valid bearer token. The principal's identity is the certificate subject. It cannot tell Crew's internal callers apart, and the contract says so. Separating them is Crew's job. The lease holder ID is a label that Crew assigns. It is not authentication. Every handle (`frame_id`, `operation_id`, lease) is scoped to (principal, lease holder ID). Effect calls must name the current lease holder ID, or they are refused with `lease_not_held`.
- **Action log boundary.**
  - **Writer.** The default design is a small root LaunchDaemon in the same bundle, registered with `SMAppService.daemon`. It owns `/Library/Logs/deskhand/actions.log` (root:wheel, 0644) and accepts entries over an XPC Mach service. It checks that each client's code signature matches deskhand's designated requirement, and it only appends.
  - **Rotation.** Rotate by size, keep a configured number of files, and never edit an entry once written.
  - **Fail closed.** deskhand logs the intent before it posts an effect, and logs the outcome after. If the intent entry cannot be committed, the effect is refused with `log_unavailable`.
  - **Install.** Installing needs admin rights once, at install time.
  - **Fallback.** A design task compares this with a file marked system append-only (`sappnd`) by root. Mode A (a dedicated console account) does not remove the need for the root writer.
- **App-policy boundary.**
  - **Scope.** The policy guards against an agent reaching sensitive apps. It is not a sandbox, and the README says so.
  - **Allowlist.** Policy is deny-by-default. Apps launched during an armed session are denied unless they are allowlisted.
  - **App identity.** An app is identified by its bundle ID plus its code-signing team ID.
  - **Checks before every event.** Check the frontmost app immediately before each posted event, not once per call. If it changed during a sequence, abort the rest of the sequence with `denied_app` and release any held input.
  - **Pointer events.** The owning app of the topmost window under the target point (`CGWindowListCopyWindowInfo`) must also be allowlisted.
  - **Global shortcuts.** A configured set of global shortcuts (Cmd-Space, Cmd-Tab, Cmd-Option-Esc, Ctrl-arrow Spaces switching, screenshot shortcuts, and others) is denied by default.
  - **Browsers.** deskhand cannot detect whether a browser is signed in to Forge. So the default allowlist contains no browser, and the README makes the owner responsible for any browser they add.
  - **Uncertainty.** If any check is uncertain, refuse.
- **State precedence and transitions.**
  - **Precedence.** States are one pure reducer with a table in `docs/contract.md`. In precedence order: `gated` > `paused` > `disarmed` > `not_console` > `locked` > `display_asleep` > `permission_missing` > `permission_stale` > `secure_input` > `ok`.
  - **What `status` reports.** `status` returns the state with the highest precedence plus every active condition.
  - **Leaving `ok`.** Any change away from `ok` cancels the effect in flight, releases held keys and buttons, and invalidates every frame.
  - **Dropping the lease.** `gated`, `paused` and `disarmed` also drop the lease.
  - **Arming again.** `paused` (the kill switch) leaves deskhand disarmed, so someone at the Mac must arm it again.
  - **`user_active`.** This is not a state. It refuses a call before execution starts, and it aborts a call during execution.
  - **Tests.** The reducer has exhaustive table-driven tests.
- **Operation outcome model.**
  - **Lifecycle.** Each `operation_id` moves from `accepted` to `executing`, then to `completed`, `aborted` or `failed`. The record stores how many events were posted.
  - **Repeats and duplicates.** A repeat of a finished ID returns the stored result and never posts again. A duplicate that arrives while the operation is still executing gets `operation_in_progress`.
  - **Aborts.** An abort can come from a disconnect, the kill switch, a state change or a change of frontmost app. On abort, deskhand releases every key and button it pressed, then records `aborted` with the count of events posted. Input that was already posted cannot be undone, and the contract says so.
  - **Persistence and retention.** Records are persisted to an owner-only file and kept for a configured window. The default is 24 h and 10,000 IDs per principal. Crew must not retry after that window.
  - **Payload binding.** Each record stores a SHA-256 of the canonical request: the tool name plus its arguments in canonical JSON, without transport metadata. A repeated `operation_id` with a different digest returns `operation_id_conflict`.
  - **Capacity.** Records still inside the retention window are never evicted. When a principal already has 10,000 such records, new IDs are refused with `operation_capacity`.
  - **Write ordering.** The record is written durably (fsync) as `executing` before the first event is posted. Its final state is written durably after.
  - **Restart.** On startup, deskhand marks `accepted` records `failed_before_execution`, because nothing was posted for them. It marks `executing` records `aborted_by_restart`. It invalidates all frames and drops the lease.
  - **Held-input ledger.** A durable ledger records every key and button that might be down.
    - Before posting a down event, write a "possibly held" entry and fsync it.
    - After posting the matching up event, clear the entry and fsync.
    - A crash in either window leaves the entry in place, so recovery always releases conservatively. An extra key-up does no harm.
    - Restart cleanup runs from the ledger, not from event counts. A crash during cleanup leaves the remaining entries for the next start.
    - Fault-injection tests crash the process at each boundary: before the ledger write, between the write and the post, after the post, and during cleanup.
  - **Restart cleanup.** deskhand posts only the key-up and button-up events that match the ledger entries.
  - **Cleanup authorization.** Every release, both restart cleanup and ordinary abort cleanup, requires every blocking condition to be absent, not just the state `status` reports. The blocking conditions are: locked, not on the console, at the login window, and `secure_input`. Releases are allowed while gated, paused or disarmed, because releasing removes input rather than adding it.
    - If an abort is caused by locking, a console switch or secure input, the releases are deferred, not posted.
    - Until cleanup can run, deskhand logs `cleanup_pending` and refuses every effect.
    - The spike checks whether synthetic input that is still held survives the exit of the process that posted it.
- **Input executor.**
  - **One at a time.** Each Mac has one serial executor. At most one effect executes at a time.
  - **Busy, not queued.** An effect call that arrives while another is executing is refused immediately with `busy`. There is no queue, so the frame, the lease and policy are always checked against the current state when execution starts.
  - **Releasing input.** Each operation tracks the keys and buttons it pressed. On abort, it releases only those.
  - **Between events.** Before every posted event, the executor checks the state and the deadlines.
  - **The person at the Mac.** The executor also watches for physical user activity during an operation, including while it waits with input held. It polls the hardware (HID) event source every 100 ms, ignoring deskhand's own posted events per the spike's result. If the person used the keyboard or pointer, it aborts the operation with `user_active` and releases that operation's input within 250 ms.
    - Tests cover a person intervening during typing, during a drag, and during a modifier chord.
- **Deadlines during execution.**
  - **The deadline.** The executor's deadline is the earliest of the allowance's `expires_at`, the lease expiry and the arming expiry.
  - **When it is checked.** Before every posted event, and by a timer while the executor is idle.
  - **Revocation.** If the allowance file is removed or replaced, deskhand notices within 1 s, through a file watch plus a 1 s poll.
  - **On expiry or revocation.** Within the 1 s bound, cancel the running operation, release its held input and drop the lease. `docs/contract.md` states this bound.
- **Allowance file contract** (the deskhand side; birbhomes-r-ttg5 owns publishing it).
  - **Path.** The path comes from config.
  - **File checks.** Open with `O_NOFOLLOW`. The file must be a regular file owned by root, not writable by group or world, in a root-owned directory.
  - **Contents.** JSON `{version, mac, not_before, expires_at}`, with UTC RFC 3339 timestamps. `mac` must match this Mac. Clock skew tolerance is configured.
  - **When it is read.** On every call, cached for at most 1 s.
  - **Failure.** A missing, invalid or expired file means `gated`. Becoming gated aborts any operation in flight and drops the lease.
  - **Coordination.** A Beans task proposes this format on birbhomes-r-ttg5. birbhomes guarantees atomic publishing by rename.
  - **Node-IP allowlist.** deskhand has no node-IP allowlist of its own. This is listed as an owner decision.
- **Spike outcomes.**
  - **Recording.** Each spike item records pass, fail or inconclusive per Mac, with evidence.
  - **Lock detection.** The chosen signal must be correct in 20 of 20 trials on each lock path: menu, hot corner, lid, idle timeout and fast user switching. It must never report unlocked by mistake. If no signal meets that bar, deskhand fails closed and reports `locked` whenever detection is uncertain.
  - **Blank frames.** Blank-frame detection must not rely on judging image content alone. Combine the preflight APIs with a non-empty `SCShareableContent` window list. If that is unreliable, report `permission_stale` and document the gap.
  - **Go/no-go.** The spike ends with a go/no-go decision task. If capture or input is impossible on a Mac in a required state, the decision escalates to the owner, and the v0 tasks that depend on it stay blocked.
- **Screenshot sizing and coordinates.**
  - **Size limits.** Contract constants: `max_long_edge` 2576 and `max_pixels` 3,750,000. The contract task confirms both against the computer-use docs before v1.0.
  - **Scaling.** `scale = min(1, max_long_edge / long_edge, sqrt(max_pixels / (w*h)))`. Output size is the floor of each dimension times the scale, with a minimum of 1.
  - **Caller requests.** A caller may ask for a smaller `max_long_edge` (at least 256). Larger values return `invalid_argument`.
  - **Format.** JPEG at quality 85 by default; PNG on request. If the encoded image is over 5 MB, lower the JPEG quality in steps down to 60, then return `image_too_large`.
  - **What a frame records.** One display per frame. Each frame records the display ID, the capture rectangle in global points (the origin may be negative), the source and output pixel sizes, `pointPixelScale`, and the display configuration generation.
  - **Mapping a pointer target.** For pointer target `(x, y)` in the frame's output pixels, the global point is `rect.origin + (x + 0.5) * rect.size / output_size`. Targets outside the output size return `out_of_frame`.
- **Credential rotation.**
  - **Watching files.** Watch the credential files and also reload on SIGHUP.
  - **New certificate and key.** Validate the new pair before swapping it in: the key must match the certificate, the certificate must chain to the CA and be in date, and its SANs must include the configured names. New connections get the new pair, and existing connections run until they close. Keep-alive connections are capped at 5 minutes.
  - **Invalid replacements.** If the new files are invalid, keep the old pair, log it, and report a `credentials_warning` condition in `status`.
  - **Tokens.** Tokens are checked on every request. An overlap window for current and previous tokens is configurable, and the default is 0, which means revocation takes effect immediately.
  - **The lease across rotations.** The principal is the per-Mac Crew executor, identified by its client certificate subject. The bearer token is a credential that must be valid on every request; it is not part of the principal's identity. Replacing the token, or rotating the certificate with the same subject, keeps the lease and the stored operation results. A revoked token still fails immediately.
- **External gates.** Create one Beans task labeled `gate` for each external dependency. Each names its owner and closes only with evidence: a closed sibling issue or an owner note.
  - Owner decisions:
    - console mode (Mode A or Mode B)
    - signing identity and Apple team
    - whether to apply for the Persistent Content Capture entitlement
    - whether deskhand gets a node-IP allowlist
    - approval of the contract amendments
  - birbhomes deliverables:
    - Service and EndpointSlice
    - CA, certificates and tokens
    - pf anchor
    - allowance publisher
    - per-Mac config
  - Crew's client speaking MCP 2026-07-28.
  - A Forgejo mirror with Actions enabled.
  - Physical access to both Macs for manual tests.

  **Gate dependencies.** A task depends on every gate or spike decision whose outcome changes its behavior or interface. Examples:
  - the lock-state adapter depends on the spike's lock-detection result
  - capture adapters depend on the spike's capture-reliability result
  - signing and packaging tasks depend on the signing-identity gate
  - the log-daemon install depends on the console-mode gate
  - publishing `docs/contract.md` v1.0 depends on every amendment-approval gate

  Only work this plan has already settled proceeds against fakes without gate dependencies. That work is the pure reducers, contract types, coordinate math, the idempotency store, the TLS listener and the MCP handler. Integration and acceptance tasks depend on every relevant gate.
- **Task-graph script rules.** These override the generic template where they conflict.
  - **No initialization.** The hub is already set up, so the script never runs `bn init`.
  - **Allowed commands.** `bn create`; `bn dep add` between task beans; `bn update` only to set epics `in_progress`; and `bn request link` to link the epic and its tasks to deskhand-r-waw0 and deskhand-r-nkjj.
  - **Epics.** One top-level epic, with optional phase sub-epics parented to it: Spike, Contract, v0 core, Platform adapters, Packaging and CI, Acceptance.
  - **Re-running.** The script first checks `bn list --json` for an open issue titled "Epic: deskhand" and exits non-zero if one exists, so a rerun cannot create duplicates.
  - **Running it.** The agent writes the script to `docs/prompts/setup-beans.sh`, runs it once, then verifies with `bn children` and `bn ready`, not `bn dep tree`.
- **Review and close rules.**
  - **Implementation tasks** close only with: a commit or PR link; the commands run and their results; and two independent reviews with their findings resolved.
  - **Gate tasks** close on evidence alone: a link to the closed sibling issue or request, or the owner's decision quoted with its date. They need no commit or review.
  - **Spike measurement tasks** close when their evidence is recorded in `docs/spike-results.md`, after one review.
  - **Linking is not completion.** Linking tasks to requests does not mark the requests fulfilled.
  - **deskhand-r-waw0** is marked done with `bn request update --status` only after `docs/spike-results.md` is merged and the go/no-go decision is recorded.
  - **deskhand-r-nkjj** is marked done only after the acceptance task closes, with evidence from all three pod locations against both Macs.

**Owner decisions to surface (do not guess)**
- Mode A (dedicated console account) vs Mode B (owner's session) from birbhomes-r-ttg5.
- Signing identity type and Apple developer team.
- Whether to apply for the Persistent Content Capture entitlement.

**Process**
- Each Beans task under 750 changed lines, verified before close, reviewed per the dual-review workflow; add generated test binaries to `.gitignore` and never commit them.

---

## Your Task

Analyze this project and create a comprehensive **Beans task graph** using the `bn` CLI. Beans provides dependency-aware, conflict-free task management for multi-agent execution.

---

<critical_constraint>
Your ONLY output is a bash shell script containing `bn create` and `bn dep add` commands. Do NOT use `bn add` — the correct command to create a bead is `bn create`. Use `bn dep add` for dependencies between task beans. Do not implement anything yourself.

The script MUST create a single parent **epic** first (`bn create -t epic`) and parent **every** task bead to it via `--parent "$EPIC"`, so the whole project is one trackable rollup. The epic is an organizational rollup only — never make it a blocking dependency (do NOT `bn dep add` to or from the epic; `bn dep add` is for real ordering edges between task beans, and a blocking edge on an epic both excludes it wrongly and inverts `bn dep tree`). Membership is the `--parent` relationship, nothing else.
</critical_constraint>

## Output Format

Generate a shell script that creates the full task graph. The script should:

1. **Initialize Beans** (if not already initialized)
2. **Create one parent epic** (`bn create -t epic`) representing the whole project, capturing its ID into `$EPIC`
3. **Create all task beans** with appropriate priorities, each parented to the epic via `--parent "$EPIC"`
4. **Establish dependencies** between task beans (ordering edges only — never to or from the epic)

### Example Output

```bash
#!/bin/bash
# Project: deskhand
# Generated: 2026-11-12

set -e

echo "Creating project beans..."

# ========================================
# Parent epic — every task below is parented to it (--parent "$EPIC").
# The epic is an organizational rollup: it is NEVER given a blocking dep
# (no `bn dep add` to or from it) and is never dispatched as work itself.
# ========================================

EPIC=$(bn create "Epic: deskhand" -t epic -p 0 --silent)
bn update "$EPIC" --status in_progress   # rollup, not dispatchable work — keep it out of `bn ready`

# ========================================
# Phase 1: Project Setup & Infrastructure
# ========================================

SETUP_VITE=$(bn create "Initialize project with Vite + React + TypeScript" -p 0 --parent "$EPIC" --silent)

SETUP_LINT=$(bn create "Configure ESLint, Prettier, and TypeScript strict mode" -p 1 --parent "$EPIC" --silent)
bn dep add $SETUP_LINT $SETUP_VITE

SETUP_TAILWIND=$(bn create "Set up Tailwind CSS with design system tokens" -p 1 --parent "$EPIC" --silent)
bn dep add $SETUP_TAILWIND $SETUP_VITE

SETUP_TESTING=$(bn create "Configure testing framework (Vitest + Testing Library)" -p 1 --parent "$EPIC" --silent)
bn dep add $SETUP_TESTING $SETUP_LINT

# ========================================
# Phase 2: Core Architecture
# ========================================

API_CLIENT=$(bn create "Implement API client with error handling and retries" -p 0 --parent "$EPIC" --silent)
bn dep add $API_CLIENT $SETUP_VITE

STATE_MGMT=$(bn create "Set up global state management (Zustand/Jotai)" -p 0 --parent "$EPIC" --silent)
bn dep add $STATE_MGMT $SETUP_VITE

AUTH_CONTEXT=$(bn create "Create authentication context and hooks" -p 0 --parent "$EPIC" --silent)
bn dep add $AUTH_CONTEXT $STATE_MGMT
bn dep add $AUTH_CONTEXT $API_CLIENT

# ... continue for all phases ...

echo ""
echo "Bead graph created! View with:"
echo "  bn show $EPIC          # The parent epic and its rollup"
echo "  bn children $EPIC      # All task beans under the epic"
echo "  bn ready              # List unblocked tasks (the epic itself is not work)"
```

---

## Bead Creation Guidelines

### Epic / Hierarchy (REQUIRED)
- Create exactly **one parent epic** for the whole project: `EPIC=$(bn create "Epic: <project summary>" -t epic -p 0 --silent)`.
- Parent **every** task bead to it: add `--parent "$EPIC"` to every `bn create`.
- The epic is a **rollup, not work**: never `bn dep add` to or from it. Membership is `--parent`; `bn dep add` is reserved for real ordering edges *between task beans*. A blocking edge on an epic wrongly keeps it out of (or drops it into) `bn ready` and inverts `bn dep tree`.
- **Keep the epic out of `bn ready`** by marking it active right after creation: `bn update "$EPIC" --status in_progress`. `bn ready` excludes `in_progress`/`blocked`/`deferred`/`hooked`. Do **not** rely on `--exclude-type epic` — that flag is ineffective on some `bn`/`bn` builds, whereas status-based exclusion works everywhere.
- For very large projects you MAY use phase sub-epics (each `--parent "$EPIC"`, each with its own children), but a single top-level epic is the default and is sufficient for most projects.

### Priority Levels
- `-p 0` = Critical (blocking other work)
- `-p 1` = High (important but not blocking)
- `-p 2` = Medium (standard work)
- `-p 3` = Low (nice to have)

### Dependency Rules
1. Never create cycles
2. Every bead should have a clear dependency chain back to setup tasks
3. Use `bn dep add CHILD PARENT` (child depends on parent completing first)
4. Parallel work should share a common ancestor, not depend on each other
5. `bn dep add` is for ordering edges **between task beans only** — never use it to attach a task to the epic (that is `--parent`), and never add a blocking edge to or from the epic

### Task Granularity
- Each bead should be completable in **under 750 lines of code**
- Tasks should be atomic enough for one agent to complete without coordination
- If a task requires multiple file areas, consider splitting by file area

---

## File Reservation Planning

For each major work area, note the file patterns that will need exclusive reservation:

```bash
# Example reservation notes (add as bead descriptions)
# Auth work: src/auth/**, tests/auth/**, src/hooks/useAuth*
# API client: src/api/**, src/lib/fetch*, tests/api/**
# UI components: src/components/{ComponentName}/**, tests/components/{ComponentName}/**
```

This helps agents claim appropriate file surfaces when they start work.

---

## Context Documentation

Place any important context in `prompts/docs/` for agents to reference. This includes:
- Architecture decisions
- API documentation
- Design system specs
- External service integration guides

---

## Verification Steps

After generating the script:

1. **Run it**: `chmod +x setup-beans.sh && ./setup-beans.sh`
2. **Check the rollup**: `bn children "$EPIC"` should list every task bead, and `bn dep tree` should show them under the epic with no orphan (un-parented) tasks
3. **Check ready work**: `bn ready` should show initial setup tasks and **not** the epic. Epics are rollups, never dispatched as work — mark the epic `in_progress` right after creating it so status-based exclusion keeps it out of `bn ready` on every build.

---

## Completeness Checklist

Ensure your task graph includes:

- [ ] A single parent epic (`-t epic`); every task bead parented to it via `--parent "$EPIC"`, with no orphan tasks and no blocking dep to/from the epic
- [ ] All setup and configuration tasks
- [ ] Core architecture and shared utilities
- [ ] Feature implementation tasks (broken into small units)
- [ ] Error handling and edge cases
- [ ] Unit and integration tests for each feature
- [ ] API documentation
- [ ] Security considerations (input validation, auth checks)
- [ ] Performance considerations where relevant
- [ ] CI/CD and deployment tasks
- [ ] Clear dependency chains with no cycles
