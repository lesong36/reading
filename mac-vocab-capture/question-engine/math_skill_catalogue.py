"""Local catalogue validation and lossless bounded pages, not model coverage claims.

Inventory is distinct from a single model working set. Pages contain exact normalized
snapshots, never summaries or truncated bodies. Callers must inspect every page and
reconcile cross-page combinations before declaring an exercise uncovered.
"""
import hashlib
import json

from math_skills import SkillError, snapshots_for

REQUEST_BYTES = 300_000
MAX_ENTRIES = 512


def snapshot_bytes(snapshot):
    return json.dumps(dict(snapshot), ensure_ascii=False).encode("utf-8")


def catalogue_for(value):
    """Validate complete local inventory; each individual must remain serviceable."""
    if not isinstance(value, list) or len(value) > MAX_ENTRIES:
        raise SkillError("skillsInvalid")
    rows, identifiers, names = [], set(), set()
    for item in value:
        row = snapshots_for([item])[0]
        identifier, name = row["id"], row.get("skill_name")
        if identifier in identifiers or (name is not None and name in names):
            raise SkillError("skillsInvalid")
        identifiers.add(identifier)
        if name is not None:
            names.add(name)
        rows.append(row)
    return tuple(rows)


def catalogue_pages(snapshots):
    """Pack complete normalized rows under the existing per-request byte ceiling."""
    pages, current, size = [], [], 0
    for row in snapshots:
        count = len(snapshot_bytes(row))
        if count > REQUEST_BYTES:
            raise SkillError("skillsTooLarge")
        if current and size + count > REQUEST_BYTES:
            pages.append(tuple(current))
            current, size = [], 0
        current.append(row)
        size += count
    if current:
        pages.append(tuple(current))
    return tuple(pages)


def catalogue_fingerprint(snapshots):
    """Bind exact bodies, policies, versions and order for future scan receipts."""
    digest = hashlib.sha256()
    for row in snapshots:
        data = snapshot_bytes(row)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()
