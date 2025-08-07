#!/usr/bin/env bash
# pfrog - manage build artifacts across multiple boards using a shared NFS directory.
# This script implements a simple offline build artifact store. It compresses
# arbitrary directories into tar.gz archives named by their MD5 digest and a
# monotonically increasing version number. It allows pushing new artifacts,
# pulling existing ones, listing contents of the store and generating basic
# completion scripts.

set -euo pipefail

# Print general help message
show_help() {
    cat <<'EOF'
Usage: pfrog <command> [options]

Commands:
  push <board> <part> <dir>      Push an artifact to the store.
  pull <board> <part> [version]  Pull an artifact from the store (latest if omitted).
  list [<board> [<part>]]        List boards, parts and versions in the store.
  --generate-completion [shell]  Generate shell completion script for bash, zsh or fish.
  --help                         Show this help message.

Run pfrog <command> --help for command‑specific options.
EOF
}

die() {
    echo "pfrog: $*" >&2
    exit 1
}

# Resolve NFS root directory. Order: --nfs flag > PFROG_ROOT > config file.
# Accepts two arguments: value of --nfs flag (may be empty) and config file path.
resolve_nfs_root() {
    local nfs_flag="$1"
    local config_file="$2"
    local root=""
    if [[ -n "$nfs_flag" ]]; then
        root="$nfs_flag"
    elif [[ -n "${PFROG_ROOT:-}" ]]; then
        root="$PFROG_ROOT"
    elif [[ -n "$config_file" && -f "$config_file" ]]; then
        # Read simple KEY=VALUE lines; we look for PFROG_ROOT or root= entries.
        while IFS='=' read -r key value; do
            case "$key" in
                PFROG_ROOT|root|nfs_root)
                    root="$value"
                    break
                    ;;
            esac
        done < "$config_file"
    fi
    echo "$root"
}

# Compute MD5 checksum of a file and emit just the hex digest.
md5_of_file() {
    local file="$1"
    md5sum "$file" | awk '{print $1}'
}

# Show a simple spinner while a background process is running. Helps provide feedback
# during long‑running operations. It prints to stderr to avoid breaking output
# streams. Spins until the PID passed as argument exits.
spinner() {
    local pid="$1"
    local delay=0.1
    local spinchars='|/-\\'
    while kill -0 "$pid" 2>/dev/null; do
        for c in $(echo -n "$spinchars"); do
            printf '\r%c' "$c" >&2
            sleep "$delay"
        done
    done
    printf '\r' >&2
}

# Implementation of the push subcommand.
push_cmd() {
    local board=""
    local part=""
    local srcdir=""
    local nfs_flag=""
    local config_file="pfrog.conf"
    local yes="false"
    local dry="false"
    local verbose="false"
    local tag=""
    local commit=""

    # parse push options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nfs)
                shift; nfs_flag="${1:-}" || die "missing argument to --nfs"
                ;;
            --config)
                shift; config_file="${1:-}" || die "missing argument to --config"
                ;;
            --yes)
                yes="true"
                ;;
            --dry)
                dry="true"
                ;;
            --verbose)
                verbose="true"
                ;;
            --tag)
                shift; tag="${1:-}" || die "missing argument to --tag"
                ;;
            --commit)
                shift; commit="${1:-}" || die "missing argument to --commit"
                ;;
            --help|-h)
                cat <<'EOF'
Usage: pfrog push [options] <board> <part> <dir>

Push an artifact (directory) into the store under the given board and part labels.
Options:
  --nfs <path>        Override NFS root (default resolves from PFROG_ROOT or config file).
  --config <file>     Specify alternate config file (default: ./pfrog.conf).
  --yes               Do not ask for confirmation of the resolved NFS path.
  --dry               Simulate actions without modifying the filesystem.
  --verbose           Output detailed logs.
  --tag <string>      Provide a descriptive tag recorded with the artifact.
  --commit <hash>     Provide a source control commit hash recorded with the artifact.
  -h, --help          Show this help message.
