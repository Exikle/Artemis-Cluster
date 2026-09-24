# TrueNAS 25.04 has no LLDP service and a read-only /usr, so lldpd runs as a custom app.
# The host is named truenas.local; only the LLDP advertisement is renamed to atlas.
# The compose string is write-only in the provider: a change here is applied, but drift on
# atlas is not detected.
resource "truenas_app" "lldpd" {
  name       = "lldpd"
  custom_app = true
  running    = true

  custom_compose_config_string = yamlencode({
    services = {
      lldpd = {
        image        = "ghcr.io/lldpd/lldpd:1.0.22@sha256:c12c113c432212b207e42d2a7caff81b22258c96858616c79c50af3c8fbb54c8"
        entrypoint   = ["/bin/sh", "-c"]
        command      = ["echo 'configure system hostname atlas.dcunha.io' > /etc/lldpd.d/atlas.conf && exec lldpd -d -I enp4s0 -m '10.10.99.*'"]
        network_mode = "host"
        cap_add      = ["NET_ADMIN", "NET_RAW"]
        restart      = "unless-stopped"
        volumes      = ["/etc/os-release:/etc/os-release:ro"]
      }
    }
  })
}
