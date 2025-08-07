#!/usr/bin/env bash
# Basic integration tests for the pfrog utility. These tests exercise the main
# functionality: pushing new artifacts, handling duplicates, listing contents,
# pulling artifacts back out and working with dry runs and metadata.

set -uo pipefail

PFROG_DIR=$(cd "$(dirname "$0")" && pwd)
PFROG="$PFROG_DIR/pfrog.sh"

fail_count=0

fail() {
    echo "[FAIL] $1" >&2
    fail_count=$((fail_count + 1))
}

pass() {
    echo "[PASS] $1"
}

cleanup() {
    rm -rf "$TMPDIR"
}

trap cleanup EXIT

# Create a temporary NFS root for testing
TMPDIR=$(mktemp -d)

# 1. Push a new directory and verify version 1 is created
test_push_new() {
    # create an artifact directory outside of the NFS root to avoid being listed as a board
    local artifact_dir
    artifact_dir=$(mktemp -d)
    echo "hello" > "$artifact_dir/file.txt"
    local out
    out=$("$PFROG" push --nfs "$TMPDIR" --yes boardA partX "$artifact_dir" 2>/dev/null)
    local expected_pattern='^[0-9a-f]{32}_1\.tar\.gz$'
    if [[ "$out" =~ $expected_pattern ]]; then
        pass "push creates version 1"
    else
        fail "push did not return expected version name (got '$out')"
    fi
    # Check file exists
    if [[ -f "$TMPDIR/boardA/partX/$out" ]]; then
        pass "artifact file stored"
    else
        fail "artifact file not found in NFS store"
    fi
    # Check meta file exists
    if [[ -f "$TMPDIR/boardA/partX/md5_1.meta" ]]; then
        pass "meta file stored"
    else
        fail "meta file missing"
    fi
}

