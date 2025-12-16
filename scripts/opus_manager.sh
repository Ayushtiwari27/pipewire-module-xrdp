#!/bin/bash

# SyncCast Opus Audio Manager
# Handles Opus encoding/decoding for SyncCast audio FIFOs

set -e

# Configuration
USER_ID=$(id -u)
RUNTIME_DIR="/run/user/$USER_ID"
SPEAKER_FIFO="$RUNTIME_DIR/synccast_spk.pcm"
MIC_FIFO="$RUNTIME_DIR/synccast_mic.pcm"
FORMAT_FILE="$RUNTIME_DIR/synccast_audio_format.txt"

# Opus settings
OPUS_BITRATE="${SYNCCAST_OPUS_BITRATE:-64000}"      # 64kbps default
OPUS_COMPLEXITY="${SYNCCAST_OPUS_COMPLEXITY:-10}"   # Max quality
OPUS_FRAME_DURATION="${SYNCCAST_OPUS_FRAME:-20}"    # 20ms frames
OPUS_APPLICATION="${SYNCCAST_OPUS_APP:-voip}"       # voip/audio/lowdelay

# Output settings
OPUS_SPEAKER_OUTPUT="${SYNCCAST_OPUS_SPEAKER_OUT:-$RUNTIME_DIR/synccast_speaker.opus}"
OPUS_MIC_INPUT="${SYNCCAST_OPUS_MIC_IN:-$RUNTIME_DIR/synccast_mic.opus}"

# Alternatively, use RTP for network streaming
USE_RTP="${SYNCCAST_USE_RTP:-false}"
RTP_SPEAKER_HOST="${SYNCCAST_RTP_HOST:-127.0.0.1}"
RTP_SPEAKER_PORT="${SYNCCAST_RTP_SPEAKER_PORT:-5004}"
RTP_MIC_PORT="${SYNCCAST_RTP_MIC_PORT:-5006}"

# PID files
SPEAKER_PID_FILE="$RUNTIME_DIR/opus_speaker_encoder.pid"
MIC_PID_FILE="$RUNTIME_DIR/opus_mic_decoder.pid"

# Log files
SPEAKER_LOG="$RUNTIME_DIR/opus_speaker_encoder.log"
MIC_LOG="$RUNTIME_DIR/opus_mic_decoder.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

# Read audio format from format file
read_audio_format() {
    if [ ! -f "$FORMAT_FILE" ]; then
        log_warn "Format file not found, using defaults"
        SAMPLE_RATE=48000
        CHANNELS=2
        return
    fi
    
    SAMPLE_RATE=$(grep "^speaker_rate=" "$FORMAT_FILE" | cut -d'=' -f2)
    CHANNELS=$(grep "^speaker_channels=" "$FORMAT_FILE" | cut -d'=' -f2)
    
    SAMPLE_RATE=${SAMPLE_RATE:-48000}
    CHANNELS=${CHANNELS:-2}
    
    log_info "Audio format: ${SAMPLE_RATE}Hz, ${CHANNELS} channels"
}

