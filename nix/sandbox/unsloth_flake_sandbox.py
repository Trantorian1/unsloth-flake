"""Let Unsloth Studio's bubblewrap backend run inside the unsloth-flake FHS env.

Loaded from a .pth file in the Studio venv (see ../sandbox.nix). It patches
`core.inference.sandbox_linux` as it is imported, and changes nothing else.

Studio only accepts a bwrap that is root-owned, with every parent directory
root-owned and not group/other writable. Inside the FHS env that can never
hold: buildFHSEnv runs in an unprivileged user namespace, where host uid 0 is
unmapped and every root-owned file shows up as nobody (65534). /nix/store is
also group-writable by nixbld, so a store bwrap fails even outside the FHS.

The guarantee Studio wants is that the user it runs as cannot replace the
binary. A pinned store path gives that when the store is not writable by this
user, which is what `_sealed` checks. Studio's own check still runs first;
the pinned bwrap is only used where it refuses.

The FHS /usr, /lib and /bin are symlink farms into /nix/store, and Studio
binds /nix/store into the tool sandbox only when its interpreter lives there
(not true of uv's managed Python), so launches through the pinned bwrap also
bind /nix/store read-only, as Studio itself does on NixOS.
"""

import dataclasses
import importlib.abc
import os
import stat
import sys

BWRAP = "@bwrap@"
NIX_STORE = "/nix/store"
TARGET = "core.inference.sandbox_linux"


def _replaceable(path: str) -> bool:
    try:
        info = os.lstat(path)
    except OSError:
        return True
    return info.st_uid == os.geteuid() or os.access(path, os.W_OK)


def _sealed(path: str) -> bool:
    """Whether `path` is an executable in the store that this user cannot replace."""
    if os.path.realpath(path) != path or os.path.dirname(path) == path:
        return False
    if not path.startswith(NIX_STORE + "/"):
        return False
    try:
        info = os.lstat(path)
        store = os.lstat(NIX_STORE)
    except OSError:
        return False
    if not stat.S_ISREG(info.st_mode) or not os.access(path, os.X_OK):
        return False
    parent = path
    while parent != NIX_STORE:
        if _replaceable(parent):
            return False
        parent = os.path.dirname(parent)
    # A sticky store only lets its owner remove other users' entries.
    if _replaceable(NIX_STORE) and not (store.st_mode & stat.S_ISVTX and store.st_uid != os.geteuid()):
        return False
    return True


def _bind_store(launch):
    """Bind /nix/store read-only alongside the system roots of a launch through `BWRAP`."""
    argv = list(launch.argv)
    if not argv or argv[0] != BWRAP or not os.path.isdir(NIX_STORE):
        return launch
    end = argv.index("--") if "--" in argv else len(argv)
    options = argv[:end]
    for i in range(len(options) - 2):
        if options[i] in ("--ro-bind", "--ro-bind-try", "--bind") and options[i + 2] == NIX_STORE:
            return launch
    anchors = [i for i, arg in enumerate(options) if arg in ("--ro-bind-try", "--remount-ro")]
    if not anchors:
        return launch
    argv[anchors[0]:anchors[0]] = ["--ro-bind", NIX_STORE, NIX_STORE]
    try:
        launch.argv = tuple(argv)
    except AttributeError:  # a frozen dataclass
        launch = dataclasses.replace(launch, argv = tuple(argv))
    return launch


def _patch(module) -> None:
    trusted = getattr(module, "_trusted_bwrap_path", None)
    prepare = getattr(module, "prepare", None)
    unavailable = getattr(module, "SandboxUnavailableError", None)
    if not (callable(trusted) and callable(prepare) and isinstance(unavailable, type)):
        # Upstream changed shape: leave its own behaviour alone.
        return

    def _trusted_bwrap_path() -> str:
        try:
            return trusted()
        except unavailable:
            if _sealed(BWRAP):
                return BWRAP
            raise

    def _prepare(plan):
        return _bind_store(prepare(plan))

    _trusted_bwrap_path.__doc__ = trusted.__doc__
    _prepare.__doc__ = prepare.__doc__
    module._trusted_bwrap_path = _trusted_bwrap_path
    module.prepare = _prepare


class _Finder(importlib.abc.MetaPathFinder):
    # site can run the .pth twice (lib64 -> lib), each time with a fresh class.
    unsloth_flake_sandbox = True

    def find_spec(self, fullname, path, target = None):
        if fullname != TARGET and not fullname.endswith("." + TARGET):
            return None
        for finder in sys.meta_path:
            if getattr(finder, "unsloth_flake_sandbox", False) or not hasattr(finder, "find_spec"):
                continue
            spec = finder.find_spec(fullname, path, target)
            if spec is not None:
                break
        else:
            return None
        loader = spec.loader
        exec_module = getattr(loader, "exec_module", None)
        if exec_module is None:
            return spec

        def _exec_module(module):
            exec_module(module)
            _patch(module)

        loader.exec_module = _exec_module
        return spec


if not any(getattr(finder, "unsloth_flake_sandbox", False) for finder in sys.meta_path):
    sys.meta_path.insert(0, _Finder())
