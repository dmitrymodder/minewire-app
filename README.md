# Minewire Client

Cross-platform VPN client that masquerades as a Minecraft client to establish encrypted tunnels and bypass network restrictions.

## Features

- **AES-GCM Encryption** - All traffic encrypted and disguised as Minecraft packets
- **Deep Packet Inspection Evasion** - Indistinguishable from genuine Minecraft client traffic
- **Stream Multiplexing** - Multiple connections through single tunnel (yamux)

## Platforms

- **Android**: 5.0 (API 21) or newer
- **Windows**: 10/11

## Installation

### Pre-built Releases

Download from [Releases](https://github.com/dmitrymodder/minewire-app/releases):

- **Android**: `minewire-app-arm64-v8a-release.apk` (recommended for modern devices)
- **Windows**: `minewire-windows.zip` (extract and run `minewire_app.exe`)

### Build from Source

#### Prerequisites

- **Flutter SDK**: 3.5.0+
- **Go**: 1.19+
- **gomobile**: for Android library compilation
- **Android SDK**: for Android builds
- **Visual Studio Build Tools**: for Windows builds

#### Android Build

```bash
# Clone repository
git clone https://github.com/dmitrymodder/minewire-app.git
cd minewire-app

# Build Go library
cd go
gomobile bind -target=android -o ../android/app/libs/minewire.aar -androidapi 21 -javapkg=com.uberwelt.libminewire .
cd ..

# Install Flutter dependencies
flutter pub get

# Build APK
flutter build apk --release --split-per-abi

# Output: build/app/outputs/flutter-apk/
# - app-arm64-v8a-release.apk (recommended)
# - app-armeabi-v7a-release.apk (legacy devices)
```

#### Windows Build

```bash
# Clone repository
git clone https://github.com/dmitrymodder/minewire-app.git
cd minewire-app

# Install dependencies
flutter pub get

# Build Windows app
flutter build windows

# Output: build/windows/x64/runner/Release/
```

## Usage

### Initial Setup

1. Open app and navigate to "Config" section
2. Create new profile:
   - Server address (e.g., `server.example.com:25565`)
   - Password (provided by server administrator)
   - Profile name
3. Select created profile
4. Return to home screen and tap "Connect"

### Import Configuration

Paste link in format `mw://password@server:port#ProfileName` to auto-configure.

### Settings

Configure in "Settings" section:

- **Proxy Type**: SOCKS5 (default) or HTTP
- **Local Port**: default `:1080`
- **Theme**: light, dark, or system
- **Dynamic Colors**: Android 12+ only

## Architecture

### Components

- **Flutter UI** (`lib/`) - Cross-platform Dart interface
- **Go Core** (`go/`, `go-windows/`) - VPN/proxy engine, compiled as:
  - Android: AAR library via gomobile
  - Windows: Direct FFI integration
- **Platform Channels** - Dart ↔ Go communication bridge

### How It Works

1. **Connection**: Client initiates Minecraft protocol handshake with server
2. **Authentication**: Username derived from SHA256(password), matching server's validation logic
3. **Tunnel Establishment**: Encrypted yamux multiplexed session over Minecraft connection
4. **Traffic Encapsulation**: Data encrypted with AES-GCM, embedded in Minecraft Plugin Message packets (0x0D)
   - Uses `minecraft:brand` or `minewire:tunnel` channels
   - Each write: random nonce + AEAD encrypted payload
5. **Proxying**:
   - **Android**: tun2socks intercepts all device traffic, routes through tunnel
   - **Windows**: Local SOCKS5/HTTP proxy redirects application traffic

The protocol leverages Minecraft's plugin messaging system: Plugin Message packets can contain arbitrary data and are expected during gameplay, making them ideal carriers for encrypted tunnel traffic.

### Project Structure

```
minewire_app/
├── android/          # Android-specific code
├── windows/          # Windows-specific code
├── lib/              # Flutter/Dart code
│   ├── main.dart           # Entry point
│   ├── config_page.dart    # Profile management
│   ├── settings_page.dart  # Settings UI
│   ├── models/             # Data models
│   └── services/           # Platform channels
├── go/               # Go library (Android)
│   ├── minewire.go   # Core logic
│   ├── tunnel.go     # Server tunnel
│   ├── protocol.go   # Minecraft protocol
│   └── proxy.go      # SOCKS5/HTTP proxy
└── go-windows/       # Go library (Windows)
```

### Development

```bash
# Run on Android (emulator or device)
flutter run

# Run on Windows
flutter run -d windows
```

## License

MIT

## Related Projects

- [minewire](https://github.com/dmitrymodder/minewire) - Minewire server implementation