# SSH on atlas is key-only, with no weak ciphers (2026-09-23). The provider adopts this
# singleton on create; other SSH settings are left as they are on atlas. Note that
# `midclt call ssh.config` on atlas prints the host private keys — do not paste its output.
resource "truenas_ssh_config" "this" {
  passwordauth = false
  weak_ciphers = []
}

# iSCSI had zero targets, extents or portals when it was switched off (2026-09-23).
resource "truenas_service" "iscsitarget" {
  name    = "iscsitarget"
  enabled = false
}
