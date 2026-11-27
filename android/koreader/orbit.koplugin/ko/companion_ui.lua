-- SPDX-License-Identifier: AGPL-3.0-or-later
function OrbitAndroid:onOrbitOpenCompanion() return Library.companion.openStatus() end
function OrbitAndroid:openCompanionHome() return Library.companion.openHome() end
function OrbitAndroid:onOrbitOpenApps() return Library.companion.openApps() end
