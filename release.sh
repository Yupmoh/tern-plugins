#!/bin/sh
# Release a plugin: ./release.sh <plugin> <version>, e.g. ./release.sh kai 0.3.0
# Sets the version in <plugin>/plugin.toml (what Tern and the sidebar show), commits it and tags
# <plugin>-v<version>. Push afterwards with: git push && git push --tags
set -eu
plugin=${1:?usage: ./release.sh <plugin> <version>}
version=${2:?usage: ./release.sh <plugin> <version>}
cd "$(dirname "$0")"
manifest="$plugin/plugin.toml"
[ -f "$manifest" ] || { echo "no $manifest" >&2; exit 1; }
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version must be X.Y.Z" >&2; exit 1; }
tag="$plugin-v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "$tag already exists" >&2; exit 1; }
sed -i.bak "s/^version = \".*\"/version = \"$version\"/" "$manifest" && rm "$manifest.bak"
git add "$manifest"
git diff --cached --quiet || git commit -qm "$plugin $version"
git tag -a "$tag" -m "$plugin $version"
echo "tagged $tag"
