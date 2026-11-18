// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Testing
@testable import RoundhouseCore

@Suite struct AppInfoTests {
    @Test func versionIsNeverEmpty() {
        #expect(!AppInfo.version.isEmpty)
    }
}
