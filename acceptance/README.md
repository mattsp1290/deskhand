# deskhand acceptance client

A scripted MCP client that checks one deskhand Mac over the wire, as a pod in the cluster sees it. It speaks
MCP `2026-07-28` with mutual TLS and the per-Mac bearer token, exactly as [the contract](../docs/contract.md)
describes, and writes machine-readable evidence to stdout.

| File | What it is |
| --- | --- |
| `deskhand_acceptance.py` | The client. Python 3 standard library only, so it runs on an unmodified `python` image. |
| `render-job.py` | Prints a ConfigMap (holding the client) and a Job for one run: one node, one Mac, one run ID. |
| `tests/` | `unittest` tests, including an end-to-end run against a local fake server that requires mTLS. |

## Checks

`DESKHAND_CHECKS` (or `--checks`) takes `default`, `all` or a comma-separated list. `default` is every check
except `pointer_move` and `type_text`, which need an operator. The `lease` checks run whenever a check that needs
the lease is selected.

| Check | Expects | Contract |
| --- | --- | --- |
| `discover` | `supportedVersions` is `["2026-07-28"]`, `tools.listChanged` false, server name `deskhand` | 3, 3.1 |
| `tools_list` | the six tools in order, with the titles and all four annotations of the table | 3.2 |
| `status` | `mcp_protocol_version`, `mac` equals `DESKHAND_MAC`, lease not held; reports `state` | 6.1, 5.4 |
| `displays` | at least one display | 6.2 |
| `screenshot` | long edge at most 2576, at most 3,588,000 pixels, at most 3,750,000 bytes, `sha256` and decoded image size match the metadata, valid `frame_id` | 6.3, 7, 16 |
| `lease` | `acquire` → `acquired`, `renew` → `renewed`, `release` → `released` and `status` shows it gone | 5.1, 5.4 |
| `pointer_move` | `move` to the pointer's own position (or the centre) under `permitted_apps`: `completed`, echoes, `global_point` | 6.4, 6.7, 6.8 |
| `type_text` | types a unique nonce under `permitted_apps`: `completed`, `target_app` is permitted; records whether the screen changed | 6.5, 6.7, 6.8 |
| `neg_missing_token`, `neg_wrong_token` | `401` with `WWW-Authenticate: Bearer` | 2.2, 2.4 |
| `neg_get`, `neg_delete` | `405` with `Allow: POST` | 2.4 |
| `neg_wrong_host` | `421` | 2.3, 2.4 |
| `neg_unsupported_version` | `400`, `-32022` | 2.3, 9.4 |
| `neg_method_mismatch`, `neg_name_mismatch` | `400`, `-32020` | 2.3, 9.4 |
| `neg_missing_header` | no `MCP-Protocol-Version`: `400`, `-32020` | 2.3, 9.4 |
| `neg_no_lease` | `pointer` before acquiring: tool error `lease_not_held` | 5.3, 9.5 |
| `neg_stale_frame` | `pointer` with an unknown frame under the lease: `stale_frame`, `details.reason` `unknown` | 8.3, 9.5 |

### Preconditions

- `displays`, `screenshot`, `neg_no_lease`, `neg_stale_frame`, `pointer_move` and `type_text` need the Mac in
  state `ok` (armed, unlocked, display awake), because a state's name is refused first (9.5 step 1).
- `neg_no_lease` and the lease checks need nobody else (for example Crew) holding the lease (5.1, 9.5 step 6).
- `pointer_move` and `type_text` also need nobody at the keyboard or pointer for 3 s (`user_active`, 13.2).

A failure caused by an unmet precondition says `precondition: ...` in its `error`. The lease is released in a
`finally`, also when the Job deadline sends SIGTERM, and its TTL ends it anyway.

### Before `pointer_move` and `type_text`

The app policy is deny-by-default (6.9): the desktop, Dock and menu bar are refused unless allowlisted. So a person
at the Mac opens a scratch document in a permitted app (TextEdit by default), clicks into its text area, leaves the
pointer over that window, then leaves the keyboard and pointer alone. `pointer_move` moves the pointer to where it
already is. `type_text` takes a screenshot, types `deskhand-acceptance-<12 hex>`, then takes another. Both send
`permitted_apps` set to `DESKHAND_PERMITTED_APPS`, so deskhand refuses with `denied_app` if anything else is under
the pointer or has focus, and `measured` in the evidence names the app.

