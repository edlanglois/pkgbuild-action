# Maintainer: Eric Langlois <eric@langlois.xyz>
pkgname=(helloworld hw)
pkgver=1.0.0
pkgrel=1
pkgdesc="Hello World"
url="http://www.example.com"
arch=('any')
license=('MIT')
depends=(python)
checkdepends=()
makedepends=()
source=(helloworld.py)
sha256sums=('61b911f2d8b9e9f52e512aa7e273240cbd26bcaf0a5cae4abed5a7a53fdde6e7')

build() {
	cp helloworld.py helloworld
	chmod u+x helloworld
}

check() {
	./helloworld
}

package_helloworld() {
	install -m755 -D "helloworld" "$pkgdir/usr/bin/helloworld"
}

package_hw() {
	install -m755 -D "helloworld" "$pkgdir/usr/bin/hw"
}
