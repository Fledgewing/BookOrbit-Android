// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

/** Local native binding identifiers only; no credentials or protocol objects leave the adapter. */
internal object RecommendedSettings {
    val items=listOf(
        mapOf("id" to "bo.auto_sync","kind" to "connector","key" to "auto_sync","ours" to true,"label" to "Connector: Auto-sync"),
        mapOf("id" to "bo.sync_forward","kind" to "connector","key" to "sync_forward","ours" to 2L,"label" to "Connector: When the library is further ahead"),
        mapOf("id" to "bo.home","kind" to "connector","key" to "catalog_auto_open","ours" to "home","label" to "Connector: Make the library home"),
        mapOf("id" to "ko.wifi_on","kind" to "ko","key" to "wifi_enable_action","ours" to "turn_on","stock" to "prompt","needs" to "wifi","required_by" to "wifi","label" to "KOReader: Action when Wi-Fi is off"),
        mapOf("id" to "g.sync_sleep","kind" to "gesture","key" to "hold_top_right_corner","ours" to mapOf("orbit_sync_and_sleep" to true),"label" to "Gesture: hold top-right corner"),
        mapOf("id" to "g.sync_all","kind" to "gesture","key" to "hold_top_left_corner","ours" to mapOf("bookorbit_sync_now" to true),"label" to "Gesture: hold top-left corner"),
        mapOf("id" to "g.this_book","kind" to "gesture","key" to "one_finger_swipe_bottom_edge_right","ours" to mapOf("bookorbit_this_book" to true),"label" to "Gesture: swipe right along the bottom edge"),
        mapOf("id" to "g.apps","kind" to "gesture","key" to "two_finger_swipe_north","ours" to mapOf("orbit_open_apps" to true),"needs" to "apps","label" to "Gesture: two-finger swipe up"),
        mapOf("id" to "g.no_flip","kind" to "gesture","key" to "tap_top_left_corner","ours" to emptyMap<String,Any?>(),"label" to "Gesture: tap top-left corner"),
        mapOf("id" to "o.clean_menus","kind" to "owned","key" to "clean_menus","ours" to true,"untouched_only" to true,"label" to "BookSync: Reading menus")
    ).map { item ->
        val labels=when(item["key"]) {
            "sync_forward" -> mapOf("1" to "Ask","2" to "Silent","3" to "Don't sync")
            "catalog_auto_open" -> mapOf("off" to "Off","filemanager" to "File browser","home" to "Library home")
            "wifi_enable_action" -> mapOf("turn_on" to "Turn on","prompt" to "Ask","ignore" to "Ignore")
            else -> mapOf("orbit_sync_and_sleep" to "BookSync: Sync and sleep","bookorbit_sync_now" to "BookSync: Sync all books",
                "bookorbit_this_book" to "BookSync: This book","orbit_open_apps" to "BookSync: Other apps",
                "increase_frontlight" to "Brighter frontlight","toggle_page_flipping" to "Page flipping")
        }
        item+mapOf("value_labels" to labels)
    }
}
