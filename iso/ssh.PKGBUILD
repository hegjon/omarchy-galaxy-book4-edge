# SSH into a test install from one network only. iso/build.sh builds this when
# given --ssh-from and --authorized-keys: the keys may log in as any user but
# root, from that network (from= in authorized_keys and a ufw rule).
pkgname=samsung-galaxy-book4-edge-14-ssh
pkgver=1
pkgrel=1
pkgdesc='SSH access to a Samsung Galaxy Book4 Edge 14 test install from one network'
arch=(any)
license=(0BSD)
depends=(openssh ufw)
source=(authorized_keys sshd.conf samsung-galaxy-book4-edge-14-ssh.service)
sha256sums=(SKIP SKIP SKIP)

package() {
  install -Dm644 authorized_keys "$pkgdir/etc/ssh/samsung-galaxy-book4-edge-14-authorized_keys"
  install -Dm644 sshd.conf "$pkgdir/etc/ssh/sshd_config.d/50-samsung-galaxy-book4-edge-14.conf"
  install -Dm644 -t "$pkgdir/usr/lib/systemd/system" samsung-galaxy-book4-edge-14-ssh.service
  install -d "$pkgdir/usr/lib/systemd/system/multi-user.target.wants"
  ln -s ../samsung-galaxy-book4-edge-14-ssh.service \
    "$pkgdir/usr/lib/systemd/system/multi-user.target.wants/samsung-galaxy-book4-edge-14-ssh.service"
}
