PROJECT := SubwayLore/SubwayLore.xcodeproj
SCHEME := SubwayLore
SIMULATOR ?= iPhone 18 Pro
DESTINATION := platform=iOS Simulator,name=$(SIMULATOR),OS=latest
DERIVED_DATA := .build/DerivedData

.PHONY: test

test:
	xcodebuild test \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-only-testing:SubwayLoreTests
