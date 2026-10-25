# FunSize

A macOS app built with SwiftUI.

## Requirements
- macOS 14+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Getting started
```sh
xcodegen generate   # regenerate FunSize.xcodeproj after editing project.yml
open FunSize.xcodeproj
```

Project settings live in `project.yml`. Add new files under `FunSize/` and re-run `xcodegen generate`.
