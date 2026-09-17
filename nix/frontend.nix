# Unsloth Studio's Vite/React frontend, built offline from studio/frontend.
#
# Upstream builds this with `./build.sh`, which runs `bun install || npm install`
# followed by `npm run build`. Neither is usable in a Nix sandbox, so the npm
# tree is resolved from studio/frontend/package-lock.json with `importNpmLock`.
# That reuses the `integrity` hashes already in the lockfile, which is why this
# derivation carries no `npmDepsHash` to regenerate whenever upstream bumps a
# dependency.
{
  lib,
  stdenv,
  importNpmLock,
  jq,
  nodejs_22,
  runCommand,
  autoPatchelfHook,
  unsloth-src,
  version,
}: let
  frontendRoot = "${unsloth-src}/studio/frontend";

  # package.json carries an `overrides` block, and two of its entries name
  # packages that are also direct dependencies (@tanstack/react-router and
  # remend). importNpmLock rewrites `dependencies` to `file:` store paths but
  # leaves `overrides` at its version string, so npm sees the two disagree about
  # the same package and refuses the install with EOVERRIDE.
  #
  # Deleting the block is not an option, because it is load-bearing: streamdown
  # depends on remend 1.3.0 and the override is what pulls the tree up to 1.3.1.
  # Without it npm judges the locked tree unsatisfying and goes to the registry
  # for remend, which fails in the sandbox with ENOTCACHED. So instead point
  # every override at the same store tarball importNpmLock already chose. That
  # removes the disagreement and keeps the forcing intact, and needs no network
  # because the value is a path rather than a range to resolve.
  rawNpmDeps = importNpmLock {npmRoot = frontendRoot;};

  npmDeps =
    runCommand "unsloth-studio-frontend-npm-deps" {
      nativeBuildInputs = [jq];
    } ''
      mkdir -p $out
      cp ${rawNpmDeps}/package-lock.json $out/package-lock.json
      jq --slurpfile lock ${rawNpmDeps}/package-lock.json \
        -f ${./fix-npm-overrides.jq} \
        ${rawNpmDeps}/package.json > $out/package.json
    '';
in
  stdenv.mkDerivation {
    pname = "unsloth-studio-frontend";
    inherit version;

    src = unsloth-src;

    # Adjust sourceRoot after unpacking rather than naming the store path, which
    # changes on every `nix flake update unsloth-src`.
    postUnpack = ''
      sourceRoot="$sourceRoot/studio/frontend"
    '';

    postPatch = ''
      # studio/frontend/.npmrc pins the registry and sets min-release-age=7, a
      # supply-chain cooldown that only means anything when npm is resolving
      # versions against a live registry. Here every dependency is already a fixed
      # store path chosen by package-lock.json's integrity hashes, so the file can
      # only push npm towards network access the sandbox does not have.
      rm -f .npmrc
    '';

    inherit npmDeps;

    # npm audits on install unless told not to, and an audit wants the registry.
    npmFlags = ["--no-audit" "--no-fund" "--offline"];

    nativeBuildInputs = [
      nodejs_22
      importNpmLock.npmConfigHook
      # vite 8 pulls in rolldown, tailwind v4 oxide, lightningcss and skia as
      # prebuilt .node objects. They are linked against a glibc that is not on a
      # Nix host's default loader path, so they have to be rewritten before the
      # build loads them.
      autoPatchelfHook
    ];

    buildInputs = [
      stdenv.cc.cc.lib
    ];

    # autoPatchelfHook only fires in postFixup, which is far too late: these
    # objects are dlopen'd during the build itself.
    preBuild = ''
      # The musl variants sit beside the gnu ones and cannot resolve against
      # glibc; drop them so autoPatchelf does not fail on them. Nothing loads
      # them on this platform.
      find node_modules -type d -name '*-musl' -prune -exec rm -rf {} +

      # --ignore-missing because node_modules also carries prebuilt objects that
      # this build never loads (skia, for one) and whose own dependencies are not
      # worth dragging in. A library that is genuinely needed and genuinely
      # missing still fails, at the point the build tries to load it.
      autoPatchelf --ignore-missing node_modules
    '';

    buildPhase = ''
      runHook preBuild

      # `tsc -b && vite build`, as studio/package.json defines it.
      npm run build

      runHook postBuild
    '';

    # build.sh refuses to package a dist whose largest stylesheet is under 100KB,
    # because a Tailwind oxide scan blocked by a stray .gitignore silently emits a
    # near-empty stylesheet instead of failing. Keep that gate: the failure mode is
    # an app that renders unstyled, which is easy to miss in a headless build.
    doCheck = true;
    checkPhase = ''
      runHook preCheck

      # -printf rather than `wc -c`, whose trailing "total" line would otherwise
      # be the largest number here and let the sum pass for a single file.
      maxCssSize=$(find dist/assets -name '*.css' -printf '%s\n' | sort -n | tail -1)
      if [ -z "$maxCssSize" ]; then
        echo "ERROR: the frontend build emitted no CSS into dist/assets." >&2
        exit 1
      fi
      if [ "$maxCssSize" -lt 100000 ]; then
        echo "ERROR: largest stylesheet is only $((maxCssSize / 1024))KB (expected >100KB)." >&2
        echo "Tailwind probably did not scan the .tsx sources." >&2
        exit 1
      fi
      echo "Frontend CSS validated ($maxCssSize bytes)"

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall

      cp -r dist $out

      runHook postInstall
    '';

    meta = {
      description = "Prebuilt web assets for Unsloth Studio";
      homepage = "https://unsloth.ai/";
      license = lib.licenses.agpl3Only;
      platforms = ["x86_64-linux"];
    };
  }
