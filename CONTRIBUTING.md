# Contributing to MiDa

Thank you for your interest in contributing to MiDa!

## Getting Started

### Prerequisites

- Flutter SDK (3.5.0+)
- Windows: Visual Studio 2022 with C++ Desktop Development workload
- macOS: Xcode

### Development Setup

1. Clone the repository
```bash
git clone https://github.com/frederic102/mida.git
cd mida
```

2. Download required binaries

**Windows:**
```powershell
.\scripts\download_binaries.ps1
```

**macOS:**
```bash
chmod +x scripts/download_binaries_mac.sh
./scripts/download_binaries_mac.sh
```

3. Install dependencies
```bash
flutter pub get
```

4. Run the app
```bash
# Windows
flutter run -d windows

# macOS
flutter run -d macos
```

## Code Style

- Follow [Dart style guide](https://dart.dev/guides/language/effective-dart/style)
- Run `flutter analyze` before submitting
- Keep code simple and readable

## Submitting Changes

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Reporting Issues

- Use GitHub Issues to report bugs
- Include steps to reproduce the issue
- Include your OS version and Flutter version

## License

By contributing, you agree that your contributions will be licensed under the GPLv3 License.
