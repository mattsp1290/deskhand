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

Each driver takes a host lease and writes a unique `<root>/<host>/runs/<run-id>/` directory. `<host>/current-run` selects the run consumed by the existing host-level `checklist --dir <host>` and `summarize --dir <host>` contract. Prior runs remain intact. The cross-host checklist stays pending until reviewed evidence establishes completion; a summary file alone does not complete it. A blocked result records the missing permission and is not a successful measurement. Persistence and transport failures return nonzero.

The agent holds one UUID owner across a whole trial, including human pauses. Other clients fail while it is owned, and background capture and sampling pause. A crashed driver can leave a lease. Inspect the recorded driver PID before removing `~/Library/Application Support/homes.birb.deskhand/spike/driver.lock`. An orphaned agent session requires restarting the registered agent before retrying. No automatic expiry can release a trial while the user is unlocking.

Default trials require the agent. `--in-process` is an explicit diagnostic option on the executable and is excluded from installed-run orchestration. Reports retain driver context and add executor context. Finder drag and exclusion trials also contain driver measurements and their summary context is the driver. They cannot establish LaunchAgent behavior.

The local checks verify buildability and deterministic behavior. They do not establish SMAppService approval, permission attribution, signed-runtime operation, or physical results on either target.
