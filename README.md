# Adaptive AI Chat Router

A native macOS chat app that routes each query to a local on-device MLX model,
a fast cloud model, or an advanced cloud model, based on an on-device
classification pass. See `AIChatRouterKit/` for the routing/persistence/provider
business logic and `AIChatRouter/` for the SwiftUI app.

## Setup

```sh
brew install xcodegen   # if not already installed
xcodegen generate
open AIChatRouter.xcodeproj
```

## Testing the logic layer

```sh
cd AIChatRouterKit
swift test
```
