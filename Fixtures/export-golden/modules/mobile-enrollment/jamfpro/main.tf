data "jamfpro_device_enrollments" "instance" {
  name = var.ade_instance_name
}

# The Jamf Pro API sets every PreStage field; those the Platform API leaves
# at Jamf Pro's defaults are spelled out here with the same values.
resource "jamfpro_mobile_device_prestage_enrollment" "standard" {
  display_name                          = "${var.name_prefix}${var.prestage_display_name}"
  device_enrollment_program_instance_id = data.jamfpro_device_enrollments.instance.id
  timezone                              = "UTC"

  supervised                                   = true
  mandatory                                    = true
  mdm_removable                                = false
  allow_pairing                                = false
  prevent_activation_lock                      = true
  enable_device_based_activation_lock          = false
  install_apps_during_enrollment               = true
  default_prestage                             = var.default_prestage
  auto_advance_setup                           = false
  configure_device_before_setup_assistant      = false
  require_authentication                       = false
  authentication_prompt                        = ""
  keep_existing_site_membership                = false
  keep_existing_location_information           = false
  multi_user                                   = false
  maximum_shared_accounts                      = 10
  use_storage_quota_size                       = false
  storage_quota_size_megabytes                 = 1024
  enrollment_customization_id                  = "0"
  prestage_minimum_os_target_version_type_ios  = "NO_ENFORCEMENT"
  prestage_minimum_os_target_version_type_ipad = "NO_ENFORCEMENT"
  department                                   = ""
  language                                     = ""
  region                                       = ""

  support_email_address = var.support_email
  support_phone_number  = var.support_phone

  location_information {
    username      = ""
    realname      = ""
    phone         = ""
    email         = ""
    room          = ""
    position      = ""
    department_id = "-1"
    building_id   = "-1"
  }

  purchasing_information {
    leased             = false
    purchased          = true
    apple_care_id      = ""
    po_number          = ""
    vendor             = ""
    purchase_price     = ""
    life_expectancy    = 0
    purchasing_account = ""
    purchasing_contact = ""
  }

  names {
    assign_names_using       = "Default Names"
    device_naming_configured = false
    manage_names             = false
  }

  # Business Setup Assistant: skip consumer panes, keep language, Wi-Fi,
  # passcode and terms interactive.
  skip_setup_items {
    apple_id                = true
    android                 = true
    appearance              = true
    diagnostics             = true
    imessage_and_facetime   = true
    intelligence            = true
    payment                 = true
    restore                 = true
    screen_time             = true
    siri                    = true
    transfer_data           = true
    watch_migration         = true
    action_button           = false
    biometric               = false
    camera_button           = false
    cloud_storage           = false
    display_tone            = false
    enable_lockdown_mode    = false
    express_language        = false
    home_button_sensitivity = false
    keyboard                = false
    location                = false
    multitasking            = false
    onboarding              = false
    os_showcase             = false
    passcode                = false
    preferred_language      = false
    privacy                 = false
    restore_completed       = false
    safety                  = false
    safety_and_handling     = false
    screen_saver            = false
    sim_setup               = false
    software_update         = false
    spoken_language         = false
    tap_to_setup            = false
    terms_of_address        = false
    tos                     = false
    tv_home_screen_sync     = false
    tv_provider_sign_in     = false
    tv_room                 = false
    update_completed        = false
    voice_selection         = false
    welcome                 = false
    zoom                    = false
  }
}
