#!/usr/bin/env python3
"""Check docs/schemas and docs/contract.md against each other.

Everything is discovered by convention under docs/schemas/, so adding a schema
or an example needs no edit here:

  Schemas    Every *.json under docs/schemas/ outside examples/. A schema's
             stem is its file name without .json (tools/pointer.input.json has
             stem "pointer.input", allowance.json has stem "allowance"). Stems
             must be unique. Each schema must declare Draft 2020-12, have an
             $id ending in its path relative to docs/schemas/, and every $ref
             must resolve locally (no network).
  defs.json  The shared definitions library. It is the only schema that needs
             no valid example.
  tools/     Tool schemas <tool>.input.json and <tool>.output.json. They must
             also survive the tools/list bundling rule (contract 3.2); input
             schemas must be closed objects with no top-level combinators.
  Examples   examples/<stem>.<name>.json must validate against the schema
             with the longest matching stem. Every schema except defs.json
             needs at least one.
  Invalid    examples/invalid/<stem>.<name>.json must be rejected.
  Wire       examples/wire/*.json are whole JSON-RPC 2.0 messages with an id.
             tools-call.<tool>.<name>.<request|response>.json must carry
             arguments / structuredContent valid against tools/<tool>.*.json.
  Prose      docs/contract.md tables (9.2, 9.3, 8.3, 10, 11) must match the
             enums and tool_error members in defs.json, and every intra-doc
             #anchor must resolve to a heading.

Any other JSON file under examples/ is an error, so nothing is silently skipped.
Exits 1 and prints one line per failure.
"""

import argparse
import copy
import json
import re
import sys
from pathlib import Path

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError, best_match
from referencing import Registry, Resource
from referencing.exceptions import Unresolvable
from referencing.jsonschema import DRAFT202012

DRAFT = "https://json-schema.org/draft/2020-12/schema"
DEFS = "defs.json"
TOOLS_DIR = "tools"
EXAMPLE_NAME = re.compile(r"^[a-z0-9-]+$")
WIRE_CALL = re.compile(r"^tools-call\.([a-z0-9_-]+)\.[a-z0-9-]+\.(request|response)\.json$")


