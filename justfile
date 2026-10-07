# Distill wraps xcodebuild, Swift, SwiftLint, and Cargo, showing useful diagnostics.
# https://github.com/lycaennaa/distill

worktree_root := justfile_directory()
worktree_build_dir := worktree_root + "/build"
derived_data := worktree_build_dir + "/DerivedData"
source_packages := worktree_build_dir + "/SourcePackages"
release_products := derived_data + "/Build/Products/Release"

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
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -project Sidekick.xcodeproj -scheme sidekick -configuration Debug -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Debug -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- build; fi

@run: build
    open "$(python3 -c 'import sys; from pathlib import Path; apps = list(Path(sys.argv[1]).glob("*.app")); assert len(apps) == 1, "Expected one app"; print(apps[0])' "{{derived_data}}/Build/Products/Debug")"

@build-release: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- build; fi

@build-release-open: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build --open -- -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- build && open "$(python3 -c 'import sys; from pathlib import Path; apps = list(Path(sys.argv[1]).glob("*.app")); assert len(apps) == 1, "Expected one app"; print(apps[0])' "{{release_products}}")"; fi

@build-release-move: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build --mv -- -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- build && app_path="$(python3 -c 'import sys; from pathlib import Path; apps = list(Path(sys.argv[1]).glob("*.app")); assert len(apps) == 1, "Expected one app"; print(apps[0])' "{{release_products}}")" && destination="/Applications/$(basename "$app_path")" && rm -rf "$destination" && mv -f "$app_path" "$destination"; fi

@build-release-omv: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build --omv -- -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Release -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- build && app_path="$(python3 -c 'import sys; from pathlib import Path; apps = list(Path(sys.argv[1]).glob("*.app")); assert len(apps) == 1, "Expected one app"; print(apps[0])' "{{release_products}}")" && destination="/Applications/$(basename "$app_path")" && rm -rf "$destination" && mv -f "$app_path" "$destination" && open "$destination"; fi


@test: test-justfile generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode test -- -project Sidekick.xcodeproj -scheme sidekick -configuration Debug -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-; else xcodebuild -project Sidekick.xcodeproj -scheme sidekick -configuration Debug -derivedDataPath "{{derived_data}}" -clonedSourcePackagesDirPath "{{source_packages}}" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- test; fi

@test-justfile:
    sh justfile_recipe_syntax_test.sh


@lint:
    if command -v distill >/dev/null 2>&1; then distill swift lint -- --config .swiftlint.yml; else swiftlint lint --config .swiftlint.yml; fi

@lint-fix:
    if command -v distill >/dev/null 2>&1; then distill swift lint -- --fix --config .swiftlint.yml; else swiftlint lint --fix --config .swiftlint.yml; fi

@check-package-locks:
    python3 -B scripts/check-package-locks.py

@check-pbx: generate-project
    python3 -B scripts/check-pbx-identifiers.py

@check-client-id: generate-project
    python3 -B scripts/check-client-id.py

@check: check-package-locks check-pbx check-client-id lint test

@ci: check build-release

@package:
    sh scripts/package-release.sh


@clean:
    rm -rf "{{worktree_build_dir}}" "{{worktree_root}}/dist" "{{worktree_root}}/.build/package-derived-data"
