//
//  PocketServe1Tests.swift
//  PocketServe1Tests
//
//  Created by Paweł Goluda on 2026-09-19.
//

import Testing
import OpenAICompat
import ModelKit
@testable import PocketServe1

struct PocketServe1Tests {

    @Test func humanizeDistinguishesLoadFromDelete() {
        #expect(ModelsViewModel.humanize(.loadInProgress) == "Model is already loading")
        #expect(ModelsViewModel.humanize(.deleteInProgress) == "Cannot delete — another operation in progress")
        #expect(ModelsViewModel.humanize(.downloadInProgress) == "Download already in progress")
    }

    @Test func bridgeKeepsWireTokenForNewOps() {
        #expect(ModelsViewModel.bridge(.loadInProgress, op: .load) == .downloadInProgress)
        #expect(ModelsViewModel.bridge(.deleteInProgress, op: .delete) == .downloadInProgress)
    }

}
