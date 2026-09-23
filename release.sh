#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
PREFIX="${PREFIX:-v}"
DEFAULT_BUMP="patch"

# -----------------------------
# Helpers
# -----------------------------
usage() {
  cat <<'EOF'
usage: ./release.sh [major|minor|patch] [-y|--yes] [--skip-checks]

Creates a signed annotated tag from main/master and pushes it to origin.

Options:
  major|minor|patch   Version bump type (default: patch)
  -y, --yes           Skip confirmation prompt
      --skip-checks   Tag without running the test suite first
  -h, --help          Show this help
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# -----------------------------
# Parse args
# -----------------------------
BUMP="$DEFAULT_BUMP"
ASSUME_YES="false"
SKIP_CHECKS="false"

while (($# > 0)); do
  case "$1" in
    major|minor|patch)
      BUMP="$1"
      ;;
    -y|--yes)
      ASSUME_YES="true"
      ;;
    --skip-checks)
      SKIP_CHECKS="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: '$1'"
      ;;
  esac
  shift
done

# -----------------------------
# Validate environment
# -----------------------------
require_cmd git

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "working tree has uncommitted changes — commit or stash first"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" && "$BRANCH" != "master" ]]; then
  die "releases must be created from main/master (current: $BRANCH)"
fi

git remote get-url origin >/dev/null 2>&1 || die "remote 'origin' is not configured"

# Keep local tags up to date before calculating the next version.
git fetch --tags --quiet origin || die "failed to fetch tags from origin"

# Optional but useful: ensure local branch is not behind upstream.
UPSTREAM_REF=""
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  UPSTREAM_REF="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
  LOCAL_SHA="$(git rev-parse HEAD)"
  UPSTREAM_SHA="$(git rev-parse '@{u}')"
  BASE_SHA="$(git merge-base HEAD '@{u}')"

  # Only "behind" used to be rejected, so a diverged or unpushed branch
  # sailed through and tagged a commit that origin's branch does not
  # contain — the tag push carries the objects, so nothing fails loudly,
  # but the release is built from a commit nobody can find on main.
  if [[ "$LOCAL_SHA" != "$UPSTREAM_SHA" ]]; then
    if [[ "$LOCAL_SHA" == "$BASE_SHA" ]]; then
      die "local branch is behind $UPSTREAM_REF — pull/rebase first"
    elif [[ "$UPSTREAM_SHA" == "$BASE_SHA" ]]; then
      die "local branch is ahead of $UPSTREAM_REF — push first, or the tag points at a commit that is not on the remote branch"
    else
      die "local branch has diverged from $UPSTREAM_REF — reconcile before releasing"
    fi
  fi
fi

# -----------------------------
# Validate signing config
# -----------------------------
SIGNING_FORMAT="$(git config --get gpg.format || true)"
SIGNING_KEY="$(git config --get user.signingkey || true)"
USER_EMAIL="$(git config --get user.email || true)"

if [[ -z "$USER_EMAIL" ]]; then
  die "git user.email is not configured"
fi

if [[ -z "$SIGNING_KEY" ]]; then
  die "git signing is not configured: missing user.signingkey"
fi

case "${SIGNING_FORMAT:-openpgp}" in
  ssh)
    [[ -f "$SIGNING_KEY" ]] || die "SSH signing key file does not exist: $SIGNING_KEY"

    ALLOWED_SIGNERS="$(git config --get gpg.ssh.allowedSignersFile || true)"
    if [[ -z "$ALLOWED_SIGNERS" ]]; then
      die "gpg.ssh.allowedSignersFile is not configured"
    fi
    [[ -f "$ALLOWED_SIGNERS" ]] || die "gpg.ssh.allowedSignersFile does not exist: $ALLOWED_SIGNERS"
    ;;
  openpgp|x509)
    :
    ;;
  *)
    die "unsupported gpg.format: ${SIGNING_FORMAT}"
    ;;
esac

