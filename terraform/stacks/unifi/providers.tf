# api_url, api_key, site and allow_insecure all come from the environment
# (UNIFI_API, UNIFI_API_KEY, UNIFI_SITE, UNIFI_INSECURE) via secrets.env, so no
# credential or endpoint is duplicated in configuration.
provider "unifi" {}
