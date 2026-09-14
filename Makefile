PART ?= patch

.PHONY: install bump lint

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
	shfmt -l -d sdx install.sh lib/*.sh
	shellcheck -x sdx install.sh lib/*.sh
