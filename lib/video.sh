#!/bin/bash
# lib/video.sh — CoreX Pro
# Make QuickTime recordings playable in the apps people already use.
#
# THE PROBLEM, STATED PRECISELY, BECAUSE THE OBVIOUS DIAGNOSIS IS WRONG
#
# A video stored in Nextcloud can refuse to play in the Nextcloud app and in
# every browser while being completely intact. The reported symptom is about
# size ("the 3GB one will not play") and size has nothing to do with it.
#
# Every video an iPhone records is a .mov whose container is QuickTime, not
# MP4. The first bytes of the file say so:
#
#   ftyp qt      <- QuickTime. HTML5 video cannot play this.
#   ftyp isom    <- MP4. Plays everywhere.
#
# The codecs inside are usually H.264 and AAC, which every device decodes in
# hardware. So the media is fine and only the wrapper is wrong, and a player
# that checks the container refuses the file before it ever looks at a frame.
# Nextcloud reports the mimetype correctly as video/quicktime, the browser
# correctly says it cannot play video/quicktime, and nothing anywhere is
# broken. It just does not work.
#
# THE FIX IS A REWRAP, NOT A CONVERSION
#
# Rewriting the container copies the audio and video streams through
# untouched: no decoding, no re-encoding, no quality change, and none of the
# CPU load that makes converting video dangerous on this hardware (gotcha
# #31). Measured on a 3.8GB three hour recording: 17 seconds, and the CPU went
# from 58.9C to 66.4C, which is nowhere near the shed threshold.
#
# A re-encode of the same file would take hours and pin every core. This
# module will not do that under any circumstances: if the streams cannot be
# copied into an MP4 as they are, the file is reported and left alone.

# Containers worth rewrapping. A file is a candidate only when the container
# is QuickTime AND every stream is something MP4 can legally hold, which is
# what keeps this a copy rather than a conversion.
_VIDEO_OK_VCODECS="h264 hevc mpeg4 av1"
_VIDEO_OK_ACODECS="aac mp3 ac3 eac3 alac"

# The ffmpeg CoreX already fetched for Nextcloud thumbnails, reused rather
# than fetched twice.
_video_ffmpeg() { echo "${DATA_ROOT:-/mnt/corex-data/service-data}/ffmpeg-shared/ffmpeg"; }
_video_ffprobe() { echo "${DATA_ROOT:-/mnt/corex-data/service-data}/ffmpeg-shared/ffprobe"; }

_video_tools_present() {
    local ff; ff="$(_video_ffmpeg)"
    local fp; fp="$(_video_ffprobe)"
    [[ -x "$ff" && -x "$fp" ]] && "$ff" -version >/dev/null 2>&1
}

# Is this file a QuickTime container whose streams MP4 can hold as they are?
# Prints "why" on stdout, returns 0 when it should be rewrapped.
#
# The brand is read from the file rather than from the extension, because the
# extension is what made this confusing in the first place: plenty of .mov
# files are already MP4 inside, and rewrapping those would be pointless work.
_video_needs_rewrap() {
    local f="$1" brand
    brand=$(head -c 12 "$f" 2>/dev/null | tail -c 4 | tr -d '\0')
    # "qt  " is QuickTime. isom, mp42, iso5 and friends are already MP4.
    [[ "$brand" == "qt"* ]] || return 1

    local probe vcodec acodec
    probe=$("$(_video_ffprobe)" -v error -select_streams v:0 -show_entries stream=codec_name \
            -of default=nw=1:nk=1 "$f" 2>/dev/null | head -1)
    vcodec="${probe:-none}"
    acodec=$("$(_video_ffprobe)" -v error -select_streams a:0 -show_entries stream=codec_name \
            -of default=nw=1:nk=1 "$f" 2>/dev/null | head -1)
    acodec="${acodec:-none}"

    case " ${_VIDEO_OK_VCODECS} " in *" ${vcodec} "*) ;; *) return 1 ;; esac
    [[ "$acodec" == "none" ]] || case " ${_VIDEO_OK_ACODECS} " in
        *" ${acodec} "*) ;; *) return 1 ;;
    esac
    echo "${vcodec}/${acodec}"
    return 0
}

# Every video under a path, newline separated. find -print0 would be safer but
# these paths come from a filesystem the operator named, and the loop below
# reads with IFS= and -r, so only a newline inside a filename breaks it.
_video_candidates() {
    find "$1" -type f \( -iname '*.mov' -o -iname '*.qt' \) 2>/dev/null | sort
}

# ── Report ────────────────────────────────────────────────────────────────────

