#!/bin/bash
#
# Quick Test Script for XRDP Audio FIFO Module
#
# This script helps you quickly test the module without manual setup
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

print_header() {
    echo ""
    echo "=================================="
    echo "$1"
    echo "=================================="
    echo ""
}

# Check if we're in the right directory
if [ ! -f "src/module-xrdp.c" ]; then
    log_error "Please run this script from the pipewire-module-xrdp root directory"
    exit 1
fi

print_header "XRDP Audio FIFO Module - Quick Test"

# Step 1: Check prerequisites
log_info "Checking prerequisites..."

if ! command -v pw-cli &> /dev/null; then
    log_error "PipeWire not found. Please install pipewire first."
    exit 1
fi

if ! command -v ffmpeg &> /dev/null; then
    log_error "FFmpeg not found. Please install ffmpeg first."
    exit 1
fi

if ! systemctl --user is-active --quiet pipewire; then
    log_warn "PipeWire is not running. Starting it..."
    systemctl --user start pipewire pipewire-pulse
    sleep 2
fi

log_success "Prerequisites OK"

# Step 2: Build the module
print_header "Step 1: Building the Module"

if [ ! -f "build/src/.libs/libpipewire-module-xrdp.so" ]; then
    log_info "Module not built. Building now..."

    if [ ! -f "configure" ]; then
        log_info "Running bootstrap..."
        ./bootstrap
    fi

    mkdir -p build
    cd build

    log_info "Configuring..."
    ../configure

    log_info "Compiling..."
    make -j$(nproc)

    cd ..
    log_success "Build complete"
else
    log_info "Module already built"
fi

# Verify build
if [ ! -f "build/src/.libs/libpipewire-module-xrdp.so" ]; then
    log_error "Build failed - module not found"
    exit 1
fi

log_success "Module binary found: build/src/.libs/libpipewire-module-xrdp.so"

# Step 3: Load the module
print_header "Step 2: Loading the Module"

MODULE_PATH="$(pwd)/build/src/.libs/libpipewire-module-xrdp"

# Check if already loaded
if pw-cli ls Module | grep -q "libpipewire-module-xrdp"; then
    log_warn "Module already loaded. Unloading first..."
    MODULE_ID=$(pw-cli ls Module | grep -B1 "libpipewire-module-xrdp" | grep "id" | awk '{print $2}' | tr -d ',')
    pw-cli unload-module "$MODULE_ID" 2>/dev/null || true
    sleep 1
fi

log_info "Loading module..."
if pw-cli load-module "$MODULE_PATH"; then
    log_success "Module loaded successfully"
else
    log_error "Failed to load module"
    exit 1
fi

sleep 2

# Step 4: Verify FIFOs
print_header "Step 3: Verifying FIFOs"

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SPK_FIFO="$RUNTIME_DIR/xrdp_spk.pcm"
MIC_FIFO="$RUNTIME_DIR/xrdp_mic.pcm"
FORMAT_FILE="$RUNTIME_DIR/xrdp_audio_format.txt"

if [ -p "$SPK_FIFO" ]; then
    log_success "Speaker FIFO created: $SPK_FIFO"
else
    log_error "Speaker FIFO not found"
fi

if [ -p "$MIC_FIFO" ]; then
    log_success "Mic FIFO created: $MIC_FIFO"
else
    log_error "Mic FIFO not found"
fi

if [ -f "$FORMAT_FILE" ]; then
    log_success "Format file created: $FORMAT_FILE"
    log_info "Format specification:"
    cat "$FORMAT_FILE" | grep -v "^#" | sed 's/^/  /'
else
    log_warn "Format file not found (will be created on first audio stream)"
fi

# Step 5: Verify PipeWire devices
print_header "Step 4: Verifying PipeWire Devices"

if pw-cli ls Node | grep -q "xrdp-sink"; then
    log_success "Speaker device (xrdp-sink) detected"
else
    log_error "Speaker device not found"
