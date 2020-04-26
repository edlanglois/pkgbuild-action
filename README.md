# pkgbuild-action - Self Test
GitHub action to build and check a PKGBUILD package

**This branch is a self-test of the action on a simple PKGBUILD file**

## Features
* Checks that .SRCINFO matches PKGBUILD if .SRCINFO exists
* Builds package(s) with makepkg (configurable arguments)
* Runs on a bare minimum Arch Linux install to help detect missing dependencies
* Outputs built package archives
* Checks PKGBUILD and package archives with [namcap](https://wiki.archlinux.org/index.php/namcap)
