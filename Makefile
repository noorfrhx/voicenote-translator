.PHONY: app install test package release icons clean run

app:            ## Build build/VoiceNote Translator.app (universal)
	scripts/build-app.sh

install:        ## Build for this Mac and install into /Applications
	scripts/build-app.sh --native --install

test:           ## Run unit tests
	swift test

package:        ## Make the DMG and zips in dist/
	scripts/package.sh

icons:          ## Redraw the app and extension icons
	swift scripts/make-icons.swift

run: install    ## Install and launch
	open -b io.github.voicenote-translator

clean:
	rm -rf .build build dist

release:        ## Build and publish a GitHub release for VERSION
	scripts/release.sh
