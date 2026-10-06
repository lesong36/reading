"""Place Python data in Resources and sign actual nested code before the app."""

import os
from pathlib import Path
import subprocess
import sys

MACH_O = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def is_code(path):
    with path.open("rb") as file:
        return file.read(4) in MACH_O


def relocate(path, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    path.rename(destination)
    path.symlink_to(os.path.relpath(destination, path.parent), target_is_directory=destination.is_dir())


def sign(app, identity):
    runtime = app / "Contents/Helpers/QuestionEngine/runtime"
    resources = app / "Contents/Resources"
    # Apple treats data directories in code locations as nested bundles. Preserve
    # PyInstaller's lookup layout with links to resources inside the same app.
    for metadata in runtime.glob("*.dist-info"):
        if not metadata.is_symlink():
            relocate(metadata, resources / "QuestionEngineMetadata" / metadata.name)
    for path in runtime.rglob("*"):
        if path.is_file() and not path.is_symlink() and not is_code(path):
            relocate(path, resources / "QuestionEngineData" / path.relative_to(runtime))
    subprocess.run(["xattr", "-cr", str(app)], check=True)
    count = 0
    for path in (app / "Contents/Helpers").rglob("*"):
        if path.is_file() and not path.is_symlink() and is_code(path):
            subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(path)], check=True)
            count += 1
    subprocess.run(["xattr", "-cr", str(app)], check=True)
    # --deep signing misidentifies Python metadata; nested code is already signed.
    subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(f"Signed {count} nested Mach-O files; deep strict verification passed.")


if __name__ == "__main__":
    sign(Path(sys.argv[1]).resolve(), sys.argv[2])
