#!/usr/bin/env python3
"""Validate and stage a complete public distribution before replacing local artifacts."""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import tarfile
import tempfile
import zipapp

root = Path(__file__).resolve().parent.parent
version = (root / 'VERSION').read_text().strip()
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?', version):
    raise SystemExit('Invalid VERSION')
dist = root / 'dist'
private_files = shutil.ignore_patterns('.local', '__pycache__', '*.pyc', '*.local.yaml', '.env*', 'secrets.env')
# This reviewed source file is the explicit public-example allowlist.
public_examples = json.loads((root / 'examples/catalog.json').read_text())
example_names = [entry['path'] for entry in public_examples]
if len(set(example_names)) != len(example_names) or any(not re.fullmatch(r'[a-z0-9][a-z0-9-]*', name) for name in example_names):
    raise SystemExit('Invalid public example catalog')


def exclusions(directory, names):
    excluded = set(private_files(directory, names))
    for name in set(names) - excluded:
        if (Path(directory) / name).is_symlink():
            raise SystemExit('Symlinks are not allowed in distributed sources')
    return excluded


def copy_file(source, destination):
    if source.is_symlink():
        raise SystemExit('Symlinks are not allowed in distributed sources')
    shutil.copy(source, destination)


def copy_tree(source, destination):
    if not source.is_dir() or source.is_symlink():
        raise SystemExit('Distributed source directory missing or symlinked: ' + source.name)
    shutil.copytree(source, destination, ignore=exclusions)


def checksum(path):
    path.with_name(path.name + '.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n')


# Stage on the output filesystem so publication uses rename, not partial copies.
with tempfile.TemporaryDirectory(prefix='.ctrl-build-', dir=root) as directory:
    temporary = Path(directory)
    source = temporary / 'source'
    source.mkdir()
    release = temporary / 'release'
    release.mkdir()
    code_path = root / 'src/ctrl.py'
    if code_path.is_symlink():
        raise SystemExit('Runner source must not be symlinked')
    code = code_path.read_text().replace('VERSION = "0.5.0-dev"', f'VERSION = "{version}"')
    (source / '__main__.py').write_text(code)
    for name in ('operations', 'docs'):
        copy_tree(root / name, source / name)
    copy_file(root / 'SKILL.md', source / 'SKILL.md')
    (source / 'examples').mkdir()
    (source / 'examples/catalog.json').write_text(json.dumps(public_examples, indent=2) + '\n')
    zipapp.create_archive(source, release / 'ctrl', interpreter='/usr/bin/env python3', compressed=True)
    (release / 'ctrl').chmod(0o755)
    checksum(release / 'ctrl')
    package = temporary / ('ctrl-' + version)
    package.mkdir()
    for name in ('ctrl', 'ctrl.sha256'):
        copy_file(release / name, package / name)
    for name in ('README.md', 'VERSION', 'install.sh'):
        copy_file(root / name, package / name)
    copy_file(source / 'SKILL.md', package / 'SKILL.md')
    for name in ('docs', 'operations'):
        copy_tree(source / name, package / name)
    copy_tree(root / 'completions', package / 'completions')
    (package / 'examples').mkdir()
    copy_file(source / 'examples/catalog.json', package / 'examples/catalog.json')
    copy_file(root / 'examples/README.md', package / 'examples/README.md')
    for name in example_names:
        copy_tree(root / 'examples' / name, package / 'examples' / name)
    archive = release / f'ctrl-{version}.tar.gz'
    with tarfile.open(archive, 'w:gz') as output:
        output.add(package, arcname=package.name)
    checksum(archive)
    # Validation and all archive work has succeeded. A validation error above
    # leaves the previous executable, archive, and checksums untouched.
    dist.mkdir(exist_ok=True)
    for path in release.iterdir():
        os.replace(path, dist / path.name)
print(f'Built dist/ctrl and dist/ctrl-{version}.tar.gz')
