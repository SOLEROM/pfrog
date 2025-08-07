#!/usr/bin/env bash
# pfrog - manage build artifacts across multiple boards using a shared NFS directory.
# This script implements a simple offline build artifact store. It compresses
# arbitrary directories into tar.gz archives named by their MD5 digest and a
# monotonically increasing version number. It allows pushing new artifacts,
# pulling existing ones, and listing contents of the store.

set -euo pipefail

# Print general help message
show_help() {
    cat <<'EOF'
pfrog - manage build artifacts across multiple boards using a shared NFS directory.

Usage:
  pfrog push [options] <board> <part> <dir>
  pfrog pull [options] <board> <part> [version]
  pfrog list [options] [<board> [<part>]]
  pfrog --help

Commands:
  push     Push an artifact (directory) into the store.
  pull     Retrieve an artifact from the store.
  list     List contents of the store (tree view).

Global Options:
  --help, -h           Show this help message.

push options:
  --nfs <path>         Override NFS root (default: PFROG_ROOT env or config file).
  --config <file>      Specify alternate config file (default: ./pfrog.conf).
  --yes                Skip confirmation prompt (default: ask).
  --dry                Simulate actions without modifying filesystem.
  --verbose            Enable verbose logging.
  --tag <string>       Provide a descriptive tag for the artifact.
  --commit <hash>      Record source control commit hash.

pull options:
  --nfs <path>         Override NFS root.
  --config <file>      Alternate config file.
  --yes                Skip overwrite confirmation.
  --verbose            Enable verbose logging.

list options:
  --nfs <path>         Override NFS root.
  --config <file>      Alternate config file.
  --verbose            Enable verbose output.
EOF
}

die() {
    echo "pfrog: $*" >&2
    exit 1
}

# Resolve NFS root directory. Order: --nfs flag > PFROG_ROOT > config file.
resolve_nfs_root() {
    local nfs_flag="$1" config_file="$2" root=""
    if [[ -n "$nfs_flag" ]]; then
        root="$nfs_flag"
    elif [[ -n "${PFROG_ROOT:-}" ]]; then
        root="$PFROG_ROOT"
    elif [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                PFROG_ROOT|root|nfs_root) root="$value"; break;;
            esac
        done < "$config_file"
    fi
    echo "$root"
}

# Compute MD5 checksum of a file and emit just the hex digest.
md5_of_file() {
    md5sum "$1" | awk '{print $1}'
}

# Show a spinner while a background process runs.
spinner() {
    local pid="$1" delay=0.1 spinchars='|/-\\'
    while kill -0 "$pid" 2>/dev/null; do
        for c in $spinchars; do
            printf '\r%c' "$c" >&2
            sleep "$delay"
        done
    done
    printf '\r' >&2
}

# push subcommand
push_cmd() {
    local nfs_flag="" config_file="pfrog.conf"
    local yes="false" dry="false" verbose="false" tag="" commit=""
    local board part srcdir

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nfs)     shift; nfs_flag="${1:-}";;
            --config)  shift; config_file="${1:-}";;
            --yes)     yes="true";;
            --dry)     dry="true";;
            --verbose) verbose="true";;
            --tag)     shift; tag="${1:-}";;
            --commit)  shift; commit="${1:-}";;
            --help|-h)
                cat <<'EOF'
Usage: pfrog push [options] <board> <part> <dir>
Push an artifact (directory) into the store.
Options:
  --nfs <path>        Override NFS root.
  --config <file>     Alternate config file.
  --yes               Skip confirmation prompt.
  --dry               Simulate without changes.
  --verbose           Detailed logs.
  --tag <string>      Descriptive tag.
  --commit <hash>     Source commit hash.
  -h, --help          Show help.
