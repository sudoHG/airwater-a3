.PHONY: generate build check

generate:
	xcodegen generate --spec project.yml

# Compile only: never installs, launches, changes networking, or contacts an A3.
build: generate
	python3 -c 'import shutil; available = shutil.disk_usage("/System/Volumes/Data").free / 1024**3; print(f"Free disk: {available:.1f} GiB"); assert available >= 80, "At least 80 GiB free is required for this build"'
	xcodebuild -project AirwaterProbe.xcodeproj -scheme AirwaterProbe -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath .derivedData/opensource CODE_SIGNING_ALLOWED=NO build

check:
	python3 scripts/check_public_tree.py