## Configuration

| Variable | Meaning | Default |
| --- | --- | --- |
| `DESKHAND_HOST` | Service DNS name; also the TLS name checked against the server certificate | required |
| `DESKHAND_PORT` | Service port, also sent in `Host` | required |
| `DESKHAND_MAC` | Expected `status.mac` | required |
| `DESKHAND_CREDENTIALS_DIR` | Base for the four paths below | `/etc/deskhand-acceptance` |
| `DESKHAND_CLIENT_CERT`, `DESKHAND_CLIENT_KEY`, `DESKHAND_CA_CERT` | PEM files | `<base>/tls/tls.crt`, `tls.key`, `ca.crt` |
| `DESKHAND_TOKEN_FILE` | File holding the bearer token | `<base>/token/token` |
| `DESKHAND_CHECKS` | Check selection | `default` |
| `DESKHAND_PERMITTED_APPS` | Comma-separated bundle IDs for `pointer_move` and `type_text` | `com.apple.TextEdit` |
| `DESKHAND_RUN_ID`, `DESKHAND_HOLDER_ID` | Labels for the evidence and the lease holder (4.1, 4.3 alphabet; run ID at most 17) | random |
| `DESKHAND_TIMEOUT_S` | Per-request socket timeout | `30` (`10` in the Job) |

The token is read from its file and only ever sent in the `Authorization` header. It never appears in argv or in
the environment, and every line of output passes through a redactor. The key is only read by the TLS library.

## Evidence

One JSON object per line: `{"check", "ok", "ms", "facts", "error"?}` per check, then
`{"summary": {"mac", "host", "port", "node", "run_id", "holder_id", "checks", "failed", "terminated", "ok",
"client_sha256", "seconds"}}`.
Facts are non-secret: versions, state, HTTP status and JSON-RPC or tool error codes, image size, byte count and
SHA-256 (never the image). Exit status is 0 when every selected check passed, 1 otherwise, 2 for a configuration
error. A run that selects nothing is a configuration error, and a run stopped by SIGTERM fails.

## Running it in the cluster

```sh
python3 acceptance/render-job.py --node infra-control-master --mac m1max2021 --run-id icm-m1-01 \
  --port <service-port> | kubectl apply -f -
kubectl -n forge logs -f job/deskhand-acceptance-icm-m1-01
```

Render one Job per (node, Mac) pair; `--node` becomes the `kubernetes.io/hostname` node selector. The pod carries
`birb.homes/deskhand-egress: "true"`, runs as nobody with a read-only root filesystem, no capabilities, seccomp
`RuntimeDefault`, no service account token, and mounts the secrets read-only as files. The Job never retries
(`backoffLimit: 0`), stops after `--deadline` seconds (default 600) and is deleted a day after it finishes. The
pod's `birb.homes/acceptance-client-sha256` annotation and the summary's `client_sha256` name the exact client. The
immutable ConfigMap is not deleted with the Job; remove it with `kubectl -n forge delete configmap -l birb.homes/acceptance-run=<run-id>`.

### Placeholders that wait on birbhomes gates

| Input | Flag | Placeholder |
| --- | --- | --- |
| Service port | `--port` | none; required (birbhomes-r-5elb) |
| Service DNS name | `--host` | `deskhand-<mac>.forge.svc` (contract 2.1) |
| Client certificate Secret with `tls.crt`, `tls.key`, `ca.crt` | `--tls-secret` | `deskhand-acceptance-client-tls` |
| Token Secret and key | `--token-secret`, `--token-key` | `deskhand-token-<mac>`, `token` |
| Image | `--image` | `python:3.13.5-slim`; pin `@sha256:<digest>` at deploy time |

The client certificate must be the one whose subject deskhand is configured to expect, with `clientAuth`.

## Tests

```sh
python3 -m unittest discover -s acceptance/tests
```

The end-to-end test makes throwaway certificates with the `openssl` CLI (OpenSSL or macOS LibreSSL) and skips
with a reason when it cannot.
