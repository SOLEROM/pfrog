#!/usr/bin/env bash
# pfrog - manage build artifacts across multiple boards using a shared NFS directory.
# This script implements a simple offline build artifact store. It compresses
# arbitrary directories into tar.gz archives named by their MD5 digest and a
# monotonically increasing version number. It allows pushing new artifacts,
# pulling existing ones, and listing contents of the store.

set -euo pipefail

# ------------------------------------------------------------------
# HELPER FUNCTIONS
# ------------------------------------------------------------------

die() {
    echo "pfrog: $*" >&2
    exit 1
}

show_help() {
    cat <<'EOF'
pfrog - manage build artifacts across multiple boards using a shared NFS directory.

STORE LOCATION:     (1) --nfs flag 
                    (2) PFROG_ROOT env var (export PFROG_ROOT=<xxx>)
                    (3) config file: ./pfrog.conf [PFROG_ROOT=<xxx>]

Usage:
  pfrog push [options] <board> <part> <dir>             // --help
  pfrog pull [options] [<board> [<part> [<version>]]]   // --help
  pfrog list [options] [<board> [<part>]]               // --help
  pfrog --help

Commands:
  push     Push an artifact (directory) into the store.
  pull     Interactive pull/list or retrieve an artifact.
  list     List contents of the store (tree view).

Global Options:
  --help, -h           Show this help message.
EOF
}

# Resolve NFS root directory. Order: --nfs flag > PFROG_ROOT > config file.
resolve_nfs_root() {
    local nfs_flag="$1" config_file="$2"
    if [[ -n "$nfs_flag" ]]; then
        echo "$nfs_flag"
    elif [[ -n "${PFROG_ROOT:-}" ]]; then
        echo "$PFROG_ROOT"
    elif [[ -f "$config_file" ]]; then
        # parse first matching key
        while IFS='=' read -r key value; do
            case "$key" in
                PFROG_ROOT|root|nfs_root) echo "$value"; return;;
            esac
        done < "$config_file"
    fi
}

# Compute MD5 checksum of a file and emit just the hex digest.
md5_of_file() {
    md5sum "$1" | awk '{print $1}'
}

# Show a spinner while a background process runs.
spinner() {
    local pid=$1 delay=0.1 spin='|/-\' c
    while kill -0 "$pid" 2>/dev/null; do
        for c in $spin; do
            printf '\r%c' "$c" >&2
            sleep "$delay"
        done
    done
    printf '\r' >&2
}

# ------------------------------------------------------------------
# PUSH COMMAND
# ------------------------------------------------------------------

push_cmd() {
    local nfs_flag="" config_file="pfrog.conf"
    local yes="false" dry="false" verbose="false" tag="" commit=""
    local board part srcdir

    # parse push options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nfs)     shift; nfs_flag=$1;;
            --config)  shift; config_file=$1;;
            --yes)     yes="true";;
            --dry)     dry="true";;
            --verbose) verbose="true";;
            --tag)     shift; tag=$1;;
            --commit)  shift; commit=$1;;
            -h|--help)
                cat <<'EOF'
Usage: pfrog push [options] <board> <part> <dir>
Options:
  --nfs <path>        Override NFS root.
  --config <file>     Alternate config file.
  --yes               Skip confirmation prompt.
  --dry               Simulate without changes.
  --verbose           Detailed logs.
  --tag <string>      Descriptive tag.
  --commit <hash>     Source commit hash.
  -h, --help          Show this help.