# Start speaker encoder (FIFO → Opus)
start_speaker_encoder() {
    if [ -f "$SPEAKER_PID_FILE" ]; then
        PID=$(cat "$SPEAKER_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            log_warn "Speaker encoder already running (PID: $PID)"
            return 0
        fi
    fi
    
    read_audio_format
    
    log_info "Starting speaker encoder..."
    log_info "  Input: $SPEAKER_FIFO (raw PCM)"
    log_info "  Codec: Opus @ ${OPUS_BITRATE}bps, ${OPUS_COMPLEXITY} complexity"
    
    if [ "$USE_RTP" = "true" ]; then
        # Stream via RTP
        log_info "  Output: RTP to ${RTP_SPEAKER_HOST}:${RTP_SPEAKER_PORT}"
        
        ffmpeg -f s16le -ar "$SAMPLE_RATE" -ac "$CHANNELS" -i "$SPEAKER_FIFO" \
            -c:a libopus -b:a "$OPUS_BITRATE" -compression_level "$OPUS_COMPLEXITY" \
            -frame_duration "$OPUS_FRAME_DURATION" -application "$OPUS_APPLICATION" \
            -f rtp "rtp://${RTP_SPEAKER_HOST}:${RTP_SPEAKER_PORT}" \
            >> "$SPEAKER_LOG" 2>&1 &
    else
        # Save to file
        log_info "  Output: $OPUS_SPEAKER_OUTPUT"
        
        ffmpeg -f s16le -ar "$SAMPLE_RATE" -ac "$CHANNELS" -i "$SPEAKER_FIFO" \
            -c:a libopus -b:a "$OPUS_BITRATE" -compression_level "$OPUS_COMPLEXITY" \
            -frame_duration "$OPUS_FRAME_DURATION" -application "$OPUS_APPLICATION" \
            -f opus "$OPUS_SPEAKER_OUTPUT" \
            >> "$SPEAKER_LOG" 2>&1 &
    fi
    
    SPEAKER_PID=$!
    echo "$SPEAKER_PID" > "$SPEAKER_PID_FILE"
    
    sleep 1
    if kill -0 "$SPEAKER_PID" 2>/dev/null; then
        log_info "Speaker encoder started successfully (PID: $SPEAKER_PID)"
        return 0
    else
        log_error "Speaker encoder failed to start"
        return 1
    fi
}

# Start mic decoder (Opus → FIFO)
start_mic_decoder() {
    if [ -f "$MIC_PID_FILE" ]; then
        PID=$(cat "$MIC_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            log_warn "Mic decoder already running (PID: $PID)"
            return 0
        fi
    fi
    
    read_audio_format
    
    log_info "Starting mic decoder..."
    
    if [ "$USE_RTP" = "true" ]; then
        # Receive via RTP
        log_info "  Input: RTP from port ${RTP_MIC_PORT}"
        log_info "  Output: $MIC_FIFO (raw PCM)"
        
        ffmpeg -protocol_whitelist file,rtp,udp \
            -i "rtp://0.0.0.0:${RTP_MIC_PORT}" \
            -f s16le -ar "$SAMPLE_RATE" -ac "$CHANNELS" \
            "$MIC_FIFO" \
            >> "$MIC_LOG" 2>&1 &
    else
        # Read from file (for testing)
        if [ ! -f "$OPUS_MIC_INPUT" ]; then
            log_warn "Mic input file not found: $OPUS_MIC_INPUT"
            log_warn "Creating silent mic stream..."
            
            # Generate silence
            ffmpeg -f lavfi -i "anullsrc=r=${SAMPLE_RATE}:cl=${CHANNELS}" \
                -f s16le -ar "$SAMPLE_RATE" -ac "$CHANNELS" \
                "$MIC_FIFO" \
                >> "$MIC_LOG" 2>&1 &
        else
            log_info "  Input: $OPUS_MIC_INPUT"
            log_info "  Output: $MIC_FIFO (raw PCM)"
            
            ffmpeg -stream_loop -1 -i "$OPUS_MIC_INPUT" \
                -f s16le -ar "$SAMPLE_RATE" -ac "$CHANNELS" \
                "$MIC_FIFO" \
                >> "$MIC_LOG" 2>&1 &
        fi
    fi
    
    MIC_PID=$!
    echo "$MIC_PID" > "$MIC_PID_FILE"
    
    sleep 1
    if kill -0 "$MIC_PID" 2>/dev/null; then
        log_info "Mic decoder started successfully (PID: $MIC_PID)"
        return 0
    else
        log_error "Mic decoder failed to start"
        return 1
    fi
}

# Stop processes
stop_all() {
    log_info "Stopping Opus encoder/decoder..."
    
    if [ -f "$SPEAKER_PID_FILE" ]; then
        PID=$(cat "$SPEAKER_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null
            log_info "Stopped speaker encoder (PID: $PID)"
        fi
        rm -f "$SPEAKER_PID_FILE"
    fi
    
    if [ -f "$MIC_PID_FILE" ]; then
        PID=$(cat "$MIC_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null
            log_info "Stopped mic decoder (PID: $PID)"
        fi
        rm -f "$MIC_PID_FILE"
    fi
    
    log_info "All processes stopped"
}

# Status check
status() {
    echo "SyncCast Opus Audio Manager Status"
    echo "==============================="
    echo
    echo "Configuration:"
    echo "  Opus bitrate: ${OPUS_BITRATE}bps"
    echo "  Complexity: $OPUS_COMPLEXITY"
    echo "  Frame duration: ${OPUS_FRAME_DURATION}ms"
    echo "  Application: $OPUS_APPLICATION"
    echo "  Use RTP: $USE_RTP"
    echo
    
    read_audio_format
    
    echo "Speaker Encoder:"
    if [ -f "$SPEAKER_PID_FILE" ]; then
        PID=$(cat "$SPEAKER_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            echo "  Status: RUNNING (PID: $PID)"
        else
            echo "  Status: STOPPED (stale PID file)"
        fi
    else
        echo "  Status: STOPPED"
    fi
    
    echo
    echo "Mic Decoder:"
    if [ -f "$MIC_PID_FILE" ]; then
        PID=$(cat "$MIC_PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            echo "  Status: RUNNING (PID: $PID)"
        else
            echo "  Status: STOPPED (stale PID file)"
        fi
    else
        echo "  Status: STOPPED"
    fi
    
    echo
    echo "Log files:"
    echo "  Speaker: $SPEAKER_LOG"
    echo "  Mic: $MIC_LOG"
}

# Main command handler
case "${1:-start}" in
    start)
        start_speaker_encoder
        start_mic_decoder
        ;;
    stop)
        stop_all
        ;;
    restart)
        stop_all
        sleep 1
        start_speaker_encoder
        start_mic_decoder
        ;;
    status)
        status
        ;;
    speaker)
        start_speaker_encoder
        ;;
    mic)
        start_mic_decoder
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|speaker|mic}"
        echo
        echo "Environment variables:"
        echo "  SYNCCAST_OPUS_BITRATE      - Opus bitrate (default: 64000)"
        echo "  SYNCCAST_OPUS_COMPLEXITY   - Opus complexity 0-10 (default: 10)"
        echo "  SYNCCAST_OPUS_FRAME        - Frame duration in ms (default: 20)"
        echo "  SYNCCAST_OPUS_APP          - Application: voip/audio/lowdelay (default: voip)"
        echo "  SYNCCAST_USE_RTP           - Use RTP streaming (default: false)"
        echo "  SYNCCAST_RTP_HOST          - RTP destination host (default: 127.0.0.1)"
        echo "  SYNCCAST_RTP_SPEAKER_PORT  - RTP speaker port (default: 5004)"
        echo "  SYNCCAST_RTP_MIC_PORT      - RTP mic port (default: 5006)"
        exit 1
        ;;
esac