# 2. Push same directory again; should detect duplicate and not create new version
test_push_duplicate() {
    local artifact_dir
    artifact_dir=$(mktemp -d)
    echo "identical" > "$artifact_dir/file.txt"
    local first
    first=$("$PFROG" push --nfs "$TMPDIR" --yes boardB partY "$artifact_dir" 2>/dev/null)
    local second
    second=$("$PFROG" push --nfs "$TMPDIR" --yes boardB partY "$artifact_dir" 2>/dev/null)
    if [[ "$first" == "$second" ]]; then
        pass "duplicate push returns same version"
    else
        fail "duplicate push created new version ('$first' vs '$second')"
    fi
    # Only one tar.gz file should exist
    local count
    count=$(ls "$TMPDIR/boardB/partY"/*.tar.gz | wc -l)
    if [[ "$count" -eq 1 ]]; then
        pass "duplicate push did not add extra file"
    else
        fail "duplicate push added extra file ($count files present)"
    fi
}

# 3. Push modified directory and verify version increments
test_push_increment() {
    local art
    art=$(mktemp -d)
    echo "v1" > "$art/data"
    local v1
    v1=$("$PFROG" push --nfs "$TMPDIR" --yes boardC partZ "$art" 2>/dev/null)
    echo "v2" > "$art/data"
    local v2
    v2=$("$PFROG" push --nfs "$TMPDIR" --yes boardC partZ "$art" 2>/dev/null)
    if [[ "$v1" != "$v2" ]]; then
        pass "modified push created new version"
    else
        fail "modified push did not create new version"
    fi
    # v2 should end with _2.tar.gz
    if [[ "$v2" =~ _2\.tar\.gz$ ]]; then
        pass "version incremented to 2"
    else
        fail "expected version 2, got '$v2'"
    fi
}

# 4. List boards, parts and versions
test_list() {
    # Boards listing
    local boards
    boards=$("$PFROG" list --nfs "$TMPDIR" 2>/dev/null | sort)
    local expected_boards
    expected_boards=$(printf '%s\n' boardA boardB boardC)
    # Compare trimmed versions of the strings to tolerate trailing newlines
    if [[ "$boards" == "$expected_boards" ]]; then
        pass "list boards"
    else
        fail "list boards returned unexpected result"
    fi
    # Parts listing for boardA
    local parts
    parts=$("$PFROG" list --nfs "$TMPDIR" boardA 2>/dev/null | sort)
    if [[ "$parts" == "partX" ]]; then
        pass "list parts for boardA"
    else
        fail "list parts incorrect for boardA"
    fi
    # Versions listing for boardC/partZ
    local versions
    versions=$("$PFROG" list --nfs "$TMPDIR" boardC partZ 2>/dev/null | sort)
    # Should contain two entries; we don't know md5 but ends _1.tar.gz and _2.tar.gz
    local count
    count=$(echo "$versions" | wc -l)
    if [[ "$count" -eq 2 ]]; then
        pass "list versions count correct"
    else
        fail "list versions expected 2 entries"
    fi
}

# 5. Pull latest version and verify MD5 check
test_pull() {
    local art
    art=$(mktemp -d)
    echo "p1" > "$art/a"
    # Push two versions
    "$PFROG" push --nfs "$TMPDIR" --yes boardP partQ "$art" >/dev/null 2>&1
    echo "p2" > "$art/a"
    local newver
    newver=$("$PFROG" push --nfs "$TMPDIR" --yes boardP partQ "$art" 2>/dev/null)
    # Pull latest (should be version 2)
    rm -f "$newver"
    "$PFROG" pull --nfs "$TMPDIR" --yes boardP partQ >/dev/null 2>&1
    if [[ -f "$newver" ]]; then
        pass "pull retrieved file"
    else
        fail "pull did not copy expected file"
    fi
    # Validate md5 from filename
    local expect_md5
    expect_md5=$(echo "$newver" | awk -F '_' '{print $1}')
    local actual_md5
    actual_md5=$(md5sum "$newver" | awk '{print $1}')
    if [[ "$expect_md5" == "$actual_md5" ]]; then
        pass "pull MD5 verified"
    else
        fail "pull MD5 mismatch"
    fi
}

# 6. Dry run does not create files
test_dry_run() {
    local art
    art=$(mktemp -d)
    echo "dry" > "$art/d"
    local out
    out=$("$PFROG" push --nfs "$TMPDIR" --yes --dry boardD partR "$art" 2>/dev/null)
    # Should return _1.tar.gz name but not create file
    local file="$TMPDIR/boardD/partR/$out"
    if [[ ! -e "$file" ]]; then
        pass "dry run did not create file"
    else
        fail "dry run unexpectedly created file"
    fi
}

# 7. Metadata file records commit and tag
test_metadata() {
    local art
    art=$(mktemp -d)
    echo "meta" > "$art/data"
    local out
    out=$("$PFROG" push --nfs "$TMPDIR" --yes --commit abcdef --tag mytag boardM partM "$art" 2>/dev/null)
    # Extract version number from returned filename <md5>_<n>.tar.gz
    local ver
    local base="${out%.tar.gz}"
    ver="${base##*_}"
    local meta_file="$TMPDIR/boardM/partM/md5_${ver}.meta"
    if [[ -f "$meta_file" ]]; then
        # Check commit and tag present
        if grep -q '^commit=abcdef' "$meta_file" && grep -q '^tag=mytag' "$meta_file"; then
            pass "metadata file contains commit and tag"
        else
            fail "metadata file missing commit or tag"
        fi
    else
        fail "metadata file not created"
    fi
}

# 8. Completion script generation
test_completion() {
    local comp
    comp=$("$PFROG" --generate-completion bash)
    if echo "$comp" | grep -q 'complete -F _pfrog_complete pfrog'; then
        pass "completion script generated"
    else
        fail "completion script missing expected function"
    fi
}

main() {
    test_push_new
    test_push_duplicate
    test_push_increment
    test_list
    test_pull
    test_dry_run
    test_metadata
    test_completion
    if [[ "$fail_count" -eq 0 ]]; then
        echo "All tests passed."
    else
        echo "$fail_count test(s) failed." >&2
        exit 1
    fi
}

main "$@"