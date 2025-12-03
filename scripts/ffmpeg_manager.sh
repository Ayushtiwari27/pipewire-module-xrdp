#!/bin/bash
#
# XRDP Audio FIFO Manager with FFmpeg
#
# This script monitors the audio format specification file and manages
# FFmpeg processes for encoding speaker audio and decoding microphone audio.
#
# Usage: ffmpeg_manager.sh [start|stop|restart|status]
#

set -e

# Configuration
USER_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SPK_FIFO="${XRDP_AUDIO_SPK_FIFO:-${USER_RUNTIME_DIR}/xrdp_spk.pcm}"
MIC_FIFO="${XRDP_AUDIO_MIC_FIFO:-${USER_RUNTIME_DIR}/xrdp_mic.pcm}"
FORMAT_FILE="${XRDP_AUDIO_FORMAT_FILE:-${USER_RUNTIME_DIR}/xrdp_audio_format.txt}"

# Output files (you can modify these for your use case)
SPEAKER_OUTPUT="${USER_RUNTIME_DIR}/xrdp_speaker_encoded.opus"
MIC_INPUT="${USER_RUNTIME_DIR}/xrdp_mic_decoded.opus"

# PID files
SPK_PID_FILE="${USER_RUNTIME_DIR}/xrdp_ffmpeg_speaker.pid"
MIC_PID_FILE="${USER_RUNTIME_DIR}/xrdp_ffmpeg_mic.pid"

# Log files
SPK_LOG_FILE="${USER_RUNTIME_DIR}/xrdp_ffmpeg_speaker.log"
MIC_LOG_FILE="${USER_RUNTIME_DIR}/xrdp_ffmpeg_mic.log"

# Current format values
SPEAKER_RATE=48000
SPEAKER_CHANNELS=2
SPEAKER_FORMAT="s16le"
MIC_RATE=48000
MIC_CHANNELS=1
MIC_FORMAT="s16le"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

read_format_spec() {
    if [ ! -f "$FORMAT_FILE" ]; then
        log "Format file not found: $FORMAT_FILE"
        return 1
    fi

    # Parse format file
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue

        case "$key" in
            speaker_rate) SPEAKER_RATE="$value" ;;
            speaker_channels) SPEAKER_CHANNELS="$value" ;;
            speaker_format) SPEAKER_FORMAT="$value" ;;
            mic_rate) MIC_RATE="$value" ;;
            mic_channels) MIC_CHANNELS="$value" ;;
            mic_format) MIC_FORMAT="$value" ;;
        esac
    done < "$FORMAT_FILE"

    log "Format spec: SPK(${SPEAKER_RATE}Hz ${SPEAKER_CHANNELS}ch ${SPEAKER_FORMAT}) MIC(${MIC_RATE}Hz ${MIC_CHANNELS}ch ${MIC_FORMAT})"
}

