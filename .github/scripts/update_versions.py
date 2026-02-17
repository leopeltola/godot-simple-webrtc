#!/usr/bin/env python3
"""Update version strings in plugin.cfg and main.py to match git tag."""

import re
import sys
from pathlib import Path


def update_plugin_cfg(version: str) -> None:
    """Update version in godot/addons/simple-webrtc/plugin.cfg"""
    plugin_cfg = Path("godot/addons/simple-webrtc/plugin.cfg")

    if not plugin_cfg.exists():
        print(f"Error: {plugin_cfg} not found", file=sys.stderr)
        sys.exit(1)

    content = plugin_cfg.read_text(encoding="utf-8")

    # Replace version line
    updated = re.sub(
        r'^version="[^"]*"', f'version="{version}"', content, flags=re.MULTILINE
    )

    plugin_cfg.write_text(updated, encoding="utf-8")
    print(f"✓ Updated {plugin_cfg} to version {version}")


def update_main_py(version: str) -> None:
    """Update __version__ in server/main.py"""
    main_py = Path("server/main.py")

    if not main_py.exists():
        print(f"Error: {main_py} not found", file=sys.stderr)
        sys.exit(1)

    content = main_py.read_text(encoding="utf-8")

    # Check if __version__ exists
    if "__version__" in content:
        # Replace existing __version__
        updated = re.sub(
            r'^__version__ = "[^"]*"',
            f'__version__ = "{version}"',
            content,
            flags=re.MULTILINE,
        )
    else:
        # Add __version__ after imports, before load_dotenv()
        updated = re.sub(
            r"(from dotenv import load_dotenv\n)",
            f'\\1\n__version__ = "{version}"\n',
            content,
        )

    # Update FastAPI version parameter
    updated = re.sub(
        r'(app = FastAPI\([^)]*version=")[^"]*(")', f"\\1{version}\\2", updated
    )

    main_py.write_text(updated, encoding="utf-8")
    print(f"✓ Updated {main_py} to version {version}")


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: update_versions.py <version>", file=sys.stderr)
        print("Example: update_versions.py 0.4.0", file=sys.stderr)
        sys.exit(1)

    # Remove 'v' prefix if present
    version = sys.argv[1].lstrip("v")

    # Validate semver format
    if not re.match(r"^\d+\.\d+\.\d+$", version):
        print(f"Error: Invalid semver format: {version}", file=sys.stderr)
        print("Expected format: X.Y.Z (e.g., 0.4.0)", file=sys.stderr)
        sys.exit(1)

    update_plugin_cfg(version)
    update_main_py(version)

    print(f"\n✓ All versions updated to {version}")


if __name__ == "__main__":
    main()