video_scan() {
    local root="${1:-}"
    [[ -d "$root" ]] || { log_error "Not a directory: ${root}"; return 1; }
    _video_tools_present || {
        log_warning "No ffmpeg yet. It arrives with Nextcloud:  sudo corex manage repair nextcloud"
        return 1
    }

    local n=0 bytes=0 f why sz
    echo
    echo "Videos that will not play in a browser or the Nextcloud app:"
    echo
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        why=$(_video_needs_rewrap "$f") || continue
        sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        n=$((n + 1)); bytes=$((bytes + sz))
        printf '  %6.2f GB  %-14s %s\n' "$(awk "BEGIN{print ${sz}/1073741824}")" "$why" "${f##*/}"
    done < <(_video_candidates "$root")

    echo
    if (( n == 0 )); then
        log_success "Nothing to do: no QuickTime-wrapped video found under ${root}"
        return 0
    fi
    printf '  %d file(s), %.1f GB. The video and audio inside are fine; only the\n' \
        "$n" "$(awk "BEGIN{print ${bytes}/1073741824}")"
    echo "  container is one browsers refuse. Rewrapping copies the streams"
    echo "  untouched, so nothing is re-encoded and no quality is lost."
    echo
    echo "  Apply it with:  sudo corex manage video-fix --apply ${root}"
    echo
}

# ── Rewrap ────────────────────────────────────────────────────────────────────

# One file. Writes beside the original, verifies the result, and only then
# replaces it. The original is removed last, so an interruption at any point
# leaves either the original or both, never neither.
_video_rewrap_one() {
    local src="$1"
    local dst="${src%.*}.mp4"
    local tmp="${src%.*}.corex-rewrap.tmp.mp4"

    [[ -e "$dst" && "$dst" != "$src" ]] && {
        log_warning "  skipped, ${dst##*/} already exists"
        return 1
    }

    rm -f "$tmp"
    # -c copy is the whole point: streams are moved, never decoded. faststart
    # puts the index at the front so playback and seeking start immediately
    # instead of after a full download.
    if ! nice -n 19 "$(_video_ffmpeg)" -hide_banner -loglevel error \
            -i "$src" -c copy -movflags +faststart -f mp4 "$tmp" -y 2>/dev/null; then
        rm -f "$tmp"
        log_warning "  failed to rewrap, left alone: ${src##*/}"
        return 1
    fi

    # Verify before destroying anything. A file that exists is not a file that
    # plays, and the original is the only copy.
    local sd dd
    sd=$("$(_video_ffprobe)" -v error -show_entries format=duration -of default=nw=1:nk=1 "$src" 2>/dev/null)
    dd=$("$(_video_ffprobe)" -v error -show_entries format=duration -of default=nw=1:nk=1 "$tmp" 2>/dev/null)
    if [[ -z "$dd" ]] || awk "BEGIN{exit !(($sd - $dd) > 1 || ($dd - $sd) > 1)}"; then
        rm -f "$tmp"
        log_warning "  output did not verify, original kept: ${src##*/}"
        return 1
    fi

    chown --reference="$src" "$tmp" 2>/dev/null || true
    chmod --reference="$src" "$tmp" 2>/dev/null || true
    touch --reference="$src" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
    [[ "$dst" != "$src" ]] && rm -f "$src"
    return 0
}

video_fix() {
    local root="${1:-}"
    [[ -d "$root" ]] || { log_error "Not a directory: ${root}"; return 1; }
    _video_tools_present || {
        log_warning "No ffmpeg yet. It arrives with Nextcloud:  sudo corex manage repair nextcloud"
        return 1
    }

    local list=() f why
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        why=$(_video_needs_rewrap "$f") || continue
        list+=("$f")
    done < <(_video_candidates "$root")

    (( ${#list[@]} )) || { log_success "Nothing to rewrap under ${root}"; return 0; }

    log_step "Rewrapping ${#list[@]} file(s). Streams are copied, nothing is re-encoded."
    local ok=0 bad=0
    for f in "${list[@]}"; do
        echo "  ${f##*/}"
        if _video_rewrap_one "$f"; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
    done

    log_success "Rewrapped ${ok} file(s)${bad:+, ${bad} left alone}"

    # Nextcloud tracks every file it owns in its own database, so a file that
    # changed name on disk does not exist until it is scanned. Without this the
    # operator sees the old entry, clicks it and gets a 404, which looks like
    # the rewrap broke something.
    if container_running nextcloud 2>/dev/null && [[ "$root" == *"/nextcloud-html/data"* ]]; then
        log_info "Telling Nextcloud what changed on disk..."
        docker exec -u 33 nextcloud php occ files:scan --all --quiet >/dev/null 2>&1 \
            || log_warning "Scan did not finish. Run: docker exec -u 33 nextcloud php occ files:scan --all"
    fi

    # Jellyfin indexes the same files by path, so a rename leaves entries
    # pointing at files that are gone. Its filesystem watcher catches most of
    # them and does not catch all: measured after rewrapping eight files, six
    # were updated and two were still listed under their old name, which a
    # viewer meets as an item that will not open.
    #
    # There is no way to ask it to rescan without an API key, and minting one
    # to tidy up after a command would leave an admin credential behind for a
    # convenience. So the operator is told, in the one place they are already
    # looking.
    if container_running jellyfin 2>/dev/null; then
        echo
        log_warning "Jellyfin still lists some files under their old names."
        log_warning "  Fix it in Jellyfin: Dashboard > Libraries > Scan All Libraries."
        log_warning "  It also corrects itself on its next scheduled scan."
    fi
}