start_speaker_encoder() {
    log "Starting speaker encoder..."

    # Kill old process if exists
    if [ -f "$SPK_PID_FILE" ]; then
        old_pid=$(cat "$SPK_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            log "Stopping old speaker encoder (PID: $old_pid)"
            kill "$old_pid" 2>/dev/null || true
            sleep 0.5
        fi
        rm -f "$SPK_PID_FILE"
    fi

    # Start FFmpeg encoder (speaker FIFO -> opus file)
    nohup ffmpeg -f "${SPEAKER_FORMAT}" -ar "${SPEAKER_RATE}" -ac "${SPEAKER_CHANNELS}" \
                 -i "${SPK_FIFO}" \
                 -c:a libopus -b:a 64k -frame_duration 20 -application voip \
                 -y "${SPEAKER_OUTPUT}" \
                 >> "${SPK_LOG_FILE}" 2>&1 &

    echo $! > "$SPK_PID_FILE"
    log "Speaker encoder started (PID: $(cat "$SPK_PID_FILE"))"
}

start_mic_decoder() {
    log "Starting mic decoder..."

    # Kill old process if exists
    if [ -f "$MIC_PID_FILE" ]; then
        old_pid=$(cat "$MIC_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            log "Stopping old mic decoder (PID: $old_pid)"
            kill "$old_pid" 2>/dev/null || true
            sleep 0.5
        fi
        rm -f "$MIC_PID_FILE"
    fi

    # Create a silent input file if mic input doesn't exist
    if [ ! -f "$MIC_INPUT" ]; then
        log "Creating silent mic input file..."
        ffmpeg -f lavfi -i "anullsrc=r=${MIC_RATE}:cl=mono" -t 3600 \
               -c:a libopus -b:a 32k "$MIC_INPUT" -y >/dev/null 2>&1 &
    fi

    # Start FFmpeg decoder (opus file -> mic FIFO)
    nohup ffmpeg -re -stream_loop -1 -i "${MIC_INPUT}" \
                 -ar "${MIC_RATE}" -ac "${MIC_CHANNELS}" \
                 -f "${MIC_FORMAT}" "${MIC_FIFO}" \
                 >> "${MIC_LOG_FILE}" 2>&1 &

    echo $! > "$MIC_PID_FILE"
    log "Mic decoder started (PID: $(cat "$MIC_PID_FILE"))"
}

stop_processes() {
    log "Stopping FFmpeg processes..."

    if [ -f "$SPK_PID_FILE" ]; then
        pid=$(cat "$SPK_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log "Stopped speaker encoder (PID: $pid)"
        fi
        rm -f "$SPK_PID_FILE"
    fi

    if [ -f "$MIC_PID_FILE" ]; then
        pid=$(cat "$MIC_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log "Stopped mic decoder (PID: $pid)"
        fi
        rm -f "$MIC_PID_FILE"
    fi
}

status() {
    echo "XRDP Audio FIFO Manager Status"
    echo "==============================="
    echo ""
    echo "Configuration:"
    echo "  Speaker FIFO: $SPK_FIFO"
    echo "  Mic FIFO: $MIC_FIFO"
    echo "  Format File: $FORMAT_FILE"
    echo ""

    if [ -f "$FORMAT_FILE" ]; then
        echo "Current Format:"
        cat "$FORMAT_FILE"
        echo ""
    else
        echo "Format file not found"
        echo ""
    fi

    echo "Processes:"
    if [ -f "$SPK_PID_FILE" ]; then
        pid=$(cat "$SPK_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "  Speaker encoder: RUNNING (PID: $pid)"
        else
            echo "  Speaker encoder: STOPPED (stale PID file)"
        fi
    else
        echo "  Speaker encoder: STOPPED"
    fi

    if [ -f "$MIC_PID_FILE" ]; then
        pid=$(cat "$MIC_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "  Mic decoder: RUNNING (PID: $pid)"
        else
            echo "  Mic decoder: STOPPED (stale PID file)"
        fi
    else
        echo "  Mic decoder: STOPPED"
    fi
    echo ""
}

watch_format_file() {
    log "Starting format file watcher..."
    log "Monitoring: $FORMAT_FILE"

    # Initial start
    if read_format_spec; then
        start_speaker_encoder
        start_mic_decoder
    else
        log "Waiting for format file to appear..."
    fi

    # Watch for changes
    last_mtime=0
    while true; do
        if [ -f "$FORMAT_FILE" ]; then
            current_mtime=$(stat -c %Y "$FORMAT_FILE" 2>/dev/null || echo 0)
            if [ "$current_mtime" != "$last_mtime" ]; then
                log "Format file changed, restarting FFmpeg..."
                if read_format_spec; then
                    start_speaker_encoder
                    start_mic_decoder
                fi
                last_mtime=$current_mtime
            fi
        fi
        sleep 2
    done
}

case "${1:-start}" in
    start)
        log "Starting XRDP Audio FIFO Manager..."
        watch_format_file
        ;;
    stop)
        stop_processes
        log "XRDP Audio FIFO Manager stopped"
        ;;
    restart)
        stop_processes
        sleep 1
        if read_format_spec; then
            start_speaker_encoder
            start_mic_decoder
        fi
        log "XRDP Audio FIFO Manager restarted"
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