EOF
                return 0
                ;;
            --*)
                die "unknown option for push: $1"
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    # remaining arguments: board, part, directory
    [[ $# -lt 3 ]] && die "push: missing required arguments <board> <part> <dir>"
    board="$1"; part="$2"; srcdir="$3"; shift 3
    [[ -d "$srcdir" ]] || die "push: directory '$srcdir' does not exist"

    local nfs_root
    nfs_root=$(resolve_nfs_root "$nfs_flag" "$config_file")
    [[ -n "$nfs_root" ]] || die "push: NFS root could not be resolved"
    if [[ ! -d "$nfs_root" ]]; then
        if [[ "$dry" == "false" ]]; then
            mkdir -p "$nfs_root"
        fi
    fi

    if [[ "$yes" == "false" ]]; then
        echo "Resolved NFS root: $nfs_root"
        echo -n "Proceed? [y/N] "
        read -r answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) echo "Aborted."; return 1 ;;
        esac
    fi

    local target_dir="$nfs_root/$board/$part"
    if [[ "$dry" == "false" ]]; then
        mkdir -p "$target_dir"
    fi

    # Compress the directory to a temporary tar.gz to compute md5.
    local tmpfile
    tmpfile=$(mktemp "pfrog_tmp_XXXXXXXX.tar.gz")
    if [[ "$verbose" == "true" ]]; then
        echo "Compressing '$srcdir' to temporary archive..." >&2
    fi
    (
        # Use tar with preserved permissions and symlinks. Put output into tmpfile.
        # We redirect stderr to /dev/null to keep tar quiet unless verbose.
        if [[ "$verbose" == "true" ]]; then
            tar --preserve-permissions -czf "$tmpfile" -C "$srcdir" .
        else
            tar --preserve-permissions -czf "$tmpfile" -C "$srcdir" . 2>/dev/null
        fi
    ) &
    local tar_pid=$!
    spinner "$tar_pid"
    wait "$tar_pid"
    if [[ "$verbose" == "true" ]]; then
        echo "Compression complete." >&2
    fi

    # Compute md5 of the archive.
    local md5
    md5=$(md5_of_file "$tmpfile")
    if [[ "$verbose" == "true" ]]; then
        echo "Calculated MD5: $md5" >&2
    fi

    # Acquire a lock on target_dir for safe concurrent writes
    local lockfile="$target_dir/.lock"
    local fd
    exec {fd}>"$lockfile"
    # Use non-blocking first to create file if needed, then exclusive lock.
    flock -x "$fd"

    # Determine existing versions and whether this md5 already exists.
    local existing_file=""
    local max_version=0
    if [[ -d "$target_dir" ]]; then
        # Iterate over .tar.gz files in the directory
        for f in "$target_dir"/*.tar.gz; do
            [[ -e "$f" ]] || continue
            local base
            base=$(basename "$f")
            # expected pattern: <md5>_<n>.tar.gz
            if [[ "$base" =~ ^([0-9a-fA-F]{32})_([0-9]+)\.tar\.gz$ ]]; then
                local file_md5="${BASH_REMATCH[1]}"
                local ver="${BASH_REMATCH[2]}"
                # update max_version
                if (( ver > max_version )); then
                    max_version=$ver
                fi
                if [[ "$file_md5" == "$md5" ]]; then
                    existing_file="$base"
                fi
            fi
        done
    fi

    if [[ -n "$existing_file" ]]; then
        if [[ "$verbose" == "true" ]]; then
            echo "Artifact already exists as $existing_file" >&2
        fi
        echo "$existing_file"
        # Remove temporary file
        rm -f "$tmpfile"
        return 0
    fi

    local new_version=$((max_version + 1))
    local archive_name="${md5}_${new_version}.tar.gz"
    local dest_file="$target_dir/$archive_name"
    if [[ "$dry" == "true" ]]; then
        if [[ "$verbose" == "true" ]]; then
            echo "[dry] Would store as $dest_file" >&2
        fi
        # Clean up temp file
        rm -f "$tmpfile"
        echo "$archive_name"
        return 0
    fi

    # Move temporary file to final location
    mv "$tmpfile" "$dest_file"
    if [[ "$verbose" == "true" ]]; then
        echo "Stored artifact as $dest_file" >&2
    fi
    # Write meta file if tag or commit or always timestamp
    local meta_file="$target_dir/md5_${new_version}.meta"
    {
        # ISO‑8601 timestamp
        printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'user=%s\n' "${USER:-unknown}"
        if [[ -n "$commit" ]]; then
            printf 'commit=%s\n' "$commit"
        fi
        if [[ -n "$tag" ]]; then
            printf 'tag=%s\n' "$tag"
        fi
    } > "$meta_file"
    if [[ "$verbose" == "true" ]]; then
        echo "Wrote meta file $meta_file" >&2
    fi
    echo "$archive_name"
}

# Implementation of pull subcommand.
pull_cmd() {
    local board=""
    local part=""
    local version=""
    local nfs_flag=""
    local config_file="pfrog.conf"
    local yes="false"
    local verbose="false"

    # parse pull options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nfs)
                shift; nfs_flag="${1:-}" || die "missing argument to --nfs"
                ;;
            --config)
                shift; config_file="${1:-}" || die "missing argument to --config"
                ;;
            --yes)
                yes="true"
                ;;
            --verbose)
                verbose="true"
                ;;
            --help|-h)
                cat <<'EOF'
Usage: pfrog pull [options] <board> <part> [version]

Retrieve an artifact from the store. If no version is specified, the latest
version is pulled. The .tar.gz file is copied into the current working
directory. After download, the MD5 digest of the file is recalculated and
compared to the name to ensure integrity. A warning is printed if the
checksum does not match.

Options:
  --nfs <path>    Override NFS root (default resolves from PFROG_ROOT or config).
  --config <file> Specify alternate config file (default: ./pfrog.conf).
  --yes           Do not prompt to overwrite existing local files.
  --verbose       Output detailed logs.
  -h, --help      Show this help message.
EOF
                return 0
                ;;
            --*)
                die "unknown option for pull: $1"
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    # remaining args: board, part, [version]
    [[ $# -lt 2 ]] && die "pull: missing required arguments <board> <part>"
    board="$1"; part="$2"; shift 2
    if [[ $# -ge 1 ]]; then
        version="$1"; shift
    fi
    local nfs_root
    nfs_root=$(resolve_nfs_root "$nfs_flag" "$config_file")
    [[ -n "$nfs_root" ]] || die "pull: NFS root could not be resolved"
    local dir="$nfs_root/$board/$part"
    [[ -d "$dir" ]] || die "pull: board/part '$board/$part' does not exist in store"

    # Find the file to pull. If version is given, find md5_<version>.tar.gz; else highest.
    local to_pull=""
    local max_version=0
    if [[ -n "$version" ]]; then
        # find file with pattern *_<version>.tar.gz
        for f in "$dir"/*_"$version".tar.gz; do
            [[ -e "$f" ]] || continue
            to_pull="$f"
            break
        done
        [[ -n "$to_pull" ]] || die "pull: version $version not found for $board/$part"
    else
        for f in "$dir"/*.tar.gz; do
            [[ -e "$f" ]] || continue
            local base
            base=$(basename "$f")
            if [[ "$base" =~ ^([0-9a-fA-F]{32})_([0-9]+)\.tar\.gz$ ]]; then
                local ver="${BASH_REMATCH[2]}"
                if (( ver > max_version )); then
                    max_version=$ver
                    to_pull="$f"
                fi
            fi
        done
        [[ -n "$to_pull" ]] || die "pull: no artifacts found for $board/$part"
    fi
    local dest
    dest=$(basename "$to_pull")
    if [[ -e "$dest" ]]; then
        if [[ "$yes" == "false" ]]; then
            echo -n "File '$dest' exists. Overwrite? [y/N] "
            read -r ans
            case "$ans" in
                y|Y|yes|YES) ;;
                *) echo "Aborted."; return 1 ;;
            esac
        fi
    fi
    if [[ "$verbose" == "true" ]]; then
        echo "Copying $to_pull to $dest" >&2
    fi
    cp "$to_pull" "$dest"
    # Check MD5 integrity
    local fname
    fname=$(basename "$to_pull")
    if [[ "$fname" =~ ^([0-9a-fA-F]{32})_([0-9]+)\.tar\.gz$ ]]; then
        local expected_md5="${BASH_REMATCH[1]}"
        local actual_md5
        actual_md5=$(md5_of_file "$dest")
        if [[ "$expected_md5" != "$actual_md5" ]]; then
            echo "Warning: MD5 mismatch after pull (expected $expected_md5, got $actual_md5)" >&2
        fi
    fi
    echo "$dest"
}

# Implementation of list subcommand.
list_cmd() {
    local nfs_flag=""
    local config_file="pfrog.conf"
    local verbose="false"
    local board=""
    local part=""
    # parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nfs)
                shift; nfs_flag="${1:-}" || die "missing argument to --nfs"
                ;;
            --config)
                shift; config_file="${1:-}" || die "missing argument to --config"
                ;;
            --verbose)
                verbose="true"
                ;;
            --help|-h)
                cat <<'EOF'
Usage: pfrog list [options] [<board> [<part>]]

List boards, parts and versions stored under the NFS root. If no board is
specified, all boards are printed. If only <board> is provided, all parts
for that board are listed. If both <board> and <part> are given, versions
under that part are shown with any metadata extracted from accompanying
.meta files.

Options:
  --nfs <path>    Override NFS root (default resolves from PFROG_ROOT or config).
  --config <file> Specify alternate config file (default: ./pfrog.conf).
  --verbose       Output additional diagnostic messages.
  -h, --help      Show this help message.
EOF
                return 0
                ;;
            --*)
                die "unknown option for list: $1"
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    # parse optional board and part
    if [[ $# -gt 0 ]]; then
        board="$1"
        shift
    fi
    if [[ $# -gt 0 ]]; then
        part="$1"
        shift
    fi
    local nfs_root
    nfs_root=$(resolve_nfs_root "$nfs_flag" "$config_file")
    [[ -n "$nfs_root" ]] || die "list: NFS root could not be resolved"
    [[ -d "$nfs_root" ]] || die "list: NFS root '$nfs_root' does not exist"

    # board-level listing
    if [[ -z "$board" ]]; then
        # list all directories under nfs_root
        for b in "$nfs_root"/*; do
            [[ -d "$b" ]] || continue
            echo "$(basename "$b")"
        done
        return 0
    fi
    # part-level listing
    local board_dir="$nfs_root/$board"
    [[ -d "$board_dir" ]] || die "list: board '$board' not found"
    if [[ -z "$part" ]]; then
        for p in "$board_dir"/*; do
            [[ -d "$p" ]] || continue
            echo "$(basename "$p")"
        done
        return 0
    fi
    # version-level listing
    local part_dir="$board_dir/$part"
    [[ -d "$part_dir" ]] || die "list: part '$board/$part' not found"
    # gather entries
    for f in "$part_dir"/*.tar.gz; do
        [[ -e "$f" ]] || continue
        local base
        base=$(basename "$f")
        if [[ "$base" =~ ^([0-9a-fA-F]{32})_([0-9]+)\.tar\.gz$ ]]; then
            local ver="${BASH_REMATCH[2]}"
            local meta_file="$part_dir/md5_${ver}.meta"
            if [[ -f "$meta_file" ]]; then
                # read metadata key=value pairs
                local meta_str=""
                while IFS='=' read -r key value; do
                    meta_str+="$key=$value "
                done < "$meta_file"
                echo "$base [${meta_str% }]"
            else
                echo "$base"
            fi
        fi
    done
}

# Generate completion scripts. Currently supports bash, zsh, and fish.
generate_completion() {
    local shell="$1"
    cat <<'EOF'
_pfrog_complete() {
    local cur prev words cword
    _init_completion || return
    local commands="push pull list --generate-completion --help"
    if [[ ${cword} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return
    fi
    case "${words[1]}" in
        push)
            # Complete options
            local opts="--nfs --config --yes --dry --verbose --tag --commit --help"
            if [[ "$cur" == --* ]]; then
                COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
                return
            fi
            # board argument completion
            if [[ ${cword} -eq 2 ]]; then
                # boards from PFROG_ROOT
                local root
                root=$(resolve_nfs_root "" "pfrog.conf")
                if [[ -n "$root" ]]; then
                    COMPREPLY=( $(compgen -W "$(ls "$root" 2>/dev/null)" -- "$cur") )
                fi
                return
            fi
            # part argument completion
            if [[ ${cword} -eq 3 ]]; then
                local root
                root=$(resolve_nfs_root "" "pfrog.conf")
                if [[ -n "$root" ]]; then
                    local b="${words[2]}"
                    COMPREPLY=( $(compgen -W "$(ls "$root/$b" 2>/dev/null)" -- "$cur") )
                fi
                return
            fi
            ;;
        pull)
            local opts="--nfs --config --yes --verbose --help"
            if [[ "$cur" == --* ]]; then
                COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
                return
            fi
            # board and part completion similar to push
            if [[ ${cword} -eq 2 ]]; then
                local root
                root=$(resolve_nfs_root "" "pfrog.conf")
                COMPREPLY=( $(compgen -W "$(ls "$root" 2>/dev/null)" -- "$cur") )
                return
            fi
            if [[ ${cword} -eq 3 ]]; then
                local root
                root=$(resolve_nfs_root "" "pfrog.conf")
                local b="${words[2]}"
                COMPREPLY=( $(compgen -W "$(ls "$root/$b" 2>/dev/null)" -- "$cur") )
                return
            fi
            ;;
        list)
            local opts="--nfs --config --verbose --help"
            if [[ "$cur" == --* ]]; then
                COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
                return
            fi
            if [[ ${cword} -eq 2 ]]; then
                local root
                root=$(resolve_nfs_root "" "pfrog.conf")
                COMPREPLY=( $(compgen -W "$(ls "$root" 2>/dev/null)" -- "$cur") )
                return
            fi
            if [[ ${cword} -eq 3 ]]; then
                local root
                root=$(resolve_nfs_root "" "pfrog.conf")
                local b="${words[2]}"
                COMPREPLY=( $(compgen -W "$(ls "$root/$b" 2>/dev/null)" -- "$cur") )
                return
            fi
            ;;
    esac
}
complete -F _pfrog_complete pfrog
EOF
}

# Main entrypoint
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi
    case "$1" in
        push)
            shift; push_cmd "$@"
            ;;
        pull)
            shift; pull_cmd "$@"
            ;;
        list)
            shift; list_cmd "$@"
            ;;
        --generate-completion)
            local shell="${2:-bash}"
            generate_completion "$shell"
            ;;
        --help|-h)
            show_help
            ;;
        *)
            die "unknown command: $1"
            ;;
    esac
}

main "$@"