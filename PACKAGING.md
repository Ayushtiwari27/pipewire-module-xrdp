# Package Distribution Guide

This document explains how to create and distribute binary packages of pipewire-module-xrdp for installation on other machines without building from source.

## Creating a Package

### Prerequisites on Build Machine

- Fully built module (completed `./bootstrap && cd build && ../configure && make`)
- All dependencies installed
- Scripts and documentation in place

### Build the Package

```bash
# From the project root directory
./create-package.sh
```

This creates a redistributable tarball: `package/pipewire-module-xrdp-0.2-fifo-x86_64.tar.gz`

### Package Contents

The package includes:

```
pipewire-module-xrdp-0.2-fifo-x86_64/
├── lib/
│   └── libpipewire-module-xrdp.so   # Pre-built module binary
├── bin/
│   ├── ffmpeg_manager.sh             # FFmpeg process manager
│   └── quick-test.sh                 # Quick testing utility
├── docs/
│   ├── DEPLOYMENT_GUIDE.md           # Complete deployment guide
│   ├── IMPLEMENTATION_COMPLETE.md    # Implementation documentation
│   ├── SCRIPTS.md                    # Scripts documentation
│   ├── README.md                     # Project README
│   └── LICENSE                       # License file
├── install.sh                        # OS-aware installation script
└── PACKAGE_INFO                      # Package metadata
```

## Distributing the Package

### 1. Upload to Release

```bash
# GitHub Release (recommended)
gh release create v0.2-fifo \
  package/pipewire-module-xrdp-0.2-fifo-x86_64.tar.gz \
  --title "FIFO Audio Routing v0.2" \
  --notes "Pre-built binary package for x86_64 Linux systems"

# Or upload manually to GitHub Releases page
```

### 2. File Sharing Services

```bash
# Copy package to shared location
cp package/pipewire-module-xrdp-0.2-fifo-x86_64.tar.gz /path/to/shared/folder/

# Or upload to cloud storage (Dropbox, Google Drive, etc.)
```

### 3. Internal Network

```bash
# Using SCP
scp package/pipewire-module-xrdp-0.2-fifo-x86_64.tar.gz user@target-machine:~/

# Using HTTP server
cd package
python3 -m http.server 8000
# Access from other machine: wget http://build-machine:8000/pipewire-module-xrdp-0.2-fifo-x86_64.tar.gz
```

## Installing on Target Machine

### Prerequisites on Target Machine

- Linux system with PipeWire installed
- FFmpeg installed
- Internet connection (for dependency installation)

### Installation Steps

```bash
# 1. Download and extract package
wget https://github.com/YOUR-USERNAME/pipewire-module-xrdp/releases/download/v0.2-fifo/pipewire-module-xrdp-0.2-fifo-x86_64.tar.gz
tar xzf pipewire-module-xrdp-0.2-fifo-x86_64.tar.gz
cd pipewire-module-xrdp-0.2-fifo-x86_64

# 2. Run installer
./install.sh           # User-local installation
# OR
./install.sh --system  # System-wide installation (requires sudo)

# 3. Restart PipeWire
systemctl --user restart pipewire

# 4. Verify installation
pw-cli ls Module | grep xrdp
ls -la /run/user/$(id -u)/xrdp_*.pcm
```

### Installation Options

```bash
./install.sh [OPTIONS]

Options:
  --system      Install system-wide (requires sudo)
                Module: /usr/lib/*/pipewire-0.3/
                Scripts: /usr/local/bin/

  --skip-deps   Skip automatic dependency installation
                Useful if dependencies are already installed

  --help        Show help message

Default: User-local installation
         Module: ~/.local/lib/pipewire-0.3/
         Scripts: ~/.local/bin/
```

## Supported Operating Systems

The installer automatically detects and installs dependencies for:

- **Ubuntu/Debian/Linux Mint** - Uses `apt`
- **Fedora/RHEL/CentOS/Rocky/AlmaLinux** - Uses `dnf`
- **Arch Linux/Manjaro** - Uses `pacman`
- **openSUSE/SLES** - Uses `zypper`

For other distributions, the installer will prompt to continue and you'll need to manually install:
- `pipewire` (>= 0.3)
- `libpipewire-0.3-dev` or equivalent
- `ffmpeg`

