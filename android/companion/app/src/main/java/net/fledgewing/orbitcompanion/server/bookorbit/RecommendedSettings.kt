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
        mapOf("id" to "g.apps","kind" to "gesture","key" to "two_finger_swipe_north","ours" to mapOf("orbit_open_apps" to true),"needs" to "apps","label" to "Gesture: two-finger swipe up")
    )
}