class Checker:
    def __init__(self, docs: Path):
        self.docs = docs
        self.root = docs / "schemas"
        self.fails: list[str] = []
        self.counts = dict.fromkeys(("schemas", "refs", "valid", "invalid", "wire", "bundled"), 0)

    def fail(self, msg: str) -> None:
        self.fails.append(msg)

    def rel(self, p: Path) -> str:
        return p.relative_to(self.root).as_posix()

    def load(self, p: Path):
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError) as e:
            self.fail(f"{self.rel(p)}: cannot read JSON: {e}")
            return None

    # Schemas

    def load_schemas(self) -> None:
        self.schemas: dict[str, dict] = {}  # relative path -> schema
        self.by_stem: dict[str, str] = {}  # stem -> relative path
        paths = sorted(p for p in self.root.rglob("*.json") if "examples" not in p.relative_to(self.root).parts)
        for p in paths:
            rel = self.rel(p)
            s = self.load(p)
            if not isinstance(s, dict):
                if s is not None:
                    self.fail(f"{rel}: schema root is not an object")
                continue
            self.counts["schemas"] += 1
            if s.get("$schema") != DRAFT:
                self.fail(f"{rel}: $schema must be {DRAFT}")
            if not str(s.get("$id", "")).endswith("/" + rel):
                self.fail(f"{rel}: $id {s.get('$id')!r} does not end with /{rel}")
            try:
                Draft202012Validator.check_schema(s)
            except SchemaError as e:
                self.fail(f"{rel}: not a valid Draft 2020-12 schema: {e.message}")
                continue
            stem = p.name.removesuffix(".json")
            if stem in self.by_stem:
                self.fail(f"{rel}: stem {stem!r} also used by {self.by_stem[stem]}")
                continue
            self.schemas[rel] = s
            self.by_stem[stem] = rel
        if DEFS not in self.schemas:
            self.fail(f"{DEFS}: missing or invalid; nothing else can be checked")
            return
        self.registry = Registry().with_resources(
            (s["$id"], Resource.from_contents(s, default_specification=DRAFT202012))
            for s in self.schemas.values()
            if "$id" in s
        )
        self.validators = {
            rel: Draft202012Validator(s, registry=self.registry) for rel, s in self.schemas.items()
        }
        for rel, s in self.schemas.items():
            self.check_refs(rel, s)

    def check_refs(self, rel: str, schema: dict) -> None:
        # Validators resolve $ref lazily, so a ref on a path no example reaches would go unnoticed.
        resolver = self.registry.resolver(base_uri=schema.get("$id", ""))

        def walk(node, where):
            if isinstance(node, dict):
                ref = node.get("$ref")
                if isinstance(ref, str):
                    self.counts["refs"] += 1
                    try:
                        resolver.lookup(ref)
                    except Unresolvable:
                        self.fail(f"{rel}: $ref {ref!r} at {where or '/'} does not resolve")
                for k, v in node.items():
                    walk(v, f"{where}/{k}")
            elif isinstance(node, list):
                for i, v in enumerate(node):
                    walk(v, f"{where}/{i}")

        walk(schema, "")

    def check_tools(self) -> None:
        """The tools/list serving rule (contract 3.2) and the flat-input rule."""
        defs = self.schemas[DEFS].get("$defs", {})
        for rel, s in self.schemas.items():
            parts = rel.split("/")
            if parts[0] != TOOLS_DIR:
                continue
            m = re.fullmatch(r"([a-z0-9_-]+)\.(input|output)\.json", parts[-1])
            if len(parts) != 2 or not m:
                self.fail(f"{rel}: tool schemas are named tools/<tool>.<input|output>.json")
                continue
            tool, direction = m.groups()
            other = f"{TOOLS_DIR}/{tool}.{'output' if direction == 'input' else 'input'}.json"
            if other not in self.schemas:
                self.fail(f"{rel}: no matching {other}")
            b = copy.deepcopy(s)
            b.pop("$id", None)
            local = b.setdefault("$defs", {})
            clash = set(local) & set(defs)
            if clash:
                self.fail(f"{rel}: $defs names clash with {DEFS}: {sorted(clash)}")
            local.update(copy.deepcopy(defs))
            text = json.dumps(b).replace(f"../{DEFS}#/$defs/", "#/$defs/")
            if DEFS in text:
                self.fail(f"{rel}: a {DEFS} reference survives bundling")
            b = json.loads(text)
            try:
                Draft202012Validator.check_schema(b)
                self.bundled[rel] = Draft202012Validator(b)
                self.counts["bundled"] += 1
            except SchemaError as e:
                self.fail(f"{rel}: bundled form is not a valid schema: {e.message}")
            if direction == "input":
                for kw in ("oneOf", "anyOf", "allOf", "if", "not", "dependentRequired"):
                    if kw in s:
                        self.fail(f"{rel}: top-level {kw} (input schemas stay flat)")
                if s.get("type") != "object" or s.get("additionalProperties") is not False:
                    self.fail(f"{rel}: input schema must be a closed object")
            elif s.get("type") != "object":
                self.fail(f"{rel}: output schema root type must be object")

    # Examples

    def schema_for(self, filename: str) -> str | None:
        name = filename.removesuffix(".json")
        best = None
        for stem in self.by_stem:
            rest = name[len(stem) + 1 :]
            if name.startswith(stem + ".") and EXAMPLE_NAME.match(rest) and (best is None or len(stem) > len(best)):
                best = stem
        return self.by_stem.get(best) if best else None

    def errors(self, rel: str, instance) -> list[str]:
        out = []
        for label, v in (("", self.validators[rel]), (" [bundled]", self.bundled.get(rel))):
            if v is None:
                continue
            err = best_match(v.iter_errors(instance))
            out.append(f"{label} at /{'/'.join(map(str, err.path))}: {err.message[:200]}" if err else None)
        return out

    def check_examples(self) -> None:
        ex = self.root / "examples"
        known = {ex, ex / "invalid", ex / "wire"}
        for p in sorted(ex.rglob("*")):
            if p.is_dir() and p not in known:
                self.fail(f"{self.rel(p)}: unknown examples directory (use examples/, invalid/ or wire/)")
            elif p.is_file() and p.parent not in known:
                self.fail(f"{self.rel(p)}: example outside examples/, invalid/ or wire/")
        covered = set()
        for folder, want_valid in ((ex, True), (ex / "invalid", False)):
            for p in sorted(folder.glob("*.json")):
                rel = self.schema_for(p.name)
                if rel is None:
                    self.fail(f"{self.rel(p)}: name is not <schema stem>.<name>.json for any schema "
                              f"(stems: {', '.join(sorted(self.by_stem))})")
                    continue
                inst = self.load(p)
                if inst is None:
                    continue
                for e in self.errors(rel, inst):
                    if want_valid and e:
                        self.fail(f"{self.rel(p)}: should validate against {rel} but fails{e}")
                    if not want_valid and e is None:
                        self.fail(f"{self.rel(p)}: should be rejected by {rel} but validates")
                if want_valid:
                    covered.add(rel)
                    self.counts["valid"] += 1
                else:
                    self.counts["invalid"] += 1
        for rel in sorted(set(self.schemas) - covered - {DEFS}):
            self.fail(f"{rel}: no valid example under examples/")

    def check_wire(self) -> None:
        for p in sorted((self.root / "examples" / "wire").glob("*.json")):
            name = self.rel(p)
            doc = self.load(p)
            if doc is None:
                continue
            self.counts["wire"] += 1
            if not isinstance(doc, dict) or doc.get("jsonrpc") != "2.0" or "id" not in doc:
                self.fail(f"{name}: not a JSON-RPC 2.0 message with an id")
                continue
            if ("result" in doc) + ("error" in doc) + ("method" in doc) != 1:
                self.fail(f"{name}: must have exactly one of method, result, error")
            m = WIRE_CALL.match(p.name)
            if not m:
                continue
            tool, kind = m.groups()
            direction = "input" if kind == "request" else "output"
            rel = f"{TOOLS_DIR}/{tool}.{direction}.json"
            if rel not in self.schemas:
                self.fail(f"{name}: no schema {rel}")
                continue
            try:
                if kind == "request":
                    if doc.get("method") != "tools/call" or doc["params"]["name"] != tool:
                        self.fail(f"{name}: not a tools/call of {tool}")
                    inst = doc["params"].get("arguments", {})
                else:
                    res = doc["result"]
                    inst = res["structuredContent"]
                    if res.get("isError", False) != ("code" in inst):
                        self.fail(f"{name}: isError does not agree with presence of code")
                    texts = [c for c in res["content"] if c.get("type") == "text"]
                    if len(texts) != 1 or json.loads(texts[0]["text"]) != inst:
                        self.fail(f"{name}: needs exactly one text block holding the structuredContent JSON")
                    if not res["content"] or res["content"][-1].get("type") != "text":
                        self.fail(f"{name}: the text block must be last")
            except (KeyError, TypeError, ValueError) as e:
                self.fail(f"{name}: malformed tools/call message: {type(e).__name__}: {e}")
                continue
            for e in self.errors(rel, inst):
                if e:
                    self.fail(f"{name}: {direction} does not validate against {rel}{e}")

    def check_enums(self) -> None:
        d = self.schemas[DEFS].get("$defs", {})
        try:
            states = d["state"]["enum"]
            if d["blocking_state"]["enum"] != states[:-1] or states[-1] != "ok":
                self.fail(f"{DEFS}: blocking_state must equal state without the final ok, same order")
            if not set(states[:-1]) <= set(d["error_code"]["enum"]):
                self.fail(f"{DEFS}: every non-ok state must also be an error_code")
        except (KeyError, TypeError) as e:
            self.fail(f"{DEFS}: missing enum {e}")
        for name, node in d.items():
            vals = node.get("enum") if isinstance(node, dict) else None
            if isinstance(vals, list) and len(vals) != len({json.dumps(v) for v in vals}):
                self.fail(f"{DEFS}: duplicate values in {name}")

    # Prose

    def check_prose(self) -> None:
        path = self.docs / "contract.md"
        try:
            md = path.read_text(encoding="utf-8")
        except OSError as e:
            self.fail(f"contract.md: {e}")
            return
        d = self.schemas[DEFS].get("$defs", {})

        def section(prefix: str) -> str:
            m = re.search(rf"^#+ {re.escape(prefix)}.*?$(.*?)(?=^#+ |\Z)", md, re.S | re.M)
            if not m:
                self.fail(f"contract.md: section '{prefix}' not found")
                return ""
            return m.group(1)

        def enum(name: str) -> list:
            return d.get(name, {}).get("enum", [])

        def first_col(text: str) -> list[str]:
            return re.findall(r"^\| `([a-z_]+)` \|", text, re.M)

        def compare(where: str, doc: list, name: str) -> None:
            schema = enum(name)
            if doc == schema:
                return
            only_doc, only_schema = sorted(set(doc) - set(schema)), sorted(set(schema) - set(doc))
            detail = f"only in prose {only_doc}, only in {DEFS} {only_schema}" if only_doc or only_schema else "order differs"
            self.fail(f"contract.md {where} does not match {DEFS} $defs/{name}: {detail}")

        def slug(h: str) -> str:
            h = re.sub(r"[`*]", "", h.strip().lower())
            return re.sub(r"[^\w\- ]", "", h).replace(" ", "-")

        anchors = {slug(h) for h in re.findall(r"^#+ (.+)$", md, re.M)}
        for a in re.findall(r"\]\(#([^)]+)\)", md):
            if a not in anchors:
                self.fail(f"contract.md: broken anchor #{a}")

        compare("9.3 error code table", first_col(section("9.3 Tool error codes")), "error_code")
        compare("section 10 state table", re.findall(r"^\| \d+ \| `([a-z_]+)` \|", section("10. States"), re.M), "state")
        compare("8.3 reason table", [r for r in first_col(section("8.3 Frame staleness")) if r != "reason"],
                "stale_frame_reason")
        conditions = section("11. Conditions")
        for c in enum("condition"):
            if f"`{c}`" not in conditions:
                self.fail(f"contract.md section 11 does not name condition `{c}` from {DEFS}")

        shape = section("9.2 The")
        tool_error = d.get("tool_error", {}).get("properties", {})
        for p in tool_error:
            if f"| `{p}` |" not in shape:
                self.fail(f"contract.md 9.2 member table lacks tool_error.{p}")
        # 9.2 rows name details keys in their second column; these also name non-detail fields.
        doc_details = set(re.findall(r"`([a-z_]+)`", "\n".join(
            line.split("|")[2] for line in shape.splitlines()
            if line.startswith("| `") and line.count("|") == 3)))
        doc_details -= {"arguments", "pixels_changed", "policy", "permitted_apps"}
        schema_details = set(tool_error.get("details", {}).get("properties", {}))
        if doc_details != schema_details:
            self.fail(f"contract.md 9.2 details keys differ from {DEFS}: "
                      f"only in prose {sorted(doc_details - schema_details)}, "
                      f"only in {DEFS} {sorted(schema_details - doc_details)}")

    def run(self) -> int:
        self.bundled: dict[str, Draft202012Validator] = {}
        self.load_schemas()
        if DEFS in self.schemas:
            self.check_tools()
            self.check_examples()
            self.check_wire()
            self.check_enums()
            self.check_prose()
        summary = ", ".join(f"{k} {v}" for k, v in self.counts.items())
        if self.fails:
            for f in self.fails:
                print(f"FAIL {f}", file=sys.stderr)
            print(f"check-contract: {len(self.fails)} failure(s) ({summary})", file=sys.stderr)
            return 1
        print(f"check-contract: ok ({summary})")
        return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--docs", type=Path, default=Path(__file__).resolve().parent.parent / "docs",
                    help="docs directory holding contract.md and schemas/ (default: %(default)s)")
    args = ap.parse_args()
    return Checker(args.docs).run()


if __name__ == "__main__":
    sys.exit(main())
