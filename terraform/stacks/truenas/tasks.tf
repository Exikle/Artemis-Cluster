resource "truenas_periodic_snapshot_task" "media" {
  dataset        = "atlas/media"
  recursive      = true
  lifetime_value = 7
  lifetime_unit  = "DAY"
  naming_schema  = "auto-%Y-%m-%d_%H-%M"
  enabled        = true
  allow_empty    = true

  schedule = {
    minute = "0"
    hour   = "0"
    dom    = "*"
    month  = "*"
    dow    = "*"
  }
}

resource "truenas_periodic_snapshot_task" "backups" {
  dataset        = "atlas/backups"
  recursive      = true
  lifetime_value = 30
  lifetime_unit  = "DAY"
  naming_schema  = "auto-%Y-%m-%d_%H-%M"
  enabled        = true
  allow_empty    = true

  schedule = {
    minute = "0"
    hour   = "0"
    dom    = "*"
    month  = "*"
    dow    = "*"
  }
}

resource "truenas_scrub_task" "atlas_weekly" {
  pool      = data.truenas_pool.atlas.id
  threshold = 35
  enabled   = true

  schedule = {
    minute = "00"
    hour   = "00"
    dom    = "*"
    month  = "*"
    dow    = "7"
  }
}
