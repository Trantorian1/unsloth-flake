# Lets Unsloth Studio's bubblewrap sandbox run inside the FHS env.
# unsloth_flake_sandbox.py explains why Studio refuses it unpatched.
#
# Studio runs from a venv that `unsloth studio setup` / the desktop installer
# builds with uv from PyPI, and clears PYTHONPATH when it starts the backend,
# so the patch reaches it through a .pth file in that venv's site-packages.
{pkgs, ...}: let
  # The .pth puts this directory on sys.path and imports the module. Once the
  # store path is garbage-collected, site skips the dangling .pth link.
  sandbox = pkgs.runCommand "unsloth-flake-sandbox" {} ''
    mkdir $out
    substitute ${./sandbox/unsloth_flake_sandbox.py} $out/unsloth_flake_sandbox.py \
      --replace-fail @bwrap@ ${pkgs.bubblewrap}/bin/bwrap
    printf '%s\nimport unsloth_flake_sandbox\n' $out > $out/unsloth_flake_sandbox.pth
  '';
in
  # Sourced by the FHS env's /etc/profile on every launch. A venv created or
  # recreated while the app runs picks the patch up on the next launch.
  ''
    for _unsloth_studio in "$HOME/.unsloth/studio" ''${UNSLOTH_STUDIO_HOME:+"$UNSLOTH_STUDIO_HOME"} ''${STUDIO_HOME:+"$STUDIO_HOME"}; do
      for _unsloth_site in "$_unsloth_studio"/{unsloth_studio,.venv}/lib/python3*/site-packages; do
        [ -d "$_unsloth_site" ] && ln -sfn ${sandbox}/unsloth_flake_sandbox.pth "$_unsloth_site/" 2>/dev/null
      done
    done
    unset _unsloth_studio _unsloth_site
  ''
