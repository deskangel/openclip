// AppIdentifying.swift
// OpenClip
//
// Represents external application identity (bundle identifier and localized name).

import Foundation

public struct AppIdentity: Sendable, Equatable, Hashable {
    public let bundleIdentifier: String?
    public let localizedName: String?
    public let processIdentifier: pid_t?

    public init(bundleIdentifier: String? = nil, localizedName: String? = nil, processIdentifier: pid_t? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.processIdentifier = processIdentifier
    }
}

