.PHONY: build release test install clean

build:
	mkdir -p bin
	mise exec -- crystal build src/smith.cr -o bin/smith
	codesign -s - --force bin/smith

release:
	mkdir -p bin
	mise exec -- crystal build --release src/smith.cr -o bin/smith
	codesign -s - --force bin/smith

test:
	mise exec -- crystal spec

install: release
	mkdir -p ~/.local/bin
	cp bin/smith ~/.local/bin/smith
	codesign -s - --force ~/.local/bin/smith

clean:
	rm -rf bin/
