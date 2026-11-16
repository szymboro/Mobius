import Foundation

/// An entry from https://piped-instances.kavin.rocks/. Mirrors `api/obj/PipedInstance.kt`.
public struct PipedInstance: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var apiUrl: String
    public var locations: String
    public var version: String
    public var upToDate: Bool
    public var cdn: Bool
    public var registered: Int
    public var lastChecked: Int
    public var cache: Bool
    public var s3Enabled: Bool
    public var imageProxyUrl: String
    public var registrationDisabled: Bool
    public var uptimeToday: Double?
    public var uptimeWeek: Double?
    public var uptimeMonth: Double?
    public var isCurrentlyDown: Bool

    public var id: String { apiUrl }
    public var url: URL? { URL(string: apiUrl) }

    public init(
        name: String, apiUrl: String, locations: String = "", version: String = "",
        upToDate: Bool = true, cdn: Bool = false, registered: Int = 0, lastChecked: Int = 0,
        cache: Bool = false, s3Enabled: Bool = false, imageProxyUrl: String = "",
        registrationDisabled: Bool = false, uptimeToday: Double? = nil, uptimeWeek: Double? = nil,
        uptimeMonth: Double? = nil, isCurrentlyDown: Bool = false
    ) {
        self.name = name
        self.apiUrl = apiUrl
        self.locations = locations
        self.version = version
        self.upToDate = upToDate
        self.cdn = cdn
        self.registered = registered
        self.lastChecked = lastChecked
        self.cache = cache
        self.s3Enabled = s3Enabled
        self.imageProxyUrl = imageProxyUrl
        self.registrationDisabled = registrationDisabled
        self.uptimeToday = uptimeToday
        self.uptimeWeek = uptimeWeek
        self.uptimeMonth = uptimeMonth
        self.isCurrentlyDown = isCurrentlyDown
    }

    enum CodingKeys: String, CodingKey {
        case name
        case apiUrl = "api_url"
        case locations, version
        case upToDate = "up_to_date"
        case cdn, registered
        case lastChecked = "last_checked"
        case cache
        case s3Enabled = "s3_enabled"
        case imageProxyUrl = "image_proxy_url"
        case registrationDisabled = "registration_disabled"
        case uptimeToday = "uptime_24h"
        case uptimeWeek = "uptime_7d"
        case uptimeMonth = "uptime_30d"
        case isCurrentlyDown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiUrl = c.string(.apiUrl, default: "")
        name = c.string(.name) ?? apiUrl
        locations = c.string(.locations, default: "")
        version = c.string(.version, default: "")
        upToDate = c.bool(.upToDate, default: true)
        cdn = c.bool(.cdn, default: false)
        registered = c.int(.registered, default: 0)
        lastChecked = c.int(.lastChecked, default: 0)
        cache = c.bool(.cache, default: false)
        s3Enabled = c.bool(.s3Enabled, default: false)
        imageProxyUrl = c.string(.imageProxyUrl, default: "")
        registrationDisabled = c.bool(.registrationDisabled, default: false)
        uptimeToday = c.double(.uptimeToday)
        uptimeWeek = c.double(.uptimeWeek)
        uptimeMonth = c.double(.uptimeMonth)
        isCurrentlyDown = c.bool(.isCurrentlyDown, default: false)
    }
}
