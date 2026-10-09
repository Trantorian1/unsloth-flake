# Lets Unsloth Studio's bubblewrap sandbox run inside the FHS env.
# unsloth_flake_sandbox.py explains why Studio refuses it unpatched.
#
# Studio runs from a venv `unsloth studio setup` / the desktop installer
# builds with uv from PyPI, and clears PYTHONPATH when it starts the backend,
# so the patch reaches it through a .pth file in that venv's site-packages.
{pkgs, ...}: let
  module = pkgs.replaceVars ./sandbox/unsloth_flake_sandbox.py {
    bwrap = "${pkgs.bubblewrap}/bin/bwrap";
  };

  # A missing module (garbage-collected store path) is skipped, not an error.
  pth = pkgs.writeText "unsloth_flake_sandbox.pth" ''
    import importlib.util as u, os, sys; p = "${module}"; s = os.path.isfile(p) and u.spec_from_file_location("unsloth_flake_sandbox", p); m = s and u.module_from_spec(s); m and (sys.modules.setdefault("unsloth_flake_sandbox", m), s.loader.exec_module(m))
  '';
in {
  inherit module pth;

  # Sourced by the FHS env's /etc/profile on every launch. A venv created or
  # recreated while the app runs picks the patch up on the next launch.
  profile = ''
    for _unsloth_studio in "$HOME/.unsloth/studio" ''${UNSLOTH_STUDIO_HOME:+"$UNSLOTH_STUDIO_HOME"} ''${STUDIO_HOME:+"$STUDIO_HOME"}; do
      for _unsloth_site in "$_unsloth_studio"/{unsloth_studio,.venv}/lib/python3*/site-packages; do
        if [ -d "$_unsloth_site" ]; then
          ln -sfn ${pth} "$_unsloth_site/unsloth_flake_sandbox.pth" 2>/dev/null || true
        fi
      done
    done
    unset _unsloth_studio _unsloth_site
  '';
}
