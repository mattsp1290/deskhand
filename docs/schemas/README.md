# Contract schemas

JSON Schema Draft 2020-12 files for the wire contract in
[`docs/contract.md`](../contract.md). The contract's
[schema index](../contract.md#19-schema-index) says what each file holds.

## Checking

```sh
python3 -m venv .venv
.venv/bin/pip install -r scripts/requirements-contract.txt
.venv/bin/python scripts/check-contract.py
```

The `Contract schemas` job in `.github/workflows/docs.yml` runs the same check.
It prints one `FAIL` line per problem and exits non-zero if there are any.

## Layout convention

The checker finds schemas and examples by where they live and how they are
named. Adding a file in the right place is enough; the script has no list to
update.

| Path | Rule |
| --- | --- |
| `**/*.json` outside `examples/` | A schema. It declares Draft 2020-12, has an `$id` ending in its path under `docs/schemas/`, and every `$ref` resolves locally. Its stem is the file name without `.json` and must be unique. |
| `defs.json` | Shared definitions. The only schema that needs no example. |
| `tools/<tool>.input.json`, `tools/<tool>.output.json` | Tool schemas, always in pairs. They must survive the `tools/list` bundling rule (contract 3.2); input schemas are closed objects with no top-level combinators. |
| `examples/<stem>.<name>.json` | Must validate against the schema with the longest matching stem. Every schema except `defs.json` needs at least one. |
| `examples/invalid/<stem>.<name>.json` | Must be rejected by that schema. |
| `examples/wire/*.json` | A whole JSON-RPC 2.0 message with an `id`. In `tools-call.<tool>.<name>.<request\|response>.json`, the arguments or `structuredContent` must validate against `tools/<tool>.*.json`. |

`<name>` uses `a-z`, `0-9` and `-`. For example, `tools/pointer.input.json` has
stem `pointer.input`, so `examples/pointer.input.click.json` is checked against
it; a new `allowance.json` has stem `allowance` and its examples are
`examples/allowance.<name>.json`. Any other JSON file or directory under
`examples/` fails the check.

The checker also compares `docs/contract.md` with `defs.json`: the error codes
in 9.3, the states in 10, the stale-frame reasons in 8.3, the conditions in 11
and the `tool_error` members and `details` keys in 9.2 must match, and every
`#anchor` link in the contract must resolve to a heading.
