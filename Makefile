.PHONY: build release test install clean

CRYSTAL := mise exec -- crystal

# Ad-hoc signing is a macOS requirement; a no-op elsewhere.
ifeq ($(shell uname -s),Darwin)
SIGN := codesign -s - --force
else
SIGN := true
endif

build:
	mkdir -p bin
	$(CRYSTAL) build src/smith.cr -o bin/smith
	$(SIGN) bin/smith

release:
	mkdir -p bin
	$(CRYSTAL) build --release src/smith.cr -o bin/smith
	$(SIGN) bin/smith

test:
	$(CRYSTAL) spec

install: release
	mkdir -p ~/.local/bin
	cp bin/smith ~/.local/bin/smith
	$(SIGN) ~/.local/bin/smith

clean:
	rm -rf bin/
