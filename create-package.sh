#!/bin/bash
#
# Package Creation Script for pipewire-module-synccast
# Creates a redistributable package with pre-built binaries
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Package information
PKG_NAME="pipewire-module-synccast"
PKG_VERSION="0.2-fifo"
PKG_ARCH=$(uname -m)
PKG_FULLNAME="${PKG_NAME}-${PKG_VERSION}-${PKG_ARCH}"
PKG_DIR="package/${PKG_FULLNAME}"

echo "=========================================="
echo "Creating package: ${PKG_FULLNAME}"
echo "=========================================="

# Clean previous package
rm -rf package
mkdir -p "${PKG_DIR}"

# Check if module is built
if [ ! -f "build/src/.libs/libpipewire-module-synccast.so" ]; then
    echo "ERROR: Module not built. Please run './bootstrap && cd build && ../configure && make' first"
    exit 1
fi

echo "[1/6] Copying module binary..."
mkdir -p "${PKG_DIR}/lib"
cp build/src/.libs/libpipewire-module-synccast.so "${PKG_DIR}/lib/"
strip "${PKG_DIR}/lib/libpipewire-module-synccast.so"

echo "[2/6] Copying scripts..."
mkdir -p "${PKG_DIR}/bin"
cp scripts/ffmpeg_manager.sh "${PKG_DIR}/bin/"
cp quick-test.sh "${PKG_DIR}/bin/"
chmod +x "${PKG_DIR}/bin/"*.sh

echo "[3/6] Copying documentation..."
mkdir -p "${PKG_DIR}/docs"
cp DEPLOYMENT_GUIDE.md "${PKG_DIR}/docs/"
cp docs/IMPLEMENTATION_COMPLETE.md "${PKG_DIR}/docs/"
cp scripts/README.md "${PKG_DIR}/docs/SCRIPTS.md"
cp README.md "${PKG_DIR}/docs/" 2>/dev/null || true
cp LICENSE "${PKG_DIR}/docs/" 2>/dev/null || true

echo "[4/6] Creating installation script..."
cat > "${PKG_DIR}/install.sh" << 'INSTALL_EOF'
#!/bin/bash
#
# Installation Script for pipewire-module-synccast
# Auto-detects OS and installs dependencies
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
    echo ""
}

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS=$DISTRIB_ID
        OS_VERSION=$DISTRIB_RELEASE
    else
        OS=$(uname -s)
        OS_VERSION=$(uname -r)
    fi

    log_info "Detected OS: $OS $OS_VERSION"
}

# Check if running as root for system-wide install
check_permissions() {
    if [ "$INSTALL_TYPE" = "system" ] && [ "$EUID" -ne 0 ]; then
        log_error "System-wide installation requires root privileges"
        log_info "Please run: sudo $0 $@"
        exit 1
    fi
}

# Install dependencies based on OS
install_dependencies() {
    print_header "Installing Dependencies"

    case "$OS" in
        ubuntu|debian|linuxmint)
            log_info "Installing dependencies for Debian/Ubuntu..."
            sudo apt-get update
            sudo apt-get install -y \
                pipewire \
                libpipewire-0.3-0 \
                libpipewire-0.3-dev \
                ffmpeg \
                || log_warn "Some packages may already be installed"
            ;;

        fedora|rhel|centos|rocky|almalinux)
            log_info "Installing dependencies for RHEL/Fedora..."
            sudo dnf install -y \
                pipewire \
                pipewire-devel \
                ffmpeg \
                || log_warn "Some packages may already be installed"
            ;;

        arch|manjaro)
            log_info "Installing dependencies for Arch Linux..."
            sudo pacman -Sy --noconfirm \
                pipewire \
                ffmpeg \
                || log_warn "Some packages may already be installed"
            ;;

        opensuse*|sles)
            log_info "Installing dependencies for openSUSE..."
            sudo zypper install -y \
                pipewire \
                pipewire-devel \
                ffmpeg \
                || log_warn "Some packages may already be installed"
            ;;

        *)
            log_warn "Unknown OS: $OS"
            log_warn "Please manually install: pipewire, libpipewire-0.3, ffmpeg"
            read -p "Continue anyway? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
            ;;
    esac

    log_success "Dependencies installed"
}

# Install module
install_module() {
    print_header "Installing Module"

    if [ "$INSTALL_TYPE" = "system" ]; then
        # System-wide installation
        MODULE_DIR=$(pkg-config --variable=moduledir libpipewire-0.3 2>/dev/null || echo "/usr/lib/x86_64-linux-gnu/pipewire-0.3")
        BIN_DIR="/usr/local/bin"

        log_info "Installing to system directories..."
        log_info "Module: $MODULE_DIR"
        log_info "Scripts: $BIN_DIR"

        sudo mkdir -p "$MODULE_DIR"
        sudo cp lib/libpipewire-module-synccast.so "$MODULE_DIR/"

        sudo cp bin/ffmpeg_manager.sh "$BIN_DIR/"
        sudo chmod +x "$BIN_DIR/ffmpeg_manager.sh"

        log_success "System-wide installation complete"

    else
        # User-local installation
        MODULE_DIR="$HOME/.local/lib/pipewire-0.3"
        BIN_DIR="$HOME/.local/bin"

        log_info "Installing to user directories..."
        log_info "Module: $MODULE_DIR"
        log_info "Scripts: $BIN_DIR"

        mkdir -p "$MODULE_DIR"
        cp lib/libpipewire-module-synccast.so "$MODULE_DIR/"

        mkdir -p "$BIN_DIR"
        cp bin/ffmpeg_manager.sh "$BIN_DIR/"
        chmod +x "$BIN_DIR/ffmpeg_manager.sh"

        # Add to PATH if not already
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            log_warn "Add $HOME/.local/bin to PATH:"
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
            log_info "Added to ~/.bashrc (restart shell to apply)"
        fi

        log_success "User-local installation complete"
    fi
}