## Architecture Compatibility

The package includes a pre-built binary for the architecture it was built on (e.g., `x86_64`).

**Important:** The binary package will only work on the same architecture. For different architectures:

1. Build on target architecture: `./bootstrap && cd build && ../configure && make`
2. Create architecture-specific package: `./create-package.sh`
3. Result: `package/pipewire-module-xrdp-0.2-fifo-<arch>.tar.gz`

Common architectures:
- `x86_64` - 64-bit Intel/AMD
- `aarch64` - 64-bit ARM (Raspberry Pi 4, Apple M1/M2, AWS Graviton)
- `armv7l` - 32-bit ARM (Raspberry Pi 3)

## Troubleshooting

### "module: Can't dlopen" Error

The binary was built for a different architecture or linked against incompatible libraries.

**Solution:** Build from source on the target machine.

### Dependencies Not Found

The installer couldn't detect your OS or package manager.

**Solution:** Manually install dependencies:
```bash
# Install pipewire and ffmpeg using your package manager
# Then run: ./install.sh --skip-deps
```

### Permission Denied

System-wide installation requires root privileges.

**Solution:**
```bash
# Use sudo for system installation
sudo ./install.sh --system

# OR use user-local installation (no sudo needed)
./install.sh
```

## Creating Distribution-Specific Packages

### Debian/Ubuntu (.deb)

For Debian/Ubuntu users, you may want to create a `.deb` package:

```bash
# Install packaging tools
sudo apt install build-essential devscripts debhelper

# Create debian directory structure
# (This requires more setup - see debian/control, debian/rules, etc.)
# For now, the tarball method is simpler and works across distributions
```

### RPM-based (.rpm)

For RHEL/Fedora users:

```bash
# Install packaging tools
sudo dnf install rpm-build rpmdevtools

# Create RPM spec file
# (Similar to .deb, this requires additional setup)
```

**Note:** For simplicity, the tarball with `install.sh` works across all Linux distributions. Distribution-specific packages (.deb, .rpm) can be added later if needed.

## Verifying Package Integrity

### Create Checksum

```bash
# On build machine
cd package
sha256sum pipewire-module-xrdp-0.2-fifo-x86_64.tar.gz > pipewire-module-xrdp-0.2-fifo-x86_64.tar.gz.sha256
```

### Verify Checksum

```bash
# On target machine
sha256sum -c pipewire-module-xrdp-0.2-fifo-x86_64.tar.gz.sha256
```

## Updating

To update an existing installation:

```bash
# 1. Download new package version
wget https://github.com/YOUR-USERNAME/pipewire-module-xrdp/releases/download/v0.3/pipewire-module-xrdp-0.3-fifo-x86_64.tar.gz

# 2. Extract and install
tar xzf pipewire-module-xrdp-0.3-fifo-x86_64.tar.gz
cd pipewire-module-xrdp-0.3-fifo-x86_64
./install.sh

# 3. Restart PipeWire
systemctl --user restart pipewire
```

The installer will automatically overwrite the old version.

## Uninstalling

### User-local Installation

```bash
# Remove module
rm ~/.local/lib/pipewire-0.3/libpipewire-module-xrdp.so

# Remove scripts
rm ~/.local/bin/ffmpeg_manager.sh

# Remove configuration
rm ~/.config/pipewire/pipewire.conf.d/90-xrdp.conf

# Restart PipeWire
systemctl --user restart pipewire
```

### System-wide Installation

```bash
# Remove module
sudo rm /usr/lib/*/pipewire-0.3/libpipewire-module-xrdp.so

# Remove scripts
sudo rm /usr/local/bin/ffmpeg_manager.sh

# Remove configuration
rm ~/.config/pipewire/pipewire.conf.d/90-xrdp.conf

# Restart PipeWire
systemctl --user restart pipewire
```

## Support

- **Documentation:** See `docs/` directory in the package
- **Issues:** https://github.com/Ayushtiwari27/pipewire-module-xrdp/issues
- **Original Project:** https://github.com/neutrinolabs/pipewire-module-xrdp

---

**Package Version:** 0.2-fifo
**Last Updated:** 2024-12-04
