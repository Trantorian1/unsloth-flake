"""Let Unsloth Studio's bubblewrap backend run inside the unsloth-flake FHS env.

Imported from a .pth file in the Studio venv (see ../sandbox.nix); patches
`core.inference.sandbox_linux` as it is imported, and nothing else.

Studio only accepts a bwrap that is root-owned, with root-owned parents that
are not group/other writable. Inside the FHS env that can never hold:
buildFHSEnv runs in an unprivileged user namespace where host uid 0 is
unmapped, so every root-owned file shows up as nobody (65534).

What Studio wants is a bwrap its user cannot replace, so where Studio refuses
this falls back to a pinned store bwrap that passes that test. The FHS /usr,
/lib and /bin are symlinks into /nix/store, which Studio only binds into the
tool sandbox when its own interpreter lives there (uv's does not), so the
fallback also adds /nix/store to the read-only system roots.
"""

import importlib.abc
import importlib.machinery
import os
import stat
import sys

BWRAP = "@bwrap@"
NIX_STORE = "/nix/store"
TARGET = "core.inference.sandbox_linux"


def _sealed(path: str) -> bool:
    """Whether this user cannot replace `path`, nor any directory up to the store."""
    try:
        if not stat.S_ISREG(os.lstat(path).st_mode) or not os.access(path, os.X_OK):
            return False
        while True:
            if os.lstat(path).st_uid == os.geteuid() or os.access(path, os.W_OK):
                return False
            if path == NIX_STORE:
                return True
            path = os.path.dirname(path)
    except OSError:
        return False


def _patch(module) -> None:
    trusted = module._trusted_bwrap_path
    unavailable = module.SandboxUnavailableError

    def _trusted_bwrap_path() -> str:
        try:
            return trusted()
        except unavailable:
            if not _sealed(BWRAP):
                raise
            if NIX_STORE not in module._SYSTEM_ROOTS:
                module._SYSTEM_ROOTS += (NIX_STORE,)
            return BWRAP

    module._trusted_bwrap_path = _trusted_bwrap_path


class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target = None):
        if fullname != TARGET and not fullname.endswith("." + TARGET):
            return None
        spec = importlib.machinery.PathFinder.find_spec(fullname, path, target)
        if spec is None or spec.loader is None:
            return spec
        exec_module = spec.loader.exec_module

        def _exec_module(module):
            exec_module(module)
            try:
                _patch(module)
            except AttributeError:
                pass  # Upstream changed shape: leave its own behaviour alone.

        spec.loader.exec_module = _exec_module
        return spec


sys.meta_path.insert(0, _Finder())
