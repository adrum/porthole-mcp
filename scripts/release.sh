#!/bin/sh
# Cut a release: set the npm package's version, commit it, and tag it. Pushing
# the tag runs .github/workflows/release.yml, which tests, publishes to npm and
# creates the GitHub release; the tag is also the Swift package's version.
#
#   scripts/release.sh 0.2.0          a release
#   scripts/release.sh 0.2.0-beta.1   a prerelease (npm tag "next")
set -eu
cd "$(dirname "$0")/.."

version=${1:-}
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: scripts/release.sh <version>, like 0.2.0 or 0.2.0-beta.1" >&2; exit 2 ;;
esac
tag="v$version"

if [ -n "$(git status --porcelain)" ]; then
  echo "commit or stash your changes first" >&2
  exit 1
fi
if [ "$(git rev-parse --abbrev-ref HEAD)" != main ]; then
  echo "releases are cut from main" >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "$tag already exists" >&2
  exit 1
fi

# The same checks CI runs, so a release doesn't fail after the tag is pushed.
(cd apple && swift test)
(cd expo && npm ci && npm test)

current=$(node -p 'require("./expo/package.json").version')
if [ "$current" != "$version" ]; then
  (cd expo && npm version "$version" --no-git-tag-version >/dev/null)
  git add expo/package.json expo/package-lock.json
  git commit -m "Release $version"
fi
git tag -a "$tag" -m "Porthole $version"

echo "tagged $tag. Publish it with:"
echo "  git push origin main $tag"
