import Foundation

/// Best-effort advisory only, not a verified update channel. Google Play's
/// public listing never exposes an exact versionName/versionCode -- only a
/// human "last updated" date -- so this can only suggest that a newer TFT
/// build likely exists. It never downloads or installs anything; the
/// verified, signed hosted feed (see HostedGameUpdate) is the only path that
/// can actually update installed game bytes, and repinning the local pin in
/// this repo still requires real split APKs (scripts/switch-to-vng-tft.command).
enum PlayStoreUpdateAdvisory {
    struct CheckResult: Equatable {
        let latestUpdateDate: String
        /// true only when a prior date was recorded and it differs from the
        /// latest one -- i.e. this is not the first-ever check.
        let changed: Bool
    }

    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    private static let labelPattern: NSRegularExpression = {
        // Fixed Vietnamese label text anchors the match even as Play's
        // obfuscated CSS class names churn between deploys.
        let pattern = "Lần cập nhật gần đây nhất</div><div[^>]*>([^<]+)</div>"
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Synchronous, blocking network call: call from a background queue only.
    static func check(
        packageName: String = MacticianIdentity.tftPlayStorePackageName,
        previousDate: String?
    ) throws -> CheckResult {
        var components = URLComponents(string: "https://play.google.com/store/apps/details")!
        components.queryItems = [
            URLQueryItem(name: "id", value: packageName),
            URLQueryItem(name: "hl", value: "vi"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("vi-VN,vi;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 15

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error> = .failure(LauncherError.cancelled)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(LauncherError.process("The Play Store listing returned no data"))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        let (data, response) = try result.get()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LauncherError.process("The Play Store listing request failed")
        }
        guard let html = String(data: data, encoding: .utf8),
              let date = extractLatestUpdateDate(from: html) else {
            throw LauncherError.process("Could not read the \"last updated\" date from the Play Store listing")
        }
        return CheckResult(
            latestUpdateDate: date,
            changed: previousDate != nil && previousDate != date
        )
    }

    static func extractLatestUpdateDate(from html: String) -> String? {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = labelPattern.firstMatch(in: html, range: range),
              let group = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[group])
    }
}
