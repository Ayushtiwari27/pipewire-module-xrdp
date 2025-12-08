# Quick Start Brief for Claude Code

## Project
Modify pipewire-module-xrdp to use FIFOs instead of Unix sockets.

## Current Location
File: src/module-xrdp.c (~1500 lines)

## What to Do
1. **Remove**: All xrdp socket and protocol code (~lines 300-600)
2. **Add**: FIFO management functions
3. **Modify**: Stream callbacks to use raw PCM over FIFOs
4. **Implement**: Flexible PipeWire format negotiation
5. **Create**: ffmpeg_manager.sh watchdog script

## Key Changes

### Remove These:
- `connect_xrdp_socket()`
- `PA_CMD_*` defines
- `struct xrdp_msg_header`
- Socket protocol handling

### Add These:
- `open_speaker_fifo()` / `open_mic_fifo()`
- `write_format_spec()` - writes format to file
- `on_sink_param_changed()` - handles format changes
- `on_source_param_changed()` - handles format changes
- FIFO reconnection logic

### Modify These:
- `on_sink_process()` - write raw PCM to FIFO (no protocol wrapper)
- `on_source_process()` - read raw PCM from FIFO (no protocol unwrap)
- `module_init()` - open FIFOs instead of sockets
- `module_cleanup()` - close FIFOs

## Build & Test
```bash
meson setup build && cd build && ninja
sudo ninja install
pw-cli load-module libpipewire-module-xrdp
```

## Format File Location
`/run/user/$(id -u)/xrdp_audio_format.txt`

Contains:
- speaker_rate, speaker_channels, speaker_format
- mic_rate, mic_channels, mic_format  
- timestamp

## Error Handling
- EAGAIN on write: drop frame
- EAGAIN on read: fill with silence
- EPIPE: reconnect FIFO
- Missing reader/writer: handle gracefully

## Full Context
See PROJECT_CONTEXT.md for complete details.
