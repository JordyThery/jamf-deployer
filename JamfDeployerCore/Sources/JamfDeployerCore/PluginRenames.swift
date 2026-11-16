import Foundation

/// Attributes an engine plugin release renamed or added, which the first
/// refresh after updating fills in although nothing changed in Jamf: the old
/// state has no value for them. jamfplatform 1.8.0 gave PreStage attributes
/// and Setup Assistant panes the admin UI's names (the old names stay until
/// 2027-02-03, holding the same value) and added new panes. Tables read from
/// jamfplatform 1.9.0's source.
nonisolated enum PluginRenames {
    struct Rename: Sendable {
        let old: String
        let new: String
        /// The new attribute holds the opposite value of the old one.
        var inverted = false
    }

    static let byResourceType: [String: (renames: [Rename], added: Set<String>)] = [
        "jamfplatform_pro_computer_prestage_enrollment": (
            renames: [
                Rename(old: "authentication_prompt", new: "authentication_message"),
                Rename(old: "auto_advance_setup", new: "automatically_advance_through_setup_assistant"),
                Rename(old: "hidden_admin_account", new: "hide_managed_local_administrator_account"),
                Rename(old: "keep_existing_location_information", new: "use_existing_location_information"),
                Rename(old: "keep_existing_site_membership", new: "use_existing_site_membership"),
                Rename(old: "local_admin_account_enabled", new: "create_managed_local_administrator_account"),
                Rename(old: "local_user_managed", new: "make_managed_local_administrator_account_mdm_enabled"),
                Rename(old: "mandatory", new: "make_mdm_profile_mandatory"),
                Rename(old: "mdm_removable", new: "allow_mdm_profile_removal"),
                Rename(old: "prevent_prefill_info_from_modification", new: "lock_primary_account_information"),
                Rename(old: "skip_setup_items.appearance", new: "skip_setup_items.choose_your_look"),
                Rename(old: "skip_setup_items.diagnostics", new: "skip_setup_items.app_analytics"),
                Rename(old: "skip_setup_items.display_tone", new: "skip_setup_items.true_tone_display"),
                Rename(old: "skip_setup_items.icloud_storage", new: "skip_setup_items.all_your_files_in_icloud"),
                Rename(old: "skip_setup_items.restore", new: "skip_setup_items.transfer_information"),
                Rename(old: "skip_setup_items.tos", new: "skip_setup_items.terms_and_conditions"),
                Rename(old: "skip_setup_items.welcome", new: "skip_setup_items.get_started"),
            ],
            added: ["skip_setup_items.liquid_glass"]
        ),
        "jamfplatform_pro_mobile_device_prestage_enrollment": (
            renames: [
                Rename(old: "authentication_prompt", new: "authentication_message"),
                Rename(old: "auto_advance_setup", new: "automatically_advance_through_setup_assistant"),
                Rename(old: "configure_device_before_setup_assistant", new: "install_configuration_profiles_before_setup_assistant"),
                Rename(old: "default_prestage", new: "automatically_assign_new_devices"),
                Rename(old: "install_apps_during_enrollment", new: "install_managed_apps_before_setup_assistant"),
                Rename(old: "keep_existing_location_information", new: "use_existing_location_information"),
                Rename(old: "keep_existing_site_membership", new: "use_existing_site_membership"),
                Rename(old: "mandatory", new: "make_mdm_profile_mandatory"),
                Rename(old: "mdm_removable", new: "prevent_unenrollment", inverted: true),
                Rename(old: "multi_user", new: "enable_shared_ipad"),
                Rename(old: "require_authentication", new: "require_credentials_for_enrollment"),
                Rename(old: "rts_enabled", new: "allow_return_to_service"),
                Rename(old: "send_timezone", new: "set_time_zone"),
                Rename(old: "skip_setup_items.appearance", new: "skip_setup_items.choose_your_look"),
                Rename(old: "skip_setup_items.diagnostics", new: "skip_setup_items.app_analytics"),
                Rename(old: "skip_setup_items.display_tone", new: "skip_setup_items.true_tone_display"),
                Rename(old: "skip_setup_items.onboarding", new: "skip_setup_items.new_feature_highlights"),
                Rename(old: "skip_setup_items.restore", new: "skip_setup_items.apps_and_data"),
                Rename(old: "skip_setup_items.safety", new: "skip_setup_items.emergency_sos"),
                Rename(old: "skip_setup_items.screen_saver", new: "skip_setup_items.see_the_world_screensaver"),
                Rename(old: "skip_setup_items.sim_setup", new: "skip_setup_items.add_cellular_plan"),
                Rename(old: "skip_setup_items.spoken_language", new: "skip_setup_items.dictation"),
                Rename(old: "skip_setup_items.tap_to_setup", new: "skip_setup_items.set_up_your_apple_tv"),
                Rename(old: "skip_setup_items.tos", new: "skip_setup_items.terms_and_conditions"),
                Rename(old: "skip_setup_items.tv_home_screen_sync", new: "skip_setup_items.one_home_screen_for_every_apple_tv"),
                Rename(old: "skip_setup_items.tv_room", new: "skip_setup_items.where_is_this_apple_tv"),
                Rename(old: "skip_setup_items.update_completed", new: "skip_setup_items.software_update_completed"),
                Rename(old: "skip_setup_items.watch_migration", new: "skip_setup_items.apple_watch"),
                Rename(old: "skip_setup_items.welcome", new: "skip_setup_items.get_started"),
                Rename(old: "skip_setup_items.zoom", new: "skip_setup_items.display_zoom"),
            ],
            added: ["skip_setup_items.liquid_glass", "skip_setup_items.device_features_tour"]
        ),
    ]

    /// True when the change at `path` only echoes a renamed or added
    /// attribute: no value before, and either a pane new in the plugin, or
    /// the old attribute's unchanged value (opposite, for an inverted pair).
    /// A change made in Jamf changes the old attribute too, so it still shows.
    static func isEcho(path: String, resourceType: String, before: JSONValue?, after: JSONValue?) -> Bool {
        guard let table = byResourceType[resourceType], value(at: path, in: before) == .null else { return false }
        if table.added.contains(path) { return true }
        guard let rename = table.renames.first(where: { $0.new == path }) else { return false }
        let oldBefore = value(at: rename.old, in: before)
        let oldAfter = value(at: rename.old, in: after)
        let newAfter = value(at: path, in: after)
        guard oldBefore == oldAfter, oldAfter != .null else { return false }
        if rename.inverted {
            guard let old = oldAfter.boolValue, let new = newAfter.boolValue else { return false }
            return new == !old
        }
        return newAfter == oldAfter
    }

    /// The value at a dotted path (`skip_setup_items.tos`), `.null` when absent.
    static func value(at path: String, in json: JSONValue?) -> JSONValue {
        var current = json ?? .null
        for key in path.split(separator: ".") {
            current = current.objectValue?[String(key)] ?? .null
        }
        return current
    }
}
