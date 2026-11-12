#!/usr/bin/env python3
"""Apply the agreed findings from the 2026-11-12 graph review (Codex gpt-6.1-sol + Sonnet subagent).

Run once: python3 -I docs/prompts/apply-graph-review.py
"""
import json
import subprocess
import sys

MARK = "[graph-review 2026-11-12]"


def bn(*args):
    r = subprocess.run(["bn", *args, "--no-sync"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"bn {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout.strip()


issues = {i["id"]: i for i in json.loads(
    subprocess.run(["bn", "list", "-n", "0", "--json"], capture_output=True, text=True, check=True).stdout)}
if any(MARK in i["description"] for i in issues.values()):
    sys.exit("Graph review already applied; refusing to run twice.")


def append(iid, text):
    desc = issues[iid]["description"].strip() + f"\n\n{MARK} {text}"
    issues[iid]["description"] = desc
    bn("update", iid, "--description", desc)


def retitle(iid, title):
    bn("update", iid, "--title", title)


def new(title, parent, labels, priority, desc, blocked_by=()):
    args = ["create", title, "-t", "task", "-p", str(priority), "--parent", parent, "-d", desc, "--silent"]
    for label in labels:
        args += ["-l", label]
    iid = bn(*args)
    issues[iid] = {"id": iid, "description": desc}
    for b in blocked_by:
        dep(iid, b)
    return iid


def dep(child, parent):
    bn("dep", "add", child, parent)


def undep(child, parent):
    bn("dep", "remove", child, parent)


def prio(iid, p):
    bn("update", iid, "--priority", str(p))


E_SPIKE, E_CONTRACT, E_CORE, E_PLAT, E_PKG = "deskhand-04zd", "deskhand-66ri", "deskhand-nbj5", "deskhand-7wo6", "deskhand-htom"

# Gates
dep("deskhand-cfc8", "deskhand-fxz0")
append("deskhand-fxz0", "Default answer is no. If the owner chooses an internal allowlist, create an implementation task under the core epic blocking deskhand-6d91 before closing this gate.")
append("deskhand-88p6", "Closes on mirror URL, Actions enabled and the macOS runner online. The first passing workflow run is deskhand-iri9's completion criterion, not this gate's.")
dep("deskhand-nxas", "deskhand-xisn")
dep("deskhand-4na5", "deskhand-xisn")
dep("deskhand-bw22", "deskhand-cfc8")

# Contract: split and tighten
retitle("deskhand-k01y", "Draft docs/contract.md wire surface: tools, schemas, errors, lease ops, screenshot constants")
append("deskhand-k01y", "Scope narrowed to the wire surface. Must define lease acquire/renew/release on the wire with holder_id fields and allowed states; if this needs a tool beyond the five, it is a contract amendment gated by deskhand-nxas. Define max_long_edge range 256..2576 (outside -> invalid_argument), JPEG quality steps 85,75,65,60, oversized PNG -> image_too_large (no format switch), target-patch staleness region and tolerance, and the user-activity lookback interval.")
C_BEHAV = new("Draft docs/contract.md behavior: states, conditions, operation model, allowance format, amendments, timing bounds",
              E_CONTRACT, ["contract"], 0,
              "State table with precedence; conditions that are not states (credentials_warning, cleanup_pending, log_unavailable, login_window, user_active); login window reported as not_console plus the login_window condition; operation outcome model keyed by (principal, holder_id, operation_id); allowance JSON format; clean-stop behavior; 1 s deadline and 250 ms activity bounds; 'Changes from the shared contract'. When done, tag docs/contract.md v0.9-draft and note it on crew-r-yqso so Crew can start. Files: docs/contract.md (behavior sections).",
              ["deskhand-k01y"])
for d in ["deskhand-o6yz", "deskhand-zl8l", "deskhand-2gvr", "deskhand-xisn"]:
    dep(d, C_BEHAV)
dep("deskhand-cfc8", C_BEHAV)
dep("deskhand-cfc8", "deskhand-u5z8")
prio("deskhand-u5z8", 0)
append("deskhand-u5z8", "Must pass against the final spike-adjusted content before v1.0 is tagged.")
append("deskhand-xisn", "Include the clean-stop interface in the notes to birbhomes-r-ttg5.")

# Scaffold
append("deskhand-5ia6", "Declare every target and dependency up front so later tasks never edit Package.swift: targets DeskhandCore, DeskhandServer, DeskhandPlatform, DeskhandApp, DeskhandLogDaemon (macOS executable); dependencies swift-nio, swift-nio-ssl, swift-crypto (SHA-256 on Linux). Define the Swift Testing tag for TCC/GUI/display tests that CI excludes. Package.swift changes after this task need an explicit note.")

# Spike
retitle("deskhand-r0nn", "Spike: signed probe harness, SMAppService LaunchAgent install, capture and state probes")
append("deskhand-r0nn", "Use the final bundle identifier and install as a LaunchAgent via SMAppService (items 1, 9 and wallpaper-only capture need LaunchAgent execution). Includes a display-geometry dump. Input probes moved to a separate task.")
SP_INPUT = new("Spike: input, activity, hot-key and held-input probes", E_SPIKE, ["spike"], 0,
               "Add to the spike harness: CGEvent posting, secure-input targets, HID idle counter vs own posts, modifier chords vs global hot keys, RegisterEventHotKey modifiers, held synthetic input after process exit. Files: spike/Input/**.",
               ["deskhand-r0nn"])
SP_PCC = new("Spike: Persistent Content Capture qualification", E_SPIKE, ["spike"], 1,
             "If the entitlement was granted, measure whether it suppresses the recurring prompt on each Mac. If declined or unavailable, record that and define how deskhand reports a pending prompt. Evidence: docs/spike-results/pcc.md.",
             ["deskhand-7jyw", "deskhand-r0nn"])
for run, mac in [("deskhand-z67j", "lunus-macbook-pro"), ("deskhand-a52z", "m1max2021")]:
    dep(run, SP_INPUT)
    append(run, f"Write evidence to docs/spike-results/{mac}.md only; deskhand-7t13 aggregates docs/spike-results.md.")
append("deskhand-7c12", "Uses candidate signals from the per-Mac runs. Write evidence to docs/spike-results/lock.md. Physical trials on one Mac are serial.")
dep("deskhand-7c12", "deskhand-z67j")
dep("deskhand-7c12", "deskhand-a52z")
undep("deskhand-ealq", "deskhand-r0nn")
dep("deskhand-ealq", "deskhand-t7j1")
append("deskhand-ealq", "Needs no probe app; use nc or a plain listener. Evidence: docs/spike-results/network.md.")
dep("deskhand-7t13", SP_PCC)
dep("deskhand-7t13", "deskhand-7jyw")
append("deskhand-7t13", "Aggregate docs/spike-results/*.md into docs/spike-results.md. Also recommend: login-window detection, own-post discount for HID idle, kill-switch modifier.")

# Core
append("deskhand-o6yz", "Output includes the non-state conditions credentials_warning, cleanup_pending, log_unavailable and login_window; login window maps to not_console.")
append("deskhand-2gvr", "Store and look up records by (principal, holder_id, operation_id); capacity counts per principal across holders.")
append("deskhand-3520", "Add the Mac identifier (lunus-macbook-pro or m1max2021), the user-activity lookback interval, and the target-patch tolerance.")
append("deskhand-8ywz", "Enforce 256 <= max_long_edge <= 2576. The pixel-change check is a protocol implemented by the platform target-patch task.")
retitle("deskhand-bhwb", "Core: serial executor, busy refusal, per-event validation, op-store and log integration")
append("deskhand-bhwb", "Abort and release moved to a separate task. Bind the frontmost identity (bundle ID + team ID) at start; abort with denied_app if it changes, even to another allowlisted app; for pointer events require the target-window owner to be allowlisted; uncertain identity refuses. Tests: allowlisted-to-allowlisted switch, denied window under target, uncertain identity. Publish the protocols used by watchdog and recovery.")
undep("deskhand-bhwb", "deskhand-i910")
K_RELEASE = new("Core: abort and release with cleanup authorization and ledger", E_CORE, ["core"], 0,
                "On abort release only the operation's held input via the ledger. Releases require every blocking condition absent (locked, not_console, login_window, secure_input); otherwise defer and raise cleanup_pending. Files: Sources/DeskhandCore/Release/**.",
                ["deskhand-bhwb", "deskhand-i910"])
dep("deskhand-zze2", K_RELEASE)
dep("deskhand-zay1", K_RELEASE)
append("deskhand-zze2", "Files move to Sources/DeskhandCore/Watchdog/**. Before accepting an effect, refuse with user_active if activity is within the configured lookback. Define a post-timestamp provider protocol so own posts can be discounted. Tests: recent activity before execution and intervention during it.")
undep("deskhand-zuyx", "deskhand-zay1")

# Server
append("deskhand-aj88", "Define a token-provider protocol; this task enforces 401, deskhand-zkt0 supplies the token set.")
retitle("deskhand-zuyx", "Server: status, displays, screenshot and lease handlers with platform fakes")
append("deskhand-zuyx", "Pointer and keyboard handlers moved to a separate task.")
N_EFFECTS = new("Server: pointer and keyboard effect handlers with rate ceiling", E_CORE, ["server"], 0,
                "Pointer and keyboard handlers through the executor; enforce the per-minute rate_limited ceiling from deskhand-3520; newline/tab and text-size refusals; effect results carry measured frontmost app and window title. Files: Sources/DeskhandServer/Tools/Effects/**.",
                ["deskhand-zuyx"])
dep("deskhand-57vk", N_EFFECTS)
append("deskhand-57vk", "Also cover gated, user_active, lease_not_held, rate_limited, log_unavailable, cleanup_pending, busy during an executing op, cross-holder isolation for operations, frames and leases, same-subject cert rotation, and a restart-recovery run.")

# Platform
P_ENCODE = new("Platform: ImageIO downscale, JPEG/PNG encode and size loop", E_PLAT, ["platform"], 0,
               "Downscale per frame math; JPEG q85 then 75, 65, 60; PNG on request; over 5 MB -> image_too_large. Files: Sources/DeskhandPlatform/Encode/**.",
               ["deskhand-8ywz"])
dep("deskhand-jnt5", P_ENCODE)
P_PATCH = new("Platform: live target-patch recapture for stale_frame", E_PLAT, ["platform"], 0,
              "Implement the frame store's pixel-change protocol: recapture a small region around the target through the exclusion-preserving filter and compare within the contract tolerance; capture failure -> stale_frame. Tests for changed pixels and capture failure. Files: Sources/DeskhandPlatform/Capture/TargetPatch*.",
              ["deskhand-jnt5", "deskhand-8ywz"])
P_IDENT = new("Platform: frontmost app and target-window identity lookup", E_PLAT, ["platform"], 0,
              "Frontmost app and topmost window owner under a point, each as bundle ID plus verified signing team ID; measured window title. Files: Sources/DeskhandPlatform/Identity/**.",
              ["deskhand-mbba"])
retitle("deskhand-mupn", "Platform: CGEvent pointer and keyboard poster")
append("deskhand-mupn", "Identity lookup moved to a separate task. Feed post timestamps to the watchdog's provider protocol.")
append("deskhand-z42e", "Expose a separately tested login_window condition chosen from spike evidence; unknown detection prohibits input and cleanup. Implement the own-post discount via the watchdog's post-timestamp provider.")
dep("deskhand-j5it", "deskhand-7t13")
dep("deskhand-j5it", "deskhand-7jyw")
dep("deskhand-cbqq", "deskhand-7t13")
undep("deskhand-8fjh", "deskhand-6rnl")
P_STOP = new("Platform: clean-stop interface for the LAN gate", E_PLAT, ["platform"], 1,
             "deskhand-r-nkjj 'Clean stop'. Agree the trigger with birbhomes-r-ttg5 (default: SIGTERM from launchd plus allowance revocation). Behaves like paused: cancel, authorized release or durable deferral, persist state, exit cleanly. Document invocation in docs/contract.md. Files: Sources/DeskhandApp/Stop/**.",
             [C_BEHAV, "deskhand-o6yz", K_RELEASE])
P_WIRE = new("App: condition aggregator, state-effect wiring, arming and deadline sources", E_PLAT, ["platform"], 0,
             "Periodic probe loop feeding the reducer; apply reducer effects (cancel, release, invalidate frames, drop lease); arming expiry from the menu as a deadline source; allowance and lease deadlines to the watchdog. Files: Sources/DeskhandApp/Wiring/**.",
             ["deskhand-o6yz", "deskhand-z42e", "deskhand-zze2", "deskhand-zl8l", "deskhand-j5it"])
for d in [P_PATCH, P_IDENT, P_STOP, P_WIRE, N_EFFECTS, "deskhand-zay1"]:
    dep("deskhand-6d91", d)

# Packaging
dep("deskhand-95x7", "deskhand-7t13")
dep("deskhand-95x7", "deskhand-7jyw")
append("deskhand-95x7", "Embed and nested-sign the DeskhandLogDaemon executable. LSMinimumSystemVersion, usage strings and entitlements follow the spike recommendations.")
dep("deskhand-tzac", "deskhand-6rnl")
append("deskhand-tzac", "Install and uninstall are app subcommands (deskhand install|uninstall). Registering or removing the daemon needs admin rights.")
undep("deskhand-cpkl", "deskhand-tzac")
dep("deskhand-cpkl", "deskhand-k01y")
dep("deskhand-cpkl", "deskhand-95x7")

# Security review and acceptance
dep("deskhand-cts7", "deskhand-6d91")
dep("deskhand-cts7", "deskhand-tzac")
append("deskhand-cts7", "Review the integrated build: XPC client validation, root-owned log paths and rotation, app-identity resolution, login-window detection, deferred cleanup, install permissions.")
prio("deskhand-cts7", 0)
for m in ["deskhand-hja5", "deskhand-aavp"]:
    for d in ["deskhand-tzac", "deskhand-farl", "deskhand-4na5", "deskhand-cfc8"]:
        dep(m, d)
    append(m, "Evidence must come from the installed bundle signed with the chosen identity, in the selected console mode.")
append("deskhand-x5io", "Cover lease acquire, renew and release.")
for d in ["deskhand-y7s7", "deskhand-iri9", "deskhand-0nce"]:
    dep("deskhand-7w2c", d)
append("deskhand-7w2c", "CI checks must be green on the accepted commit.")

# Shared completion rules
append("deskhand-b1c6", "Completion rules for every child: implementation tasks close with a commit or PR link, the commands run and their results, and two independent reviews with findings resolved. Spike measurement tasks close with evidence in docs/spike-results/ after one review. Gate tasks close on evidence alone.")

# Priorities: tasks that block p0 work
for iid in ["deskhand-t7j1", "deskhand-3520", "deskhand-mbba", "deskhand-wo02", "deskhand-yvsk", "deskhand-zay1",
            "deskhand-zkt0", "deskhand-j5it", "deskhand-cbqq", "deskhand-xisn", "deskhand-7jyw", "deskhand-ealq",
            "deskhand-u4lm", "deskhand-farl", "deskhand-4na5", "deskhand-fxz0", "deskhand-y7s7", "deskhand-iri9", "deskhand-0nce"]:
    prio(iid, 0)

print("applied")
