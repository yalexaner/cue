scheme := "cue"
destination := "platform=iOS Simulator,name=iPhone 17"

default:
    @just --list

build:
    xcodebuild build -scheme {{scheme}} -destination '{{destination}}' -quiet CODE_SIGNING_ALLOWED=NO

test:
    xcodebuild test -scheme {{scheme}} -destination '{{destination}}' -quiet CODE_SIGNING_ALLOWED=NO

ipa:
    xcodebuild archive -scheme {{scheme}} -configuration Release -destination 'generic/platform=iOS' -archivePath build/cue.xcarchive -quiet CODE_SIGNING_ALLOWED=NO
    rm -rf build/Payload build/cue.ipa
    cp -R "build/cue.xcarchive/Products/Applications" build/Payload
    cd build && zip -qry cue.ipa Payload

lint:
    swiftlint lint --strict

format:
    swift format --recursive --in-place cue cueTests

format-check:
    swift format lint --recursive --strict cue cueTests

clean:
    xcodebuild clean -scheme {{scheme}}
    rm -rf DerivedData build

destinations:
    xcodebuild -scheme {{scheme}} -showdestinations
