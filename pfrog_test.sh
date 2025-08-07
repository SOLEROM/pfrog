#!/usr/bin/env bash
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

TMPDIR=$(mktemp -d)

test_push_new() {
    local artifact_dir
    artifact_dir=$(mktemp -d)
    echo "hello" > "$artifact_dir/file.txt"
    local out
    out=$("$PFROG" push --nfs "$TMPDIR" --yes boardA partX "$artifact_dir" 2>/dev/null)
    if [[ "$out" =~ ^[0-9a-f]{32}_1\.tar\.gz$ ]]; then
        pass "push creates version 1"
    else
        fail "push did not return expected version name (got '$out')"
    fi
    [[ -f "$TMPDIR/boardA/partX/$out" ]] && pass "artifact file stored" || fail "artifact file not found in NFS store"
    [[ -f "$TMPDIR/boardA/partX/md5_1.meta" ]] && pass "meta file stored" || fail "meta file missing"
}

test_push_duplicate() {
    local artifact_dir
    artifact_dir=$(mktemp -d)
    echo "identical" > "$artifact_dir/file.txt"
    local first second
    first=$("$PFROG" push --nfs "$TMPDIR" --yes boardB partY "$artifact_dir" 2>/dev/null)
    second=$("$PFROG" push --nfs "$TMPDIR" --yes boardB partY "$artifact_dir" 2>/dev/null)
    [[ "$first" == "$second" ]] && pass "duplicate push returns same version" || fail "duplicate push created new version ('$first' vs '$second')"
    local count
    count=$(ls "$TMPDIR/boardB/partY"/*.tar.gz | wc -l)
    [[ "$count" -eq 1 ]] && pass "duplicate push did not add extra file" || fail "duplicate push added extra file ($count files)"
}

test_push_increment() {
    local art
    art=$(mktemp -d)
    echo "v1" > "$art/data"
    local v1 v2
    v1=$("$PFROG" push --nfs "$TMPDIR" --yes boardC partZ "$art" 2>/dev/null)
    echo "v2" > "$art/data"
    v2=$("$PFROG" push --nfs "$TMPDIR" --yes boardC partZ "$art" 2>/dev/null)
    [[ "$v1" != "$v2" ]] && pass "modified push created new version" || fail "modified push did not create new version"
    [[ "$v2" =~ _2\.tar\.gz$ ]] && pass "version incremented to 2" || fail "expected version 2, got '$v2'"
}

test_list() {
    local boards expected_boards
    boards=$("$PFROG" list --nfs "$TMPDIR" 2>/dev/null | sort)
    expected_boards=$(printf '%s\n' boardA boardB boardC)
    [[ "$boards" == "$expected_boards" ]] && pass "list boards" || fail "list boards returned unexpected result"
    local parts
    parts=$("$PFROG" list --nfs "$TMPDIR" boardA 2>/dev/null | sort)
    [[ "$parts" == "partX" ]] && pass "list parts for boardA" || fail "list parts incorrect for boardA"
    local versions count
    versions=$("$PFROG" list --nfs "$TMPDIR" boardC partZ 2>/dev/null | sort)
    count=$(echo "$versions" | wc -l)
    [[ "$count" -eq 2 ]] && pass "list versions count correct" || fail "list versions expected 2 entries"
}

test_pull() {
    local art
    art=$(mktemp -d)
    echo "p1" > "$art/a"
    "$PFROG" push --nfs "$TMPDIR" --yes boardP partQ "$art" >/dev/null 2>&1
    echo "p2" > "$art/a"
    local newver
    newver=$("$PFROG" push --nfs "$TMPDIR" --yes boardP partQ "$art" 2>/dev/null)

    # Isolated pull target
    local pull_tmp
    pull_tmp=$(mktemp -d)
    pushd "$pull_tmp" > /dev/null

    "$PFROG" pull --nfs "$TMPDIR" --yes boardP partQ >/dev/null 2>&1

    if [[ -f "$newver" ]]; then
        pass "pull retrieved file"
    else
        fail "pull did not copy expected file"
    fi

    local expect_md5 actual_md5
    expect_md5=$(echo "$newver" | awk -F '_' '{print $1}')
    actual_md5=$(md5sum "$newver" | awk '{print $1}')
    [[ "$expect_md5" == "$actual_md5" ]] && pass "pull MD5 verified" || fail "pull MD5 mismatch"

    popd > /dev/null
    rm -rf "$pull_tmp"
}

test_dry_run() {
    local art
    art=$(mktemp -d)
    echo "dry" > "$art/d"
    local out
    out=$("$PFROG" push --nfs "$TMPDIR" --yes --dry boardD partR "$art" 2>/dev/null)
    local file="$TMPDIR/boardD/partR/$out"
    [[ ! -e "$file" ]] && pass "dry run did not create file" || fail "dry run unexpectedly created file"
}

test_metadata() {
    local art
    art=$(mktemp -d)
    echo "meta" > "$art/data"
    local out base ver
    out=$("$PFROG" push --nfs "$TMPDIR" --yes --commit abcdef --tag mytag boardM partM "$art" 2>/dev/null)
    base="${out%.tar.gz}"; ver="${base##*_}"
    local meta_file="$TMPDIR/boardM/partM/md5_${ver}.meta"
    if [[ -f "$meta_file" ]]; then
        if grep -q '^commit=abcdef' "$meta_file" && grep -q '^tag=mytag' "$meta_file"; then
            pass "metadata file contains commit and tag"
        else
            fail "metadata file missing commit or tag"
        fi
    else
        fail "metadata file not created"
    fi
}

test_completion() {
    local comp
    comp=$("$PFROG" --generate-completion bash)
    echo "$comp" | grep -q 'complete -F _pfrog_complete pfrog' && pass "completion script generated" || fail "completion script missing expected function"
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
