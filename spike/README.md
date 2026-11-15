# Run the macOS spike

The package is independent of the main Deskhand package. Local development may run only deterministic checks and catalog commands until signed runtime testing is authorized.

```sh
spike/scripts/run-spike.sh --selfcheck
```

This command builds, tests, lints, checks JSON and filesystem behavior, and lists catalogs. It does not install, register, request grants, capture, post events, focus windows, or lock.

## Build on the signing Mac

Run on m4max2025 from a clean checkout of the reviewed commit. The signing key and notary credentials remain on that Mac.

```sh
DESKHAND_SIGN_IDENTITY=23F09E197A3C0CB477D4FC48FA7AA022317DAF48 \
DESKHAND_NOTARY_PROFILE=deskhand-notary \
spike/scripts/build-bundle.sh --out /tmp/deskhand-spike-release
```

Use a fresh output directory. The command creates a signed, notarized and stapled arm64 `DeskhandSpike.app`, `DeskhandSpike.zip`, and `DeskhandSpike.receipt.json`. The signed app embeds source commit, team and architecture. The external receipt adds SHA-256 digests of the archive and executable. Transfer the ZIP and receipt together, verify the ZIP digest against the receipt, and extract with `ditto -x -k DeskhandSpike.zip .`.

## Install on each target

```sh
spike/scripts/install.sh /tmp/deskhand-spike-release/DeskhandSpike.app
```

The receipt must sit beside the app. Installation verifies signature, fixed Developer ID team and certificate, hardened runtime, Gatekeeper and stapled notarization before replacing `~/Applications/DeskhandSpike.app`. Login Items approval returns an incomplete exit code. The prior installation remains at `~/Applications/.DeskhandSpike.previous.app` until the new agent answers with the installed build receipt and code hash. Retry the installer after approval or interruption. Unregistration precedes replacement.

```sh
spike/scripts/uninstall.sh
```

Uninstallation retains evidence and permission grants.

## Collect evidence

These commands perform active measurements. Permission, input, capture, window and lock trials require a separately authorized signed runtime session.

```sh
spike/scripts/run-spike.sh --host lunus-macbook-pro --out /evidence/docs/spike-results --automatic
spike/scripts/run-spike.sh --host m1max2021 --remote punk1290@10.0.0.96 --out /evidence/docs/spike-results --automatic
spike/scripts/run-spike.sh --host lunus-macbook-pro --out /evidence/docs/spike-results --trial lock --path shortcut --count 20
```

`--remote` without a target uses `punk1290@10.0.0.96`. The target needs the installed signed app, Python 3, and these runner scripts. Guided remote trials need a terminal and a person at that Mac. SSH connection and liveness checks are bounded. Agent commands time out after 120 seconds without a response. Remote staging remains for recovery if transfer fails.

Each driver takes a host lease and writes a unique `<root>/<host>/runs/<run-id>/` directory. `<host>/campaign.json` selects successful complete reports per operation for one verified artifact receipt. Successful permissions and separate lock paths accumulate across invocations. Failed reruns remain visible in invocation history. Artifact changes select a separate campaign under `campaigns/`. Local and remote imports use the same locked atomic writer. `<host>/current-run` is navigation to the latest invocation; unscoped historical evidence does not complete a campaign. Prior runs remain intact. The cross-host checklist stays pending until reviewed evidence establishes completion; a summary file alone does not complete it. A blocked result records the missing permission and is not a successful measurement. Persistence and transport failures return nonzero.

The agent holds one UUID owner across a whole trial, including human pauses. Other clients fail while it is owned, and background capture and sampling pause. A crashed driver can leave a lease. Inspect the recorded driver PID before removing `~/Library/Application Support/homes.birb.deskhand/spike/driver.lock`. The owner and artifact identity persist in `session-claim.json` in the same support directory. Restart restores a suspended claim before background work starts. The trial verifies a new process with the same artifact, explicitly resumes its owner, and refreshes executor context. Restarting alone does not clear a claim. After confirming the driver is dead and no physical trial is active, inspect the claim and release its recorded UUID with `deskhand-spike agent-call session end UUID`. For a malformed claim or an artifact mismatch, stop the registered agent, move the claim aside as diagnostic evidence, and restart the registered agent before retrying. Do not remove a claim while its driver is active. No automatic expiry can release a trial while the user is unlocking.

Default trials require the agent. `--in-process` is an explicit diagnostic option on the executable and is excluded from installed-run orchestration. Reports retain driver context and add executor context. Finder drag and exclusion trials also contain driver measurements and their summary context is the driver. They cannot establish LaunchAgent behavior.

The local checks verify buildability and deterministic behavior. They do not establish SMAppService approval, permission attribution, signed-runtime operation, or physical results on either target.

## Remaining evidence and peer listener

A closed terminal aborts every guided input boundary and persists incomplete evidence. Transport completion requires a matching request ID, terminal count, successful command, and Catalog-derived probe identities. Partial results remain attached to failed evidence. Wake and idle results require valid causal prerequisites. Lock candidate agreement cannot establish independent safety qualification, so these lock trials remain inconclusive until independently timed reference intervals are available.

For inbound LAN evidence, run this on the target after authorization. The peer must have the same reviewed helper installed. SSH launches the peer helper, which connects to the target listener itself. The report correlates the target greeting nonce and accepted source endpoint with the peer result. Same-host results and unavailable peers remain pending.

```sh
spike/scripts/run-spike.sh --host lunus-macbook-pro --peer punk1290@10.0.0.96 --peer-listener
```

`--parse-only` validates runner arguments without installation or network effects. Persistence across builds remains external signer-mediated work. Obtain a second signed and notarized artifact from the signing Mac, preserve both artifact receipts and permission reports before and after installation, then compare grants. The runner does not rebuild or sign that artifact.