# Create PipeWire configuration
create_pipewire_config() {
    print_header "Configuring PipeWire"

    if [ "$INSTALL_TYPE" = "system" ]; then
        CONFIG_DIR="/etc/pipewire/pipewire.conf.d"
        CONFIG_FILE="$CONFIG_DIR/90-synccast.conf"
        log_info "Using system-wide configuration: $CONFIG_FILE"
        sudo mkdir -p "$CONFIG_DIR"
    else
        CONFIG_DIR="$HOME/.config/pipewire/pipewire.conf.d"
        CONFIG_FILE="$CONFIG_DIR/90-synccast.conf"
        log_info "Using user configuration: $CONFIG_FILE"
        mkdir -p "$CONFIG_DIR"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        log_warn "Configuration already exists: $CONFIG_FILE"
        read -p "Overwrite? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Keeping existing configuration"
            return
        fi
    fi

    CONFIG_CONTENT='context.modules = [
    {   name = libpipewire-module-synccast
        args = {
            sink.stream.props = { }
            source.stream.props = { }
        }
    }
]'

    if [ "$INSTALL_TYPE" = "system" ]; then
        echo "$CONFIG_CONTENT" | sudo tee "$CONFIG_FILE" > /dev/null
    else
        echo "$CONFIG_CONTENT" > "$CONFIG_FILE"
    fi

    log_success "PipeWire configuration created: $CONFIG_FILE"
    log_info "Module will auto-load on PipeWire restart"
}

# Print usage instructions
print_usage() {
    print_header "Installation Complete!"

    echo "Next Steps:"
    echo ""
    echo "1. Restart PipeWire:"
    echo "   systemctl --user restart pipewire"
    echo ""
    echo "2. Verify module loaded:"
    echo "   pw-cli ls Module | grep synccast"
    echo ""
    echo "3. Check FIFOs created:"
    echo "   ls -la /run/user/\$(id -u)/synccast_*.pcm"
    echo ""
    echo "4. Start FFmpeg manager:"
    if [ "$INSTALL_TYPE" = "system" ]; then
        echo "   ffmpeg_manager.sh start"
    else
        echo "   ~/.local/bin/ffmpeg_manager.sh start"
    fi
    echo ""
    echo "5. Test audio:"
    echo "   speaker-test -D synccast-sink -c 2 -t wav"
    echo ""
    echo "Documentation: ./docs/"
    echo ""
}

# Main installation
main() {
    print_header "pipewire-module-synccast Installer"

    # Parse arguments
    INSTALL_TYPE="user"
    SKIP_DEPS=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --system)
                INSTALL_TYPE="system"
                shift
                ;;
            --skip-deps)
                SKIP_DEPS=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --system      Install system-wide (requires sudo)"
                echo "  --skip-deps   Skip dependency installation"
                echo "  --help        Show this help"
                echo ""
                echo "Default: User-local installation"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    detect_os
    check_permissions

    if [ "$SKIP_DEPS" = false ]; then
        install_dependencies
    fi

    install_module
    create_pipewire_config
    print_usage

    log_success "Installation completed successfully!"
}

main "$@"
INSTALL_EOF

chmod +x "${PKG_DIR}/install.sh"

echo "[5/6] Creating package metadata..."
cat > "${PKG_DIR}/PACKAGE_INFO" << EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Architecture: ${PKG_ARCH}
Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Built On: $(uname -a)

Description:
  PipeWire module for SyncCast with FIFO-based audio routing.
  Provides custom audio routing through named pipes (FIFOs)
  for integration with external audio processing tools like FFmpeg.

Components:
  - libpipewire-module-synccast.so: Main PipeWire module
  - ffmpeg_manager.sh: FFmpeg process management script
  - quick-test.sh: Quick testing utility
  - install.sh: OS-aware installation script
  - Documentation

Requirements:
  - PipeWire >= 0.3
  - FFmpeg (for audio encoding/decoding)
  - Linux kernel with FIFO support

Installation:
  ./install.sh           # User-local installation
  ./install.sh --system  # System-wide installation (requires sudo)

Documentation:
  See docs/ directory for complete documentation.
EOF

echo "[6/6] Creating tarball..."
cd package
tar czf "${PKG_FULLNAME}.tar.gz" "${PKG_FULLNAME}"
cd ..

TARBALL_PATH="package/${PKG_FULLNAME}.tar.gz"
TARBALL_SIZE=$(du -h "$TARBALL_PATH" | cut -f1)

echo ""
echo "=========================================="
echo "Package created successfully!"
echo "=========================================="
echo ""
echo "Package: $TARBALL_PATH"
echo "Size: $TARBALL_SIZE"
echo ""
echo "To distribute:"
echo "  1. Copy $TARBALL_PATH to target machine"
echo "  2. Extract: tar xzf ${PKG_FULLNAME}.tar.gz"
echo "  3. Install: cd ${PKG_FULLNAME} && ./install.sh"
echo ""
echo "Installation options:"
echo "  ./install.sh           # User-local installation"
echo "  ./install.sh --system  # System-wide installation"
echo "  ./install.sh --skip-deps  # Skip dependency installation"
echo ""
