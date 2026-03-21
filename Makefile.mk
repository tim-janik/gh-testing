# Licensed under the GNU GPL-3.0+: https://www.gnu.org/licenses/gpl-3.0.html
all:	# default target

SHELL		:= /bin/bash -o pipefail
# Commit info by git-archive in export-subst format string, see gitattributes(5)
VERSION		:= $Format: %(describe:match=v[0-9]*.[0-9]*.[0-9]*) %ci $
ifneq ($(findstring %,$(VERSION)),)
  VERSION	!= git log -1 --format='%(describe:match=v[0-9]*.[0-9]*.[0-9]*) %ci' || echo "v0.0.0-g0000000 2000-01-01 00:00:00 +0000"
endif
version_bits	:= $(subst _, , $(subst -, , $(subst ., , $(VERSION))))
PKGVERSION	:= $(word 1, $(version_bits)).$(word 2, $(version_bits))
ALL_TARGETS	:=
Q		:= $(if $(findstring 1, $(V)),, @)
QGEN		 = @echo '  GEN     ' $@
QSKIP		:= $(if $(findstring s,$(MAKEFLAGS)),: )
QECHO		 = @QECHO() { Q1="$$1"; shift; QR="$$*"; QOUT=$$(printf '  %-8s ' "$$Q1" ; echo "$$QR") && $(QSKIP) echo "$$QOUT"; }; QECHO
QCHECK		 = $(QECHO) CHECK $@
QOK		 = $(QECHO) OK $@
PANDOC		:= pandoc
CLEANFILES	 = $(ALL_TARGETS) .version

# == Paths ==
# Installation locations
PREFIX	?= /tmp/test
BINDIR	?= $(PREFIX)/bin
LIBEXEC	?= libexec/imagewmark-$(PKGVERSION)
PRJDIR	?= $(PREFIX)/$(LIBEXEC)

# == Versioning ==
# Build .version from tarball or when Git changes
.version: $(wildcard .git/logs/HEAD)
	$Q echo '$(VERSION)' > $@
version:
	@echo $(VERSION)
ALL_TARGETS += .version

# == install ==
install:
	$(QGEN)
	mkdir -p $(PREFIX)
	cp -v README.md script.sh .version $(PREFIX)
uninstall:
	$(QGEN)
	rm -f $(PREFIX)/README.md $(PREFIX)/script.sh $(PREFIX)/.version

# == installcheck ==
installcheck:
	test -r $(PREFIX)/README.md
	$(PREFIX)/script.sh --version

# == distcheck ==
distcheck:
	@$(eval distversion != git describe --match='v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//')
	@$(eval distname := pkg-$(distversion))
	$(QECHO) MAKE artifacts/$(distname).tar.zst
	$Q test -n "$(distversion)" || (echo -e "#\n# $@: ERROR: no dist version, is git working?\n#" ; false )
	$Q git describe --dirty | grep -qve -dirty || echo -e "#\n# $@: WARNING: working tree is dirty\n#"
	$Q mkdir -p artifacts/
	$Q git archive -o artifacts/$(distname).tar --prefix=$(distname)/ HEAD
	$Q rm -f artifacts/$(distname).tar.zst && zstd --ultra -22 --rm artifacts/$(distname).tar && ls -lh artifacts/$(distname).tar.zst
	$Q T=`mktemp -d --tmpdir pkg-XXXXXX` && cd $$T && tar xvf $(abspath artifacts/$(distname).tar.zst) \
        && cd $(distname) \
	&& nice make all -j`nproc` \
	&& make PREFIX=$$T/inst install \
	&& make PREFIX=$$T/inst installcheck -j`nproc` \
	&& (set -x && $$T/inst/script.sh --version) \
        && make PREFIX=$$T/inst uninstall \
        && (set -x && $$PWD/script.sh --version) \
	&& make PREFIX=$$T/inst uninstall \
	&& cd / && rm -r "$$T"
	$Q echo "Archive ready: artifacts/$(distname).tar.zst" | sed '1h; 1s/./=/g; 1p; 1x; $$p; $$x'

release:
	$(eval PKG != git config --get remote.origin.url | xargs -I{} basename {} .git)
	$(eval TAG != sed -nr '1{ /^\#\#/{ s/.*\bv?([0-9]+\.[0-9]+\.[0-9]+[_a-z.0-9+-]*)\b.*/\1/; tPRNT; q; :PRNT p } }' NEWS.md)
	$(eval HEADSHA != git rev-parse HEAD)
	$(eval VERSION := -unused- )
	$Q echo '  MAKE      ' $@
	$Q echo '  TAG       ' "HEAD as v$(TAG) # $(HEADSHA)"
	$Q ! git ls-remote --exit-code origin "refs/tags/v$(TAG)" 2>/dev/null \
	|| { echo "ERROR: tag v$(TAG) already exists on remote" ; exit 1 ; }
	$Q test -n "$${FORCE-}" && git tag -d "v$(TAG)" >/dev/null 2>&1 || :
	$Q git tag -m "$(PKG) $(TAG)" "v$(TAG)" "$(HEADSHA)"
	$Q echo '  DISTCHECK ' '> artifacts/.distcheck.log' \
	&& rm -rf artifacts/ && mkdir -p artifacts/ \
	&& ( make clean \
	&&   docker run -ti --rm -v "$$PWD:/$(PKG)" -w "/$(PKG)" ghcr.io/tim-janik/anklang-ci:ci-latest \
		make distcheck ) > artifacts/.distcheck.log 2>&1 # build assets
	$Q echo '  MK-NOTES  ' artifacts/.notes \
	&& sed -rn '/^##? / { p; :BEGIN ; n ; /^##? /q ; p ; bBEGIN ; }' NEWS.md > artifacts/.notes
	$Q echo '  CHECK     ' "HEAD @ origin" \
	&& git branch -r --contains "$(HEADSHA)" | grep -qE ' origin/' \
	|| { echo "ERROR: HEAD diverged from origin/" ; exit 1 ; }
	$Q echo '  UPLOAD    ' "Draft release $(TAG)" \
	&& gh release create -F artifacts/.notes --draft --target="$(HEADSHA)" v$(TAG) artifacts/*	< /dev/null
	$Q test -n "$${FORCE-}" \
	|| { read -i y -p "Push and publish \`HEAD\` tagged as $(PKG) v$(TAG) ? [y/N] " Y && test "y$$Y" == yy ; }
	$Q git push origin "v$(TAG)"
	$Q gh release edit "v$(TAG)" --verify-tag --draft=false
	$Q echo "TODO: pkg --help '>>' wiki/cli-help.md"

# == clean ==
clean:
	rm -f $(CLEANFILES)

# == check ==
check:
	$Q echo check-syntax etc
.PHONY: check

# == all ==
all: $(ALL_TARGETS)
# Must be last rule
