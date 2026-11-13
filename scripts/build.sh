#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ ! -f Local.xcconfig ]]; then
  print '// Optional: DEVELOPMENT_TEAM = YOUR_TEAM_ID' > Local.xcconfig
fi
xcodegen generate
xcodebuild -project SkyDesk.xcodeproj -scheme SkyDeskHost -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=YES build
xcodebuild -project SkyDesk.xcodeproj -scheme SkyDeskPad -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-pad \
  CODE_SIGNING_ALLOWED=NO build
