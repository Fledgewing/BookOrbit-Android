package net.fledgewing.orbitcompanion

/** NET_UP and Wi-Fi callbacks share one attempt per connected Wi-Fi period. */
class VpnConnectGate {
    private var requested = false
    @Synchronized fun request(wifi: Boolean, vpn: Boolean): Boolean {
        if (!wifi) return false
        if (vpn) { requested = true; return false }
        if (requested) return false
        requested = true
        return true
    }
    @Synchronized fun disconnected() { requested = false }
}
