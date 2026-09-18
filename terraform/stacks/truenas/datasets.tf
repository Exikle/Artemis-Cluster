# The provider exposes no `atime` or `recordsize` attribute, so those two properties
# stay live-only and unmanaged. Every dataset here is atime=OFF, recordsize=1M on
# the box; a plan will never show drift in them because tofu cannot see them.

resource "truenas_dataset" "media" {
  name        = "atlas/media"
  type        = "filesystem"
  compression = "off"
}

resource "truenas_dataset" "backups" {
  name        = "atlas/backups"
  type        = "filesystem"
  compression = "lz4"
}

resource "truenas_dataset" "kopiur" {
  name        = "atlas/Kopiur"
  type        = "filesystem"
  compression = "lz4"
}

resource "truenas_dataset" "frigate" {
  name        = "atlas/frigate"
  type        = "filesystem"
  compression = "lz4"
}