EOF
                return 0
                ;;
            --*) die "unknown option for push: $1";;
            *) break;;
        esac
        shift
    done

    [[ $# -ge 3 ]] || die "push: missing <board> <part> <dir>"
    board="$1"; part="$2"; srcdir="$3"
    [[ -d "$srcdir" ]] || die "push: directory '$srcdir' does not exist"

    local nfs_root
    nfs_root=$(resolve_nfs_root "$nfs_flag" "$config_file")
    [[ -n "$nfs_root" ]] || die "push: NFS root could not be resolved"
    [[ -d "$nfs_root" ]] || [[ "$dry" == "true" ]] || mkdir -p "$nfs_root"

    if [[ "$yes" != "true" ]]; then
        echo "Resolved NFS root: $nfs_root"
        echo -n "Proceed? [Y/n] "
        read -r answer
        case "$answer" in
            n|N|no|NO) echo "Aborted."; return 1;;
            *) ;;
        esac
    fi

    local target_dir="$nfs_root/$board/$part"
    [[ "$dry" == "true" ]] || mkdir -p "$target_dir"

    local tmpfile
    tmpfile=$(mktemp "pfrog_tmp_XXXXXXXX.tar.gz")
    [[ "$verbose" == "true" ]] && echo "Compressing '$srcdir'..." >&2
    (
        if [[ "$verbose" == "true" ]]; then
            tar --preserve-permissions -czf "$tmpfile" -C "$srcdir" .
        else
            tar --preserve-permissions -czf "$tmpfile" -C "$srcdir" . 2>/dev/null
        fi
    ) &
    spinner $!
    [[ "$verbose" == "true" ]] && echo "Compression complete." >&2

    local md5
    md5=$(md5_of_file "$tmpfile")
    [[ "$verbose" == "true" ]] && echo "MD5: $md5" >&2

    mkdir -p "$target_dir"
    exec 9>"$target_dir/.lock"
    flock -x 9

    local existing="" maxv=0
    for f in "$target_dir"/*.tar.gz; do
        [[ -e "$f" ]] || continue
        local base; base=$(basename "$f")
        if [[ "$base" =~ ^([0-9a-f]{32})_([0-9]+)\.tar\.gz$ ]]; then
            [[ "${BASH_REMATCH[1]}" == "$md5" ]] && existing="$base"
            (( BASH_REMATCH[2] > maxv )) && maxv=${BASH_REMATCH[2]}
        fi
    done

    if [[ -n "$existing" ]]; then
        [[ "$verbose" == "true" ]] && echo "Already exists: $existing" >&2
        rm -f "$tmpfile"
        echo "$existing"
        return 0
    fi

    local newv=$((maxv+1))
    local name="${md5}_${newv}.tar.gz"
    local dest="$target_dir/$name"
    if [[ "$dry" == "true" ]]; then
        [[ "$verbose" == "true" ]] && echo "[dry] would store as $dest" >&2
        rm -f "$tmpfile"
        echo "$name"
        return 0
    fi

    mv "$tmpfile" "$dest"
    [[ "$verbose" == "true" ]] && echo "Stored as $dest" >&2

    local meta="$target_dir/md5_${newv}.meta"
    {
        printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'user=%s\n' "${USER:-unknown}"
        [[ -n "$commit" ]] && printf 'commit=%s\n' "$commit"
        [[ -n "$tag"    ]] && printf 'tag=%s\n'    "$tag"
    } > "$meta"
    [[ "$verbose" == "true" ]] && echo "Wrote meta $meta" >&2

    echo "$name"
}

# pull subcommand
pull_cmd() {
    local nfs_flag="" config_file="pfrog.conf"
    local yes="false" verbose="false"
    local board part version

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nfs)     shift; nfs_flag="${1:-}";;
            --config)  shift; config_file="${1:-}";;
            --yes)     yes="true";;
            --verbose) verbose="true";;
            --help|-h)
                cat <<'EOF'
Usage: pfrog pull [options] <board> <part> [version]
Retrieve an artifact. If no version is given, pulls latest.
Options:
  --nfs <path>       Override NFS root.
  --config <file>    Alternate config file.
  --yes              Skip overwrite confirmation.
  --verbose          Detailed logs.
  -h, --help         Show help.
EOF
                return 0
                ;;
            --*) die "unknown option for pull: $1";;
            *) break;;
        esac
        shift
    done

    [[ $# -ge 2 ]] || die "pull: missing <board> <part>"
    board="$1"; part="$2"; shift 2
    [[ $# -ge 1 ]] && version="$1"

    local nfs_root
    nfs_root=$(resolve_nfs_root "$nfs_flag" "$config_file")
    [[ -n "$nfs_root" ]] || die "pull: NFS root could not be resolved"
    local dir="$nfs_root/$board/$part"
    [[ -d "$dir" ]] || die "pull: '$board/$part' not found"

    local to_pull="" maxv=0
    if [[ -n "${version:-}" ]]; then
        for f in "$dir"/*_"$version".tar.gz; do [[ -e "$f" ]] && { to_pull="$f"; break; }; done
        [[ -n "$to_pull" ]] || die "pull: version $version not found"
    else
        for f in "$dir"/*.tar.gz; do
            [[ -e "$f" ]] || continue
            local base; base=$(basename "$f")
            if [[ "$base" =~ ^[0-9a-f]{32}_([0-9]+)\.tar\.gz$ ]]; then
                (( BASH_REMATCH[1] > maxv )) && { maxv=${BASH_REMATCH[1]}; to_pull="$f"; }
            fi
        done
        [[ -n "$to_pull" ]] || die "pull: no artifacts found"
    fi

    local dest; dest=$(basename "$to_pull")
    if [[ -e "$dest" && "$yes" != "true" ]]; then
        echo -n "Overwrite '$dest'? [y/N] "
        read -r ans
        case "$ans" in y|Y|yes|YES) ;; *) echo "Aborted."; return 1;; esac
    fi

    [[ "$verbose" == "true" ]] && echo "Copying $to_pull to $dest" >&2
    cp "$to_pull" "$dest"

    if [[ "$dest" =~ ^([0-9a-f]{32})_ ]]; then
        local exp="${BASH_REMATCH[1]}"
        local act; act=$(md5_of_file "$dest")
        [[ "$exp" != "$act" ]] && echo "Warning: MD5 mismatch ($exp != $act)" >&2
    fi

    echo "$dest"
}

# list subcommand (tree-like, excluding .meta and .lock)
list_cmd() {
    local nfs_flag="" config_file="pfrog.conf"
    local verbose="false" board="" part=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nfs)     shift; nfs_flag="${1:-}";;
            --config)  shift; config_file="${1:-}";;
            --verbose) verbose="true";;
            --help|-h)
                cat <<'EOF'
Usage: pfrog list [options] [<board> [<part>]]
List the store in a tree view. Only shows .tar.gz entries with metadata.
Options:
  --nfs <path>       Override NFS root.
  --config <file>    Alternate config file.
  --verbose          Detailed output.
  -h, --help         Show help.
EOF
                return 0
                ;;
            --*) die "unknown option for list: $1";;
            *) break;;
        esac
        shift
    done

    [[ $# -ge 1 ]] && board="$1" && shift
    [[ $# -ge 1 ]] && part="$1"  && shift

    local nfs_root
    nfs_root=$(resolve_nfs_root "$nfs_flag" "$config_file")
    [[ -n "$nfs_root" ]] || die "list: NFS root could not be resolved"

    local target="$nfs_root"
    [[ -n "$board" ]] && target="$target/$board"
    [[ -n "$part"  ]] && target="$target/$part"
    [[ -d "$target" ]] || die "list: '$board${board:+/}$part' not found"

    if command -v tree &>/dev/null; then
        tree -P '*.tar.gz' -I '*.meta|*.lock' "$target"
        return
    fi

    # fallback two-level tree
    for bdir in "$target"/*; do
        [[ -d "$bdir" ]] || continue
        local boardn; boardn=$(basename "$bdir")
        echo "$boardn/"
        for pdir in "$bdir"/*; do
            [[ -d "$pdir" ]] || continue
            local partn; partn=$(basename "$pdir")
            echo "├── $partn/"
            for f in "$pdir"/*.tar.gz; do
                [[ -e "$f" ]] || continue
                local name; name=$(basename "$f")
                local ver; ver=$(sed -E 's/^[0-9a-f]{32}_([0-9]+)\.tar\.gz$/\1/' <<<"$name")
                local meta_file="$pdir/md5_${ver}.meta"
                if [[ -f "$meta_file" ]]; then
                    local mstr=""
                    while IFS='=' read -r k v; do mstr+="$k=$v "; done <"$meta_file"
                    mstr=${mstr% }
                    echo "│   └── $name [$mstr]"
                else
                    echo "│   └── $name"
                fi
            done
        done
    done
}

# Main entrypoint
main() {
    [[ $# -eq 0 ]] && { show_help; exit 0; }
    case "$1" in
        push) shift; push_cmd "$@";;
        pull) shift; pull_cmd "$@";;
        list) shift; list_cmd "$@";;
        --help|-h) show_help;;
        *) die "unknown command: $1";;
    esac
}

main "$@"
