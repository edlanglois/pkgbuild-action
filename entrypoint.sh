#!/bin/bash
set -euo pipefail

# Arguments are passed through to makepkg, so it's possible
# to disable checks, building, etc.

FILE="$(basename "$0")"

pacman -Syu --noconfirm base-devel

# Makepkg does not allow running as root
# Run as `nobody` and give full access to these files
chmod -R a+rw .

# When installing dependencines, makepkg will use sudo
# Give user `nobody` passwordless sudo access
echo "nobody ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Assume that if .SRCINFO is missing then it is generated elsewhere.
# AUR checks that .SRCINFO exists so a missing file can't go unnoticed.
if [ -f .SRCINFO ] && ! sudo -u nobody makepkg --printsrcinfo | diff - .SRCINFO; then
	echo "::error file=$FILE,line=$LINENO::Mismatched .SRCINFO. Update with: makepkg --printsrcinfo > .SRCINFO"
	exit 1
fi

# Get array of packages to be built
mapfile -t PKGFILES < <( sudo -u nobody makepkg --packagelist )
echo "Package(s): ${PKGFILES[*]}"

# Build packages
sudo -u nobody makepkg --syncdeps --noconfirm "$@"

# Report built package archives
i=0
for PKGFILE in "${PKGFILES[@]}"; do
	# makepkg reports absolute paths, must be relative for use by other actions
	RELPKGFILE="$(realpath --relative-base="$PWD" "$PKGFILE")"
	# Caller arguments to makepkg may mean the pacakge is not built
	if [ -f "$PKGFILE" ]; then
		echo "::set-output name=pkgfile$i::$RELPKGFILE"
	else
		echo "Archive $RELPKGFILE not built"
	fi
	(( ++i ))
done

function prepend () {
	# Prepend the argument to each input line
	while read -r line; do
		echo "$1$line"
	done
}

# namcap_check is set up to be configured with environment variables
# but I haven't figured how how to pass those into the docker container.
# TODO: Either pass in environment variables or use args instead.

function namcap_check() {
	# Run namcap checks
	# Installing namcap after building so that makepkg happens on a minimal
	# install where any missing dependencies can be caught.
	pacman -S --noconfirm namcap

	NAMCAP_ARGS=()
	if [ -n "${NAMCAP_RULES:-}" ]; then
		NAMCAP_ARGS+=( "-r" "${NAMCAP_RULES}" )
	fi

	namcap "${NAMCAP_ARGS[@]}" PKGBUILD \
		| prepend "::warning file=$FILE,line=$LINENO::"
	for PKGFILE in "${PKGFILES[@]}"; do
		if [ -f "$PKGFILE" ]; then
			RELPKGFILE="$(realpath --relative-base="$PWD" "$PKGFILE")"
			namcap "${NAMCAP_ARGS[@]}" "$PKGFILE" \
				| prepend "::warning file=$FILE,line=$LINENO::$RELPKGFILE:"
		fi
	done
}

if [ -z "${NAMCAP_DISABLE:-}" ]; then
	namcap_check
fi