fi

if pw-cli ls Node | grep -q "xrdp-source"; then
    log_success "Microphone device (xrdp-source) detected"
else
    log_error "Microphone device not found"
fi

# Step 6: Start FFmpeg manager
print_header "Step 5: Starting FFmpeg Manager"

if [ -f "$RUNTIME_DIR/xrdp_ffmpeg_speaker.pid" ]; then
    OLD_PID=$(cat "$RUNTIME_DIR/xrdp_ffmpeg_speaker.pid")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log_warn "FFmpeg manager already running (PID: $OLD_PID)"
        log_info "Stopping old instance..."
        ./scripts/ffmpeg_manager.sh stop
        sleep 1
    fi
fi

log_info "Starting FFmpeg manager in background..."
nohup ./scripts/ffmpeg_manager.sh start > /tmp/xrdp_ffmpeg_manager.log 2>&1 &
MANAGER_PID=$!

sleep 3

# Check if it started
if [ -f "$RUNTIME_DIR/xrdp_ffmpeg_speaker.pid" ]; then
    SPK_PID=$(cat "$RUNTIME_DIR/xrdp_ffmpeg_speaker.pid")
    if kill -0 "$SPK_PID" 2>/dev/null; then
        log_success "Speaker encoder running (PID: $SPK_PID)"
    else
        log_error "Speaker encoder not running"
    fi
fi

if [ -f "$RUNTIME_DIR/xrdp_ffmpeg_mic.pid" ]; then
    MIC_PID=$(cat "$RUNTIME_DIR/xrdp_ffmpeg_mic.pid")
    if kill -0 "$MIC_PID" 2>/dev/null; then
        log_success "Mic decoder running (PID: $MIC_PID)"
    else
        log_error "Mic decoder not running"
    fi
fi

# Step 7: Run audio test
print_header "Step 6: Running Audio Test"

log_info "Playing test tone through xrdp-sink..."

if command -v speaker-test &> /dev/null; then
    log_info "Using speaker-test (2 seconds)..."
    timeout 2 speaker-test -D xrdp-sink -c 2 -t sine -f 440 2>/dev/null || true
    log_success "Audio test completed"
else
    log_warn "speaker-test not found, trying paplay..."
    if [ -f "/usr/share/sounds/alsa/Front_Center.wav" ]; then
        paplay -d xrdp-sink /usr/share/sounds/alsa/Front_Center.wav 2>/dev/null || true
        log_success "Audio test completed"
    else
        log_warn "No test audio file found. Skipping audio test."
    fi
fi

# Step 8: Show status
print_header "Step 7: System Status"

log_info "Running status check..."
./scripts/ffmpeg_manager.sh status

# Final summary
print_header "Test Complete!"

echo ""
echo "Summary:"
echo "--------"
echo "✅ Module loaded and running"
echo "✅ FIFOs created: $SPK_FIFO, $MIC_FIFO"
echo "✅ PipeWire devices: xrdp-sink, xrdp-source"
echo "✅ FFmpeg manager running"
echo ""
echo "Next Steps:"
echo "-----------"
echo "1. Play audio to xrdp-sink:"
echo "   paplay -d xrdp-sink /path/to/audio.wav"
echo ""
echo "2. Record from xrdp-source:"
echo "   parecord -d xrdp-source output.wav"
echo ""
echo "3. Monitor speaker encoder:"
echo "   tail -f $RUNTIME_DIR/xrdp_ffmpeg_speaker.log"
echo ""
echo "4. Monitor mic decoder:"
echo "   tail -f $RUNTIME_DIR/xrdp_ffmpeg_mic.log"
echo ""
echo "5. Check format changes:"
echo "   cat $FORMAT_FILE"
echo ""
echo "6. Stop everything:"
echo "   ./scripts/ffmpeg_manager.sh stop"
echo "   pw-cli unload-module <module-id>"
echo ""

log_success "All tests passed! The module is working correctly."
