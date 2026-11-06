#!/usr/bin/env python3
"""Validate the project math skill catalogue without third-party packages."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
from urllib.parse import unquote, urlsplit

DEFAULT_ROOT = Path(__file__).resolve().parents[1] / "Sources/VocabCapture/Resources/MathSkills"
NAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
SOURCE_ID = re.compile(r"markdown-[0-9a-f]{64}\Z")
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
REQUIRED_METADATA = {"title", "category", "version", "schema_version", "source_file", "source_sha256", "legacy_source_id"}
OPTIONAL_METADATA = {"source_reference", "body_sha256"}
REQUIRED_ENTRY = {"name", "title", "category", "version", "source_id", "description", "sha256", "path"}


class ValidationError(ValueError):
    pass


def validate_runtime_budget(snapshots: list[dict]) -> None:
    """Validate one request workset, not the sum of the installed catalogue."""
    require(len(snapshots) <= 512, "runtime snapshots exceed 512 entries")
    size = sum(len(json.dumps(item, ensure_ascii=False).encode("utf-8")) for item in snapshots)
    require(size <= 300_000, "catalogue runtime snapshots exceed 300 KB")


def validate_catalogue_serviceability(snapshots: list[dict]) -> None:
    """Keep every complete skill serviceable without treating inventory as a request.

    Runtime callers still validate actual worksets including bound policy metadata.
    """
    for snapshot in snapshots:
        validate_runtime_budget([snapshot])


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def safe_relative(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    require(bool(value) and "\\" not in value and not path.is_absolute()
            and not any(part in {"", ".", ".."} for part in value.split("/"))
            and ":" not in value and "\0" not in value,
            f"unsafe relative path: {value}")
    return path


def bounded_bytes(path: Path) -> bytes:
    require(path.is_file() and not path.is_symlink(), f"not a regular file: {path.name}")
    require(path.stat().st_size <= 1_000_000, f"file exceeds 1 MB: {path.name}")
    data = path.read_bytes()
    require(len(data) <= 1_000_000, f"file exceeds 1 MB: {path.name}")
    return data


def parse_skill(data: bytes) -> tuple[dict[str, str], dict[str, str], bytes]:
    require(data.startswith(b"---\n"), "SKILL.md must start with LF frontmatter")
    end = data.find(b"\n---\n", 4)
    require(end >= 0, "missing frontmatter end")
    try:
        header = data[4:end].decode("utf-8")
        body = data[end + 5:]
        text = body.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValidationError("SKILL.md must be UTF-8") from error
    require(text.strip() and "\0" not in text, "empty or NUL-containing skill body")
    top: dict[str, str] = {}
    metadata: dict[str, str] = {}
    in_metadata = False
    for line in header.split("\n"):
        if line == "metadata:":
            require(not in_metadata, "duplicate metadata")
            in_metadata = True
            continue
        match = re.fullmatch(r"(  )?([a-z_][a-z0-9_]*): (.+)", line)
        require(match is not None, f"unsupported frontmatter line: {line}")
        indent, key, encoded = match.groups()
        require(bool(indent) == in_metadata, f"wrong frontmatter indentation: {key}")
        try:
            value = json.loads(encoded)
        except (ValueError, TypeError) as error:
            raise ValidationError(f"frontmatter {key} must be a JSON-quoted string") from error
        require(isinstance(value, str) and value.strip() and "\0" not in value,
                f"empty or non-string frontmatter: {key}")
        target = metadata if in_metadata else top
        require(key not in target, f"duplicate frontmatter key: {key}")
        target[key] = value
    require(set(top) == {"name", "description"}, "frontmatter requires only name, description, metadata")
    require(REQUIRED_METADATA <= set(metadata) <= REQUIRED_METADATA | OPTIONAL_METADATA,
            "unsupported or missing metadata fields")
    require(("source_reference" in metadata) == ("body_sha256" in metadata),
            "source_reference and body_sha256 must appear together")
    return top, metadata, body


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def validate(root: Path, source_dir: Path | None = None) -> int:
    require(root.is_dir() and not root.is_symlink(), "catalogue root must be a real directory")
    root = root.resolve()
    # Reject even unused symlinks so future linked resources cannot escape the catalogue.
    for path in root.rglob("*"):
        require(not path.is_symlink(), f"symlink is forbidden: {path.relative_to(root)}")
    raw = bounded_bytes(root / "index.json")
    try:
        manifest = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, ValueError) as error:
        raise ValidationError(f"invalid manifest: {error}") from error
    require(isinstance(manifest, dict) and set(manifest) == {"schema_version", "skills"}
            and type(manifest["schema_version"]) is int and manifest["schema_version"] == 1,
            "manifest schema_version must be integer 1")
    entries = manifest["skills"]
    require(isinstance(entries, list) and 0 < len(entries) <= 500, "catalogue requires 1–500 skills")
    names: set[str] = set()
    identities: set[str] = set()
    source_names: set[str] = set()
    parsed = []
    snapshots = []
    expected_files = {root / "index.json"}
    total = len(raw)
    for entry in entries:
        require(isinstance(entry, dict) and REQUIRED_ENTRY <= set(entry) <= REQUIRED_ENTRY | {"legacy_alias_ids"},
                "unsupported or missing manifest skill fields")
        require(all(isinstance(entry[field], str) and entry[field].strip() for field in REQUIRED_ENTRY),
                "manifest skill fields must be nonempty strings")
        name = entry["name"]
        require(NAME.fullmatch(name) is not None and len(name) <= 64 and name not in names,
                f"invalid or duplicate skill name: {name}")
        names.add(name)
        require(entry["path"] == name + "/SKILL.md", f"unexpected skill path: {name}")
        safe_relative(entry["path"])
        path = root / entry["path"]
        data = bounded_bytes(path)
        total += len(data)
        expected_files.add(path)
        require(DIGEST.fullmatch(entry["sha256"]) is not None and sha256(data) == entry["sha256"],
                f"SKILL.md hash mismatch: {name}")
        top, metadata, body = parse_skill(data)
        require(top["name"] == name and top["description"] == entry["description"],
                f"skill discovery metadata mismatch: {name}")
        require(len(top["description"]) <= 1024, f"description too long: {name}")
        for field in ("title", "category", "version"):
            require(metadata[field] == entry[field], f"manifest {field} mismatch: {name}")
        require(len(entry["title"]) <= 256 and len(entry["category"]) <= 256,
                f"runtime title/category exceeds 256 characters: {name}")
        require(re.fullmatch(r"[1-9][0-9]*", metadata["version"]) is not None
                and metadata["schema_version"] == "1.0", f"unsupported skill version/schema: {name}")
        require(metadata["legacy_source_id"] == entry["source_id"]
                and SOURCE_ID.fullmatch(entry["source_id"]) is not None,
                f"invalid legacy source identity: {name}")
        aliases = entry.get("legacy_alias_ids", [])
        require(isinstance(aliases, list) and all(isinstance(alias, str) and UUID.fullmatch(alias)
                for alias in aliases), f"invalid legacy aliases: {name}")
        for identity in [entry["source_id"], *aliases]:
            require(identity.lower() not in identities, f"duplicate source identity or alias: {name}")
            identities.add(identity.lower())
        file_name = metadata["source_file"]
        require(str(safe_relative(file_name)) == file_name and "/" not in file_name
                and file_name.endswith(".md") and file_name not in source_names,
                f"invalid or duplicate source filename: {name}")
        source_names.add(file_name)
        require(DIGEST.fullmatch(metadata["source_sha256"]) is not None, f"invalid source digest: {name}")
        source = body
        if "source_reference" in metadata:
            reference = safe_relative(metadata["source_reference"])
            require(reference.parts[0] == "references", f"source reference must be in references/: {name}")
            source_path = path.parent / reference
            source = bounded_bytes(source_path)
            total += len(source)
            expected_files.add(source_path)
            require(DIGEST.fullmatch(metadata["body_sha256"]) is not None
                    and sha256(body) == metadata["body_sha256"], f"body digest mismatch: {name}")
        require(sha256(source) == metadata["source_sha256"], f"source digest mismatch: {name}")
        if source_dir is not None:
            source_path = source_dir / file_name
            require(bounded_bytes(source_path) == source, f"original source bytes changed: {file_name}")
            canonical = source_dir.resolve()
            expected_id = "markdown-" + sha256((str(canonical) + "/" + file_name).encode("utf-8"))
            require(entry["source_id"] == expected_id, f"legacy source ID mismatch: {name}")
        parsed.append((path, metadata, body.decode("utf-8")))
        snapshots.append({"id": entry["source_id"], "version_id": "00000000-0000-0000-0000-000000000000",
                          "title": entry["title"], "category": entry["category"],
                          "instructions": body.decode("utf-8"), "skill_name": name,
                          "description": entry["description"]})
    validate_catalogue_serviceability(snapshots)
    require([entry["name"] for entry in entries] == sorted(names), "manifest must be sorted by skill name")
    lookup = {Path(metadata["source_file"]).stem for _, metadata, _ in parsed}
    lookup.update(metadata["title"] for _, metadata, _ in parsed)
    for path, metadata, body in parsed:
        for target in re.findall(r"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]", body):
            require(target.split("#", 1)[0] in lookup, f"unresolved wiki method link: {target}")
        for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", body):
            target = target.strip().split(" ", 1)[0]
            url = urlsplit(target)
            if url.scheme or url.netloc:
                require(url.scheme in {"https", "http"}, f"unsupported external link: {target}")
                continue
            if not url.path:
                continue
            relative = safe_relative(unquote(url.path))
            linked = path.parent / relative
            bounded_bytes(linked)
            expected_files.add(linked)
        if "source_reference" in metadata:
            require(metadata["source_reference"] in body, "source reference must be linked from the skill")
    actual_files = {path for path in root.rglob("*") if path.is_file()}
    require(actual_files == expected_files, "catalogue contains missing or unreferenced files")
    require({p.name for p in root.iterdir() if p.is_dir()} == names, "catalogue contains unlisted skill directories")
    require(total <= 10_000_000, "catalogue exceeds 10 MB")
    if source_dir is not None:
        originals = {path.name for path in source_dir.glob("*.md") if path.stem != "目录"}
        require(originals == source_names, "catalogue does not cover every source method")
    return len(entries)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--source-dir", type=Path, help="optionally verify exact original bytes and legacy source IDs")
    args = parser.parse_args()
    try:
        count = validate(args.root, args.source_dir)
        review = args.root.parent / "MathTeachingReview" / "profiles.json"
        if review.is_file():
            entries = json.loads((args.root / "index.json").read_text())["skills"]
            profiles = json.loads(review.read_text())["profiles"]
            indexed = {entry["name"]: entry for entry in entries}
            require(len(profiles) == len(indexed), "review profile count differs from skill catalogue")
            require(len({p["skill_name"] for p in profiles}) == len(profiles), "duplicate review profiles")
            for profile in profiles:
                entry = indexed.get(profile["skill_name"])
                require(entry is not None and profile["skill_sha256"] == entry["sha256"]
                        and profile["skill_version"] == entry["version"],
                        f"review profile snapshot mismatch: {profile['skill_name']}")
    except (ValidationError, OSError) as error:
        print(f"Math skills validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Validated {count} math skills: manifest, metadata, hashes, identities, links and safe paths.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
