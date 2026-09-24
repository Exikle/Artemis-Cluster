# The CRS309-1G-8S+ core switch. Adopted, never authored: every resource was imported
# from the live switch and `tofu plan` must report no changes before anything is edited.
#
# Deliberately NOT managed here:
#
#   * `/ip dns`. The provider cannot import it and would overwrite the live settings
#     on first apply, so it stays live-only.
#   * The `tofu-ca` / `tofu-api` certificates. They exist only so this provider can
#     reach api-ssl over TLS; managing them here would make the stack depend on itself.
#   * Users and SSH keys. The login the provider uses is not something it should edit.
#   * `/system clock`. Its resource carries the literal date and time, so every plan
#     would drift and an apply would wind the clock back. NTP sets it instead.
#   * `/interface ethernet` (the SFP ports). The resource needs `factory_name`, which
#     import cannot fill, so the first plan always updates every port in place — and
#     sfp1/sfp8 carry the UCG uplink and pantheon. Add them in a late-night window.
#   * `/ip service`. The provider keys it by name, and RouterOS 7.20 lists each live
#     ssh/winbox session as another row with the same name, so import and read both
#     fail. Service lockdown is done on the switch directly.
#
# Resource blocks are in switch.tf. They were produced by `tofu plan -generate-config-out`
# from `import` blocks (removed once applied) and trimmed of null attributes.
