#!/bin/bash
set -euo pipefail

FILE="$(basename "$0")"

# Enable the multilib repository
cat << EOM >> /etc/pacman.conf
[multilib]
Include = /etc/pacman.d/mirrorlist
EOM

# Add alerque repository for paru
cat << EOM >> /etc/pacman.conf
[alerque]
SigLevel = Optional TrustAll
Server = https://arch.alerque.com/\$arch
EOM
pacman-key --recv-keys 63CC496475267693

if [ -n "${INPUT_PACMANCONF:-}" ]; then
	echo "Using ${INPUT_PACMANCONF:-} as pacman.conf"
	cp "${INPUT_PACMANCONF:-}" /etc/pacman.conf
fi

if [ -n "${INPUT_MAKEPKGCONF:-}" ]; then
	echo "Using ${INPUT_MAKEPKGCONF:-} as makepkg.conf"
	cp "${INPUT_MAKEPKGCONF:-}" /etc/makepkg.conf
fi

pacman -Syu --noconfirm --needed base base-devel
pacman -Syu --noconfirm --needed ccache
#pacman -Syu --noconfirm --needed ccache-ext

if [ "${INPUT_MULTILIB:-false}" == true ]; then
	pacman -Syu --noconfirm --needed multilib-devel
fi

# Makepkg does not allow running as root
# Create a new user `builder`
# `builder` needs to have a home directory because some PKGBUILDs will try to
# write to it (e.g. for cache)
useradd builder -m
# When installing dependencies, makepkg will use sudo
# Give user `builder` passwordless sudo access
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Give all users (particularly builder) full access to these files
chmod -R a+rw .

BASEDIR="$PWD"
cd "${INPUT_PKGDIR:-.}"

function download_database () {
	# Download the repository files if a repository tag has been specified
	# This is put here to fail early in case they weren't downloaded
	REPOFILES=("${INPUT_REPORELEASETAG:-}".{db{,.tar.gz},files{,.tar.gz}})
	for REPOFILE in "${REPOFILES[@]}"; do
		sudo -u builder curl \
			--retry 5 --retry-delay 30 --retry-all-errors \
			--location --fail \
			-o "$REPOFILE" "$GITHUB_SERVER_URL"/"$GITHUB_REPOSITORY"/releases/download/"${INPUT_REPORELEASETAG:-}"/"$REPOFILE"
	done
	# Delete the `<repo_name>.db` and `repo_name.files` symlinks
	rm "${INPUT_REPORELEASETAG:-}".{db,files} || true
}

if [ -n "${INPUT_REPORELEASETAG:-}" ]; then
	# Download database files to test for availability
	download_database
	# Delete them because they will be downloaded again
	rm "${INPUT_REPORELEASETAG:-}".{db,files}.tar.gz
fi

# Assume that if .SRCINFO is missing then it is generated elsewhere.
# AUR checks that .SRCINFO exists so a missing file can't go unnoticed.
if [ -f .SRCINFO ] && ! sudo -u builder makepkg --printsrcinfo | diff - .SRCINFO; then
	echo "::error file=$FILE,line=$LINENO::Mismatched .SRCINFO. Update with: makepkg --printsrcinfo > .SRCINFO"
	exit 1
fi

# Optionally install dependencies from AUR
if [ -n "${INPUT_AURDEPS:-}" ]; then
	# First install paru
	pacman -Syu --noconfirm paru

	# Extract dependencies from .SRCINFO (depends or depends_x86_64) and install
	mapfile -t PKGDEPS < \
		<(sed -n -e 's/^[[:space:]]*\(make\)\?depends\(_x86_64\)\? = \([[:alnum:][:punct:]]*\)[[:space:]]*$/\3/p' .SRCINFO)
	sudo -H -u builder paru --sync --noconfirm "${PKGDEPS[@]}"
fi

# Make the builder user the owner of these files
# Without this, (e.g. only having every user have read/write access to the files),
# makepkg will try to change the permissions of the files itself which will fail since it does not own the files/have permission
# we can't do this earlier as it will change files that are for github actions, which results in warnings in github actions logs.
chown -R builder .

# Build packages
# INPUT_MAKEPKGARGS is intentionally unquoted to allow arg splitting
# shellcheck disable=SC2086
sudo -H -u builder CCACHE_DIR="$BASEDIR/.ccache" makepkg --syncdeps --noconfirm ${INPUT_MAKEPKGARGS:-}

# Get array of packages to be built
# shellcheck disable=SC2086
mapfile -t PKGFILES < <( sudo -u builder makepkg --packagelist ${INPUT_MAKEPKGARGS:-})
echo "Package(s): ${PKGFILES[*]}"

