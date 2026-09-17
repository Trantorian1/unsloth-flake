# Point package.json's `overrides` at the same store tarballs importNpmLock
# picked for the dependencies themselves.
#
# Input is importNpmLock's rewritten package.json; --slurpfile lock supplies its
# rewritten package-lock.json. For each override, find the lock entry for the
# package it targets whose version is the one the override asks for, and use
# that entry's `file:` path. An override with no match in the lock is left as
# it is.

def target($key):
  if ($key | startswith("@")) then
    (if ($key[1:] | contains("@")) then "@" + ($key[1:] | split("@")[0]) else $key end)
  else
    (if ($key | contains("@")) then ($key | split("@")[0]) else $key end)
  end;

($lock[0].packages) as $pkgs
| if has("overrides") then
    .overrides |= with_entries(
      target(.key) as $name
      | .value as $want
      | ( $pkgs
          | to_entries
          | map(select(
              (.key | endswith("node_modules/" + $name))
              and (.value.version == $want)
              and ((.value.resolved // "") | startswith("file:"))))
          | first ) as $hit
      | .value = (if $hit == null then $want else $hit.value.resolved end)
    )
  else . end