EOF
                return
                ;;
            --*) die "unknown option for push: $1";;
            *) break;;
        esac
        shift
    done

    [[ $# -ge 3 ]] || die "push: missing <board> <part> <dir>"
    board=$1; part=$2; srcdir=$3
    [[ -d "$srcdir" ]] || die "push: '$srcdir' is not a directory"

    # resolve and prepare NFS root
    local nfs_root
    nfs_root=$(resolve_nfs_root "$nfs_flag" "$config_file") || die "push: NFS root not found"
    [[ -d "$nfs_root" ]] || [[ "$dry" == "true" ]] || mkdir -p "$nfs_root"

    # confirmation prompt
    if [[ "$yes" != "true" ]]; then
        echo "NFS root: $nfs_root"
        read -rp "Proceed? [Y/n] " ans
        [[ $ans =~ ^[Nn] ]] && { echo "Aborted."; return 1; }
    fi

    local target_dir="$nfs_root/$board/$part"
    [[ "$dry" == "true" ]] || mkdir -p "$target_dir"

    # compress
    local tmpfile
    tmpfile=$(mktemp "pfrog_tmp_XXXXXXXX.tar.gz")
    [[ "$verbose" == "true" ]] && echo "Compressing '$srcdir'..."
    ( tar --preserve-permissions -czf "$tmpfile" -C "$srcdir" . ${verbose:+} ) &
    spinner $!
    [[ "$verbose" == "true" ]] && echo "Done."

    # checksum
    local md5
    md5=$(md5_of_file "$tmpfile")

    # concurrency lock
    exec 9>"$target_dir/.lock"
    flock -x 9

    # detect existing versions
    local existing="" maxv=0
    for f in "$target_dir"/*.tar.gz; do
        [[ -e "$f" ]] || continue
        if [[ $(basename "$f") =~ ^([0-9a-f]{32})_([0-9]+)\.tar\.gz$ ]]; then
            [[ ${BASH_REMATCH[1]} == $md5 ]] && existing=$(basename "$f")
            (( BASH_REMATCH[2] > maxv )) && maxv=${BASH_REMATCH[2]}
        fi
    done

    if [[ -n $existing ]]; then
        [[ "$verbose" == "true" ]] && echo "Already exists: $existing"
        rm -f "$tmpfile"
        echo "$existing"
        return
    fi

    # new version
    local newv=$((maxv+1))
    local name="${md5}_${newv}.tar.gz"
    local dest="$target_dir/$name"
    if [[ "$dry" == "true" ]]; then
        [[ "$verbose" == "true" ]] && echo "[dry] would store as $dest"
        rm -f "$tmpfile"
        echo "$name"
        return
    fi

    mv "$tmpfile" "$dest"
    
    # match timestamp to source folder mtime
    local src_mtime
    src_mtime=$(date -r "$srcdir" +%s)
    touch -d "@$src_mtime" "$dest"

    [[ "$verbose" == "true" ]] && echo "Stored: $dest (timestamp set to match source dir)"

    # write metadata
    local meta="$target_dir/md5_${newv}.meta"
    {
        printf 'timestamp=%s\n' "$(date -u -d "@$src_mtime" +%Y-%m-%dT%H:%M:%SZ)"
        printf 'user=%s\n' "${USER:-unknown}"
        [[ -n $commit ]] && printf 'commit=%s\n' "$commit"
        [[ -n $tag    ]] && printf 'tag=%s\n'    "$tag"
    } > "$meta"
    touch -d "@$src_mtime" "$meta"
    [[ "$verbose" == "true" ]] && echo "Meta: $meta (timestamp matched)"

    echo "$name"
}

# ------------------------------------------------------------------
# PULL COMMAND (with interactive listing)
# ------------------------------------------------------------------
pull_cmd() {
    # option defaults
    local nfs_flag="" config_file="pfrog.conf"
    local yes="false" verbose="false" tag_mode="false"
    local extract_root=""

    # collect positional args here
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nfs)     nfs_flag="$2"; shift 2;;
            --config)  config_file="$2"; shift 2;;
            --yes)     yes="true"; shift;;
            --verbose) verbose="true"; shift;;
            --tag)     tag_mode="true"; shift;;
            --root)    extract_root="$2"; shift 2;;
            root=*)    extract_root="${1#root=}"; shift;;
            -h|--help)
                cat <<'EOF'
Usage: pfrog pull [options] [<board> [<part> [<version>]]]

  No args                → list boards
  <board>                → list parts under that board
  <board> <part>         → pull latest (or use --tag for interactive)
  <board> <part> <ver>   → pull specific version

Options:
  --nfs <path>       Override NFS root.
  --config <file>    Alternate config file.
  --yes              Skip overwrite prompt (when saving tar to cwd).
  --verbose          Detailed logs.
  --tag              Interactive version selection.
  --root <path>      OR root=<path>; extract tar into <path> with: tar -xzf ... -C <path>
  -h, --help         Show this help.
EOF
                return
                ;;
            *)
                args+=("$1"); shift;;
        esac
    done
    set -- "${args[@]}"

    # resolve NFS root
    local nfs_root
    nfs_root=$(resolve_nfs_root "$nfs_flag" "$config_file") \
        || die "pull: NFS root could not be resolved"

    # 1) no args → list boards
    if [[ $# -eq 0 ]]; then
        echo "You need to choose a board:"
        for d in "$nfs_root"/*/; do
            [[ -d $d ]] || continue
            printf "  %s/\n" "${d%/}" | xargs basename
        done
        return
    fi

    # 2) one arg → list parts
    if [[ $# -eq 1 ]]; then
        local board="$1"
        local board_dir="$nfs_root/$board"
        [[ -d $board_dir ]] || die "pull: board '$board' not found"

        echo "You need to choose a part under board '$board':"
        for d in "$board_dir"/*/; do
            [[ -d $d ]] || continue
            printf "  %s/\n" "${d%/}" | xargs basename
        done
        return
    fi

    # 3) two or three args → perform pull
    local board="$1" part="$2" version="${3:-}"
    local dir="$nfs_root/$board/$part"
    [[ -d $dir ]] || die "pull: '$board/$part' not found"

    local to_pull=""
    if [[ "$tag_mode" == "true" ]]; then
        echo "Select an artifact to pull from '$board/$part':"
        local files=( "$dir"/*.tar.gz )
        [[ ${#files[@]} -gt 0 ]] || die "pull: no artifacts found"

        local i=1
        for f in "${files[@]}"; do
            local name=$(basename "$f")
            local ver=${name#*_}; ver=${ver%.tar.gz}
            local meta="$dir/md5_${ver}.meta"
            if [[ -f $meta ]]; then
                local ts=$(grep '^timestamp=' "$meta" | cut -d= -f2-)
                local tg=$(grep '^tag='       "$meta" | cut -d= -f2-)
                printf "  [%d] %s  (timestamp=%s%s)\n" \
                  "$i" "$name" "$ts" "${tg:+, tag=$tg}"
            else
                printf "  [%d] %s\n" "$i" "$name"
            fi
            ((i++))
        done

        read -rp "Enter number [1-$((i-1))]: " sel
        [[ $sel =~ ^[0-9]+$ ]] && (( sel>=1 && sel<i )) \
          || die "Invalid selection"
        to_pull="${files[$((sel-1))]}"
    else
        if [[ -n $version ]]; then
            to_pull=$(ls "$dir"/*_"$version".tar.gz 2>/dev/null | head -n1)
            [[ -n $to_pull ]] || die "pull: version $version not found"
        else
            local maxv=0
            for f in "$dir"/*.tar.gz; do
                [[ -e $f ]] || continue
                if [[ $(basename "$f") =~ ^[0-9a-f]{32}_([0-9]+)\.tar\.gz$ ]]; then
                    if (( BASH_REMATCH[1] > maxv )); then
                        maxv=${BASH_REMATCH[1]}
                        to_pull="$f"
                    fi
                fi
            done
            [[ -n $to_pull ]] || die "pull: no artifacts found"
        fi
    fi

    # verify checksum before extracting/copying
    if [[ $(basename "$to_pull") =~ ^([0-9a-f]{32})_ ]]; then
        local exp=${BASH_REMATCH[1]}
        local act
        act=$(md5_of_file "$to_pull")
        [[ $exp != $act ]] && echo "Warning: MD5 mismatch ($exp != $act)" >&2
    fi

    if [[ -n "$extract_root" ]]; then
        # extract directly from NFS store, no local tar left behind
        $verbose && echo "Extracting $to_pull -> $extract_root"
        mkdir -p "$extract_root"
        tar -xzf "$to_pull" -C "$extract_root"
        echo "Extracted to $extract_root"
        printf '%s\n' "$extract_root"
    else
        # copy tar to cwd (original behavior)
        local dest=$(basename "$to_pull")
        if [[ -e $dest && $yes != "true" ]]; then
            read -rp "Overwrite '$dest'? [y/N] " ans
            [[ $ans =~ ^[Yy] ]] || { echo "Aborted."; return 1; }
        fi
        $verbose && echo "Copying $to_pull → $dest"
        cp "$to_pull" "$dest"
        echo "$dest"
    fi
}



# ------------------------------------------------------------------
# LIST COMMAND
# ------------------------------------------------------------------

list_cmd() {
    local nfs_flag="" config_file="pfrog.conf" verbose="false" board="" part=""
    # parse list options
    while [[ $# -gt 0 && $1 == --* ]]; do
        case "$1" in
            --nfs)     shift; nfs_flag=$1;;
            --config)  shift; config_file=$1;;
            --verbose) verbose="true";;
            -h|--help)
                cat <<'EOF'
Usage: pfrog list [options] [<board> [<part>]]
List the store in a tree view (only .tar.gz, show metadata if present).

Options:
  --nfs <path>       Override NFS root.
  --config <file>    Alternate config file.
  --verbose          Detailed output.
EOF
                return
                ;;
            *) die "unknown option for list: $1";;
        esac
        shift
    done

    [[ $# -ge 1 ]] && board=$1 && shift
    [[ $# -ge 1 ]] && part=$1  && shift

    local nfs_root
    nfs_root=$(resolve_nfs_root "$nfs_flag" "$config_file") || die "list: NFS root not resolved"

    local target=$nfs_root
    [[ -n $board ]] && target+="/$board"
    [[ -n $part  ]] && target+="/$part"

    [[ -d $target ]] || die "list: '$board${board:+/}$part' not found"

    if command -v tree &>/dev/null; then
        tree -P '*.tar.gz' -I '*.meta|*.lock' "$target"
        return
    fi

    # fallback manual tree
    for b in "$target"/*; do
        [[ -d $b ]] || continue
        echo "$(basename "$b")/"
        for p in "$b"/*; do
            [[ -d $p ]] || continue
            echo "├── $(basename "$p")/"
            for f in "$p"/*.tar.gz; do
                [[ -e $f ]] || continue
                local name; name=$(basename "$f")
                local ver; ver=${name#*_}; ver=${ver%.tar.gz}
                local meta=$p/md5_"$ver".meta
                if [[ -f $meta ]]; then
                    local mstr=""
                    while IFS='=' read -r k v; do mstr+="$k=$v "; done <"$meta"
                    echo "│   └── $name [$mstr]"
                else
                    echo "│   └── $name"
                fi
            done
        done
    done
}

# ------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------

main() {
    [[ $# -eq 0 ]] && { show_help; exit 0; }
    case "$1" in
        push) shift; push_cmd "$@";;
        pull) shift; pull_cmd "$@";;
        list) shift; list_cmd "$@";;
        -h|--help) show_help;;
        *) die "unknown command: $1";;
    esac
}

main "$@"
