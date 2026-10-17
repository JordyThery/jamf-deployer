resource "jamfplatform_device_group" "computers_with_rosetta" {
  provider = jamfplatform

  criteria = [
    {
      and_or   = "and"
      criteria = "Rosetta installed"
      operator = "is"
      order    = 0
      value    = "Yes"
    },
  ]
  description = "Smart group keyed on the Rosetta extension attribute."
  group_type  = "smart"
  name        = "JD - Computers with Rosetta"
}