if [ -n "${INPUT_REPORELEASETAG:-}" ]; then
	# Download database files again in case another action updated them in the meantime
	download_database
	# Create package file list for the old database
	zcat "${INPUT_REPORELEASETAG:-}".db.tar.gz | strings | grep '.pkg.tar.' | sort > old_db.packages
fi

# Report built package archives
i=0
for PKGFILE in "${PKGFILES[@]}"; do
	# Replace colon (:) in files name because releases don't like it
	# It seems to not mess with pacman so it doesn't need to be guarded
	srcdir="$(dirname "$PKGFILE")"
	srcfile="$(basename "$PKGFILE")"
	if [[ "$srcfile" == *:* ]]; then
		dest="$srcdir/${srcfile//:/.}"
		mv "$PKGFILE" "$dest"
		PKGFILE="$dest"
	fi
	# makepkg reports absolute paths, must be relative for use by other actions
	RELPKGFILE="$(realpath --relative-base="$BASEDIR" "$PKGFILE")"
	# Caller arguments to makepkg may mean the pacakge is not built
	if [ -f "$PKGFILE" ]; then
		echo "pkgfile$i=$RELPKGFILE" >> $GITHUB_OUTPUT
		# Optionally add the packages to a makeshift repository in GitHub releases
		if [ -n "${INPUT_REPORELEASETAG:-}" ]; then
			sudo -u builder repo-add "${INPUT_REPORELEASETAG:-}".db.tar.gz "$(basename "$PKGFILE")"
		else
			echo "Skipping repository update for $RELPKGFILE"
		fi
	else
		echo "Archive $RELPKGFILE not built"
	fi
	(( ++i ))
done

if [ -n "${INPUT_REPORELEASETAG:-}" ]; then
	# Delete the `<repo_name>.db` and `repo_name.files` symlinks
	rm "${INPUT_REPORELEASETAG:-}".{db,files}
	# Copy repo archives to their suffix-less symlinks because symlinks are not uploaded to GitHub releases
	cp "${INPUT_REPORELEASETAG:-}".db{.tar.gz,}
	cp "${INPUT_REPORELEASETAG:-}".files{.tar.gz,}
	REPOFILES=("${INPUT_REPORELEASETAG:-}".{db{,.tar.gz},files{,.tar.gz}})
	j=0
	for REPOFILE in "${REPOFILES[@]}"; do
		RELREPOFILE="$(realpath --relative-base="$BASEDIR" "$(realpath -s "$REPOFILE")")"
		echo "repofile$j=$RELREPOFILE" >> $GITHUB_OUTPUT
		(( ++j ))
	done
	# List package files removed from the database
	zcat "${INPUT_REPORELEASETAG:-}".db.tar.gz | strings | grep '.pkg.tar.' | sort > new_db.packages
	k=0
	for OLDFILE in $(diff {old,new}_db.packages | grep -E "^<" | cut -c3-);do
		echo "oldfile$k=$OLDFILE" >> $GITHUB_OUTPUT
		(( ++k ))
	done
fi

function prepend () {
	# Prepend the argument to each input line
	while read -r line; do
		echo "$1$line"
	done
}

function namcap_check() {
	# Run namcap checks
	# Installing namcap after building so that makepkg happens on a minimal
	# install where any missing dependencies can be caught.
	pacman -S --noconfirm --needed namcap

	NAMCAP_ARGS=()
	if [ -n "${INPUT_NAMCAPRULES:-}" ]; then
		NAMCAP_ARGS+=( "-r" "${INPUT_NAMCAPRULES}" )
	fi
	if [ -n "${INPUT_NAMCAPEXCLUDERULES:-}" ]; then
		NAMCAP_ARGS+=( "-e" "${INPUT_NAMCAPEXCLUDERULES}" )
	fi

	# For reasons that I don't understand, sudo is not resetting '$PATH'
	# As a result, namcap finds program paths in /usr/sbin instead of /usr/bin
	# which makes namcap fail to identify the packages that provide the
	# program and so it emits spurious warnings.
	# More details: https://bugs.archlinux.org/task/66430
	#
	# Work around this issue by putting bin ahead of sbin in $PATH
	export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

	namcap "${NAMCAP_ARGS[@]}" PKGBUILD \
		| prepend "::warning file=$FILE,line=$LINENO::"
	for PKGFILE in "${PKGFILES[@]}"; do
		if [ -f "$PKGFILE" ]; then
			RELPKGFILE="$(realpath --relative-base="$BASEDIR" "$PKGFILE")"
			namcap "${NAMCAP_ARGS[@]}" "$PKGFILE" \
				| prepend "::warning file=$FILE,line=$LINENO::$RELPKGFILE:"
		fi
	done
}

if [ -z "${INPUT_NAMCAPDISABLE:-}" ]; then
	namcap_check
fi