# -----------------------------
# Find last version tag
# -----------------------------
# Pick the newest tag that is exactly `<prefix>MAJOR.MINOR.PATCH`. The glob
# alone is not enough: `v[0-9]*.[0-9]*.[0-9]*` also matches `v1.2.3-rc1`,
# which then sorts first and fails the strict parse below — one pre-release
# tag used to wedge every subsequent release.
LAST_TAG=""
while IFS= read -r candidate; do
  [[ "$candidate" =~ ^"$PREFIX"[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
  LAST_TAG="$candidate"
  break
done < <(git tag --list "${PREFIX}*" --sort=-v:refname)

if [[ -z "$LAST_TAG" ]]; then
  LAST_TAG="${PREFIX}0.0.0"
  info "No previous tags found, starting from ${LAST_TAG}"
else
  info "Last tag: $LAST_TAG"
fi

VERSION="${LAST_TAG#"$PREFIX"}"
if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  die "last tag does not match semantic version format: $LAST_TAG"
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"

# -----------------------------
# Collect commits since last tag
# -----------------------------
if git rev-parse "$LAST_TAG" >/dev/null 2>&1; then
  RANGE="${LAST_TAG}..HEAD"
else
  RANGE="HEAD"
fi

COMMITS="$(git log "$RANGE" --pretty=format:'- %h %s')"
[[ -n "$COMMITS" ]] || die "no new commits since $LAST_TAG — nothing to release"

# -----------------------------
# Compute next version
# -----------------------------
case "$BUMP" in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
esac

NEW_TAG="${PREFIX}${MAJOR}.${MINOR}.${PATCH}"

if git rev-parse "$NEW_TAG" >/dev/null 2>&1; then
  die "tag $NEW_TAG already exists locally"
fi

if git ls-remote --tags origin "refs/tags/${NEW_TAG}" | grep -q .; then
  die "tag $NEW_TAG already exists on origin"
fi

# -----------------------------
# Pre-flight checks
# -----------------------------
# The release workflow fires on the tag push and only builds; a failure
# there leaves a published tag with no artifacts and a version number that
# cannot be reused. Cheaper to find out here.
if [[ "$SKIP_CHECKS" == "true" ]]; then
  info "Skipping pre-flight checks (--skip-checks)"
elif ! command -v zig >/dev/null 2>&1; then
  die "zig not found — install it, or pass --skip-checks to tag anyway"
else
  info "Running tests..."
  zig build test >/dev/null || die "tests failed — refusing to tag $NEW_TAG"

  # ztabb links SDL3, which the release workflow gets from the runner's own
  # Homebrew, so there is nothing to cross-compile against here. What can be
  # checked locally is the host release build and the bundle, and the bundle
  # is what a release actually ships: it renders the icon, runs iconutil,
  # rewrites the SDL load path and re-signs, any of which can break alone.
  info "Building release..."
  zig build -Doptimize=ReleaseFast >/dev/null \
    || die "release build failed — refusing to tag $NEW_TAG"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    info "Building app bundle..."
    zig build bundle -Doptimize=ReleaseFast >/dev/null \
      || die "bundle failed — refusing to tag $NEW_TAG"

    bin="zig-out/ztabb.app/Contents/MacOS/ztabb"
    [[ -f "zig-out/ztabb.app/Contents/Resources/ztabb.icns" ]] \
      || die "bundle has no icon — refusing to tag $NEW_TAG"
    # A Homebrew path here means the shipped app breaks the moment the
    # formula is upgraded or removed on the user's machine.
    if otool -L "$bin" | grep -q /opt/homebrew; then
      otool -L "$bin" >&2
      die "bundle links a Homebrew path — refusing to tag $NEW_TAG"
    fi
    codesign -v zig-out/ztabb.app \
      || die "bundle is not signed — refusing to tag $NEW_TAG"
  fi

  info "Pre-flight checks passed"
fi

# -----------------------------
# Preview and confirm
# -----------------------------
echo ""
echo "  bump:      $BUMP"
echo "  previous:  $LAST_TAG"
echo "  new tag:   $NEW_TAG"
echo "  branch:    $BRANCH"
echo "  signing:   ${SIGNING_FORMAT:-openpgp}"
echo "  key:       $SIGNING_KEY"
if [[ -n "$UPSTREAM_REF" ]]; then
  echo "  upstream:  $UPSTREAM_REF"
fi
echo ""
echo "Commits:"
echo "$COMMITS"
echo ""

if [[ "$ASSUME_YES" != "true" ]]; then
  # Without a terminal `read` hits EOF, and `set -e` then killed the script
  # with no output and a bare exit 1 — indistinguishable from a real failure.
  if [[ ! -t 0 ]]; then
    die "not running interactively — pass --yes to confirm $NEW_TAG"
  fi
  read -r -p "Create and push signed tag $NEW_TAG? [y/N] " CONFIRM
  # `${CONFIRM,,}` is bash 4+, and macOS still ships bash 3.2 as /bin/bash —
  # which `#!/usr/bin/env bash` picks up unless Homebrew's bash is first on
  # PATH. It parsed fine and then died with "bad substitution" at the prompt,
  # after the full pre-flight had already run. Matching the cases directly
  # keeps this working on 3.2 and on the macOS CI runner.
  case "$CONFIRM" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
fi

# -----------------------------
# Create signed tag
# -----------------------------
TAG_MESSAGE="$NEW_TAG

Changes:
$COMMITS
"

git tag -s "$NEW_TAG" -m "$TAG_MESSAGE"

# Verify locally before pushing.
git tag -v "$NEW_TAG" >/dev/null 2>&1 || {
  git tag -d "$NEW_TAG" >/dev/null 2>&1 || true
  die "local signature verification failed for $NEW_TAG"
}

# -----------------------------
# Push tag
# -----------------------------
if ! git push origin "refs/tags/${NEW_TAG}"; then
  echo ""
  echo "warning: failed to push tag $NEW_TAG"
  echo "the signed tag still exists locally"
  echo "you can retry with:"
  echo "  git push origin refs/tags/${NEW_TAG}"
  exit 1
fi

echo ""
echo "✅ Released $NEW_TAG"
echo ""
echo "Build with:"
echo "  zig build bundle -Doptimize=ReleaseFast"
