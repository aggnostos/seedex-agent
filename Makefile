PART ?= patch
VERSION = $(shell cat version)
LDFLAGS = -s -w -X main.version=$(VERSION)

.PHONY: build install bump lint clean

build:
	cd link && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="$(LDFLAGS)" -o ../build/seedex-link_linux_amd64 .
	cd link && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="$(LDFLAGS)" -o ../build/seedex-link_linux_arm64 .
	COPYFILE_DISABLE=1 tar -czf build/seedex-agent.tar.gz sdx version install.sh lib
	cp install.sh build/install.sh
	cd build && sha256sum seedex-link_linux_* seedex-agent.tar.gz > checksums.txt

install:
	bash install.sh

bump:
	@old=$$(cat version); \
	IFS=. read -r major minor patch <version; \
	case "$(PART)" in \
	major) major=$$((major + 1)); minor=0; patch=0 ;; \
	minor) minor=$$((minor + 1)); patch=0 ;; \
	patch) patch=$$((patch + 1)) ;; \
	*) echo "PART must be major, minor or patch" >&2; exit 1 ;; \
	esac; \
	new="$$major.$$minor.$$patch"; \
	printf '%s\n' "$$new" >version; \
	echo "$$old -> $$new"; \
	if git rev-parse --git-dir >/dev/null 2>&1; then \
		git add version && git commit -q -m "v$$new" && git tag "v$$new" && echo "tagged v$$new"; \
	fi

lint:
	shfmt -l -d sdx install.sh lib/*.sh lib/vpn/*.sh
	shellcheck -x sdx install.sh lib/*.sh lib/vpn/*.sh
	test -z "$$(gofmt -l link)" || { gofmt -l link; exit 1; }
	cd link && go vet ./...

clean:
	rm -rf build
