# XRDP VDI Audio Pipeline - Custom FIFO-based Implementation

## Project Overview

I am modifying the xrdp PipeWire audio module to replace Unix socket communication 
with FIFO-based audio routing. This will integrate with external ffmpeg processes 
for encoding/decoding, eventually supporting video+audio calls in VDI environments.

## Repository Information

- **Base Repository**: https://github.com/neutrinolabs/pipewire-module-xrdp
- **Branch**: devel
- **Main File**: src/module-xrdp.c (~1500 lines)
- **Build System**: Meson + Ninja

## Architecture Goals

### Current Architecture (to be removed):
```
Application → PipeWire → module-xrdp → Unix Socket → xrdp chansrv → RDP Protocol
```

### Target Architecture:
```
Application → PipeWire → module-xrdp → FIFO → ffmpeg → Custom Video Call System
```

## Technical Requirements

### 1. Audio Paths

**Speaker Path (Playback):**
- PipeWire Sink → module-xrdp → Write to FIFO → ffmpeg reads → Encode to Opus

**Microphone Path (Capture):**
- ffmpeg writes decoded PCM → FIFO → module-xrdp reads → PipeWire Source

### 2. FIFO Configuration

**Environment Variables:**
- `XRDP_AUDIO_SPK_FIFO`: Speaker FIFO path (default: `/run/user/$(id -u)/xrdp_spk.pcm`)
- `XRDP_AUDIO_MIC_FIFO`: Microphone FIFO path (default: `/run/user/$(id -u)/xrdp_mic.pcm`)
- `XRDP_AUDIO_FORMAT_FILE`: Format specification file (default: `/run/user/$(id -u)/xrdp_audio_format.txt`)

### 3. Format Negotiation (CRITICAL)

**Must support flexible PipeWire negotiation:**
- Formats: S16LE, S24LE, S32LE, F32LE
- Sample Rates: 8000, 16000, 22050, 44100, 48000, 96000 Hz
- Channels: 1 (mono), 2 (stereo)

**When format changes:**
1. PipeWire negotiates with application
2. `param_changed()` callback fires in module
3. Module updates format specification file
4. External ffmpeg manager script reads file and restarts processes

### 4. Error Handling Requirements

**Graceful Degradation:**
- Speaker FIFO full (EAGAIN): Drop audio frames silently
- Mic FIFO empty (EAGAIN): Fill PipeWire buffer with silence
- Broken pipe (EPIPE): Attempt automatic reconnection
- Missing reader/writer: Handle gracefully without blocking

**Auto-Reconnection:**
- Detect broken pipes
- Close and reopen FIFOs
- Log reconnection attempts
- Continue operation without crashing

## Implementation Checklist

### Phase 1: Code Modifications

- [ ] Remove xrdp socket connection code
- [ ] Remove `PA_CMD_*` protocol handling
- [ ] Remove all xrdp-specific defines and structures
- [ ] Add FIFO management functions:
  - [ ] `open_speaker_fifo()`
  - [ ] `open_mic_fifo()`
  - [ ] `reconnect_fifo()`
  - [ ] `close_fifos()`
- [ ] Modify stream callbacks:
  - [ ] `on_sink_process()` - write raw PCM to speaker FIFO
  - [ ] `on_source_process()` - read raw PCM from mic FIFO
- [ ] Add format change handlers:
  - [ ] `on_sink_param_changed()`
  - [ ] `on_source_param_changed()`
  - [ ] `write_format_spec()`
- [ ] Add format conversion helpers:
  - [ ] `format_to_string()`
  - [ ] `calc_frame_size()`
- [ ] Expand format enumeration to support multiple formats
- [ ] Update module initialization
- [ ] Update module cleanup

### Phase 2: Supporting Scripts

- [ ] Create `ffmpeg_manager.sh` watchdog script:
  - [ ] Monitor format specification file
  - [ ] Start/restart ffmpeg processes on format change
  - [ ] Handle process crashes
  - [ ] Proper signal handling (SIGHUP for reload)
- [ ] Create test scripts:
  - [ ] FIFO smoke test
  - [ ] Audio loopback test
  - [ ] Format change test

### Phase 3: Build & Test

- [ ] Ensure code compiles without errors
- [ ] Test module loading
- [ ] Verify FIFO creation
- [ ] Test audio playback path
- [ ] Test audio capture path
- [ ] Test format negotiation
- [ ] Test reconnection logic

## Key Code Sections to Modify

