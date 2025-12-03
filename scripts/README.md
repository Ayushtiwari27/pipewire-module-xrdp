# XRDP Audio FIFO Scripts

This directory contains helper scripts for managing the XRDP audio FIFO system.

## ffmpeg_manager.sh

A watchdog script that monitors the audio format specification file and manages FFmpeg processes for encoding/decoding audio.

### Features

- **Automatic format detection**: Reads format from `/run/user/$(id -u)/xrdp_audio_format.txt`
- **Dynamic restart**: Restarts FFmpeg when format changes
- **Process management**: Handles speaker encoder and mic decoder processes
- **Logging**: Maintains separate logs for speaker and mic processes

### Usage

```bash
# Start the manager (runs in foreground)
./ffmpeg_manager.sh start

# Stop all managed processes
./ffmpeg_manager.sh stop

# Restart processes with current format
./ffmpeg_manager.sh restart

# Check status
./ffmpeg_manager.sh status
```

### Running as a Service

To run as a systemd user service:

```bash
# Create service file
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/xrdp-audio-fifo.service <<EOF
[Unit]
Description=XRDP Audio FIFO Manager
After=pipewire.service

[Service]
Type=simple
ExecStart=/path/to/scripts/ffmpeg_manager.sh start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

# Enable and start
systemctl --user enable xrdp-audio-fifo.service
systemctl --user start xrdp-audio-fifo.service
```

### Environment Variables

- `XRDP_AUDIO_SPK_FIFO`: Speaker FIFO path (default: `/run/user/$(id -u)/xrdp_spk.pcm`)
- `XRDP_AUDIO_MIC_FIFO`: Microphone FIFO path (default: `/run/user/$(id -u)/xrdp_mic.pcm`)
- `XRDP_AUDIO_FORMAT_FILE`: Format specification file (default: `/run/user/$(id -u)/xrdp_audio_format.txt`)

### Log Files

- Speaker encoder: `$XDG_RUNTIME_DIR/xrdp_ffmpeg_speaker.log`
- Mic decoder: `$XDG_RUNTIME_DIR/xrdp_ffmpeg_mic.log`

## Testing

### Manual FIFO Test

```bash
# Terminal 1: Start the module
pw-cli load-module libpipewire-module-xrdp

# Terminal 2: Start ffmpeg manager
./scripts/ffmpeg_manager.sh start

# Terminal 3: Play audio to test speaker
paplay /usr/share/sounds/alsa/Front_Center.wav

# Check if data is being written to speaker FIFO
ls -lh /run/user/$(id -u)/xrdp_spk.pcm
```

### Loopback Test

Create a simple loopback by connecting speaker output to mic input:

```bash
# This will route speaker audio back to microphone
ffmpeg -f s16le -ac 2 -ar 48000 \
       -i /run/user/$(id -u)/xrdp_spk.pcm \
       -ac 1 -ar 48000 -f s16le \
       /run/user/$(id -u)/xrdp_mic.pcm
```

## Troubleshooting

### FIFOs not created

Check that the module is loaded:
```bash
pw-cli ls Module | grep xrdp
```

### No audio flowing

1. Check FIFO permissions:
   ```bash
   ls -la /run/user/$(id -u)/xrdp_*.pcm
   ```

2. Check FFmpeg processes:
   ```bash
   ./scripts/ffmpeg_manager.sh status
   ```

3. Check logs:
   ```bash
   tail -f /run/user/$(id -u)/xrdp_ffmpeg_*.log
   ```

### Format file not updating

Check PipeWire module logs:
```bash
journalctl --user -u pipewire -f | grep xrdp
```
