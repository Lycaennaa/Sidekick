# Distill wraps xcodebuild, Swift, SwiftLint, and Cargo, showing useful diagnostics.
# https://github.com/lycaennaa/distill
@setup:
    set -eu; command -v brew >/dev/null 2>&1 || { printf '%s\n' 'Install Homebrew first.' >&2; exit 1; }; if ! command -v xcodegen >/dev/null 2>&1; then HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen; fi; if ! command -v swiftlint >/dev/null 2>&1; then HOMEBREW_NO_AUTO_UPDATE=1 brew install swiftlint; fi

@fetch-clearurls:
    sh scripts/fetch-clearurls-rules.sh --if-missing

@generate-project: fetch-clearurls
    xcodegen generate --spec project.yml

@refresh-clearurls:
    sh scripts/fetch-clearurls-rules.sh --force
    xcodegen generate --spec project.yml

@build: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -project Sidekick.xcodeproj -scheme sidekick -configuration Debug -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Debug -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- build; fi

@run: build
    open "$(python3 -c 'from pathlib import Path; apps = list(Path("build/DerivedData/Build/Products/Debug").glob("*.app")); assert len(apps) == 1, "Expected one app"; print(apps[0])')"

@build-release: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- build; fi

@build-release-open: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- build; fi

@build-release: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- build; fi

@test: test-justfile generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode test -- -project Sidekick.xcodeproj -scheme sidekick -configuration Debug -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Debug -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- test; fi

@test-justfile:
    sh justfile_recipe_syntax_test.sh


@lint:
    if command -v distill >/dev/null 2>&1; then distill swift lint -- --config .swiftlint.yml; else swiftlint lint --config .swiftlint.yml; fi

@lint-fix:
    if command -v distill >/dev/null 2>&1; then distill swift lint -- --fix --config .swiftlint.yml; else swiftlint lint --fix --config .swiftlint.yml; fi

@check-package-locks:
    python3 -B scripts/check-package-locks.py

@check-pbx:
    python3 -B scripts/check-pbx-identifiers.py

@check-client-id: generate-project
    python3 -B scripts/check-client-id.py

@check: check-package-locks check-pbx check-client-id lint test

@ci: check build-release

@package:
    sh scripts/package-release.sh


@clean:
    rm -rf build dist .build/package-derived-data