### 1. Remove (lines ~300-600):
- `connect_xrdp_socket()`
- `close_send_sink()` / `close_send_source()`
- All `PA_CMD_*` message handling
- `struct xrdp_msg_header`

### 2. Modify (lines ~600-900):
- `on_sink_process()`: Replace socket write with FIFO write
- `on_source_process()`: Replace socket read with FIFO read

### 3. Add New:
- Format specification file writing
- FIFO management with O_NONBLOCK
- Auto-reconnection logic
- Expanded format enumeration

### 4. Keep Mostly Unchanged:
- PipeWire stream setup
- Module registration and metadata
- Core PipeWire API integration

## Format Specification File Structure
```
# /run/user/$(id -u)/xrdp_audio_format.txt
speaker_rate=48000
speaker_channels=2
speaker_format=s16le
mic_rate=48000
mic_channels=1
mic_format=s16le
timestamp=1234567890
```

## Example ffmpeg Commands

**Speaker Encoder:**
```bash
ffmpeg -f s16le -ar 48000 -ac 2 \
       -i /run/user/$(id -u)/xrdp_spk.pcm \
       -c:a libopus -b:a 64k \
       -frame_duration 20 -application voip \
       output.opus
```

**Microphone Decoder:**
```bash
ffmpeg -re -i input.opus \
       -ar 48000 -ac 1 \
       -f s16le \
       /run/user/$(id -u)/xrdp_mic.pcm
```

## Critical Implementation Notes

1. **Non-blocking I/O**: All FIFO operations use O_NONBLOCK to prevent deadlocks
2. **Stale FIFO cleanup**: Remove old FIFOs on module init using `unlink()`
3. **Frame alignment**: Always read/write multiples of frame_size
4. **Throttle format writes**: Don't spam format file (max once per 2 seconds)
5. **Buffer sizes**: Standard PipeWire buffer sizes (typically 960-1024 samples)

## Testing Strategy

### Level 1: Module Compilation
```bash
meson setup build
cd build
ninja
```

### Level 2: FIFO Creation
```bash
# Check if FIFOs are created
ls -lh /run/user/$(id -u)/xrdp_*.pcm
```

### Level 3: Manual Audio Test
```bash
# Terminal 1: Generate test audio
ffmpeg -f lavfi -i "sine=frequency=440:duration=10" \
       -ar 48000 -ac 1 -f s16le /run/user/$(id -u)/xrdp_mic.pcm

# Terminal 2: Load module and check
pw-cli load-module libpipewire-module-xrdp
pactl list sources | grep -i xrdp
```

### Level 4: Loopback Test
```bash
# Connect speaker FIFO to mic FIFO
ffmpeg -f s16le -ac 2 -ar 48000 \
       -i /run/user/$(id -u)/xrdp_spk.pcm \
       -ac 1 -ar 48000 -f s16le \
       /run/user/$(id -u)/xrdp_mic.pcm
```

## Dependencies
```bash
# Ubuntu/Debian
sudo apt-get install -y \
    meson \
    ninja-build \
    pkg-config \
    libpipewire-0.3-dev \
    libspa-0.2-dev \
    ffmpeg

# RHEL/Rocky Linux
sudo dnf install -y \
    meson \
    ninja-build \
    pkgconfig \
    pipewire-devel \
    ffmpeg
```

## Environment Setup

I am working on:
- OS: Ubuntu 24 / RHEL 9 / Rocky Linux 9
- Desktop: Cinnamon / GNOME
- XRDP Session: Remote desktop environment
- User run directory: `/run/user/$(id -u)`

## End Goal

A working PipeWire module that:
1. Exposes virtual speaker/mic in VDI session
2. Routes raw PCM through FIFOs
3. Dynamically adapts to format changes
4. Handles errors gracefully
5. Works with external ffmpeg for encoding/decoding
6. Will eventually integrate with virtual webcam for video calls

## Questions to Consider

1. Should we implement statistics tracking (dropped frames, reconnects)?
2. How should we handle rapid format changes (debouncing)?
3. Should FIFO paths be configurable per-user or system-wide?
4. What logging level is appropriate (debug, info, warn)?

---

## Working with Claude Code

Please help me:
1. Set up the project structure correctly
2. Implement the modifications described above
3. Test incrementally as we build
4. Debug any compilation or runtime errors
5. Create the supporting scripts (ffmpeg_manager.sh)

Start by examining the current codebase structure and identifying the exact lines 
that need to be modified or removed.
