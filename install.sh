#!/bin/sh
# Build Table and install it where you can launch it.
#
#   ./install.sh            macOS Release -> /Applications/Table.app
#   ./install.sh ios        iOS Debug -> booted simulator (default iPhone 17)
#   ./install.sh ios 'iPad Pro 13-inch (M4)'
#
# Local ad-hoc signing only ("Sign to Run Locally") — no developer account needed.

set -eu

cd "$(dirname "$0")"

SIMULATOR=${2:-iPhone 17}
BUNDLE_ID=rainbowroachie.Table

case "${1:-macos}" in
macos)
	xcodebuild -project Table.xcodeproj -scheme Table \
		-destination 'platform=macOS' -configuration Release \
		-derivedDataPath build build

	# /Applications refuses to overwrite a running app
	pkill -x Table || true
	rm -rf /Applications/Table.app
	cp -R build/Build/Products/Release/Table.app /Applications/

	# The Services registry answers Finder from a cache that survives replacing the bundle, so
	# without this the right-click entry stays whatever the last install said. Setting
	# `servicesProvider` at launch does not refresh it; only this does.
	/System/Library/CoreServices/pbs -flush

	echo "installed /Applications/Table.app — open -a Table"
	;;

ios)
	xcodebuild -project Table.xcodeproj -scheme Table \
		-destination "platform=iOS Simulator,name=$SIMULATOR" \
		-derivedDataPath build build

	xcrun simctl boot "$SIMULATOR" || true
	open -a Simulator
	xcrun simctl install "$SIMULATOR" build/Build/Products/Debug-iphonesimulator/Table.app
	xcrun simctl launch "$SIMULATOR" "$BUNDLE_ID"
	;;

*)
	echo "usage: $0 [macos|ios] [simulator name]" >&2
	exit 2
	;;
esac
