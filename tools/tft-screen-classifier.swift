import CoreGraphics
import Foundation
import ImageIO
import Vision

private let referenceWidth = 2560
private let referenceHeight = 1440
private let supportedDimensions: Set<String> = [
    "2560x1440",
    "2880x1620",
    "3200x1800",
    "3840x2160",
]
// Tocker's Trials keeps its combat timer directly below the round strip.  The
// old crop stopped at y=50 and therefore missed the bar (y=58...78) entirely.
private let referenceCombatProgressRegion = CGRect(x: 700, y: 0, width: 650, height: 95)
private let referenceCombatCyanRunThreshold = 80
// Shop cards are laid out in the game's 2048x1152 Slate space. The Android
// input viewport and screencap scale that space by 5/4 at 1440p. Higher-density
// presets keep card widths pixel-stable and move the whole strip toward the
// physical right edge, matching shop_card_x() in the autonomous harness.
private let referenceShopCardCenters = [1055, 1275, 1490, 1710]

private enum ScreenState: String {
    case patchAvailable = "patch_available"
    case patchReady = "patch_ready"
    case patching
    case cosmeticNotice = "cosmetic_notice"
    case lobby
    case modeSelect = "mode_select"
    case trialsLobby = "trials_lobby"
    case matchFound = "match_found"
    case matchAccepted = "match_accepted"
    case trialEnded = "trial_ended"
    case settings
    case surrenderConfirm = "surrender_confirm"
    case trialResults = "trial_results"
    case loginServiceError = "login_service_error"
    case battle
    case trialChoice = "trial_choice"
    case disconnected
    case login
    case error
    case unknown
}

private enum ClassifierError: Error, CustomStringConvertible {
    case invalidArguments
    case missingFile(String)
    case unreadableFile(String)
    case notPNG
    case invalidImage
    case wrongDimensions(Int, Int)
    case recognitionFailed(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "expected exactly one PNG path"
        case let .missingFile(path):
            return "file does not exist: \(path)"
        case let .unreadableFile(path):
            return "file is not readable: \(path)"
        case .notPNG:
            return "input is not a PNG file"
        case .invalidImage:
            return "PNG cannot be decoded"
        case let .wrongDimensions(width, height):
            return "supported 16:9 dimensions are \(supportedDimensions.sorted().joined(separator: ", ")); got \(width)x\(height)"
        case let .recognitionFailed(message):
            return "Vision text recognition failed: \(message)"
        }
    }
}

private struct OCRLine {
    let text: String
    let normalized: String
    let compact: String
    let confidence: Float
    let boundingBox: CGRect
}

private struct Classification {
    let state: ScreenState
    let stage: String?
    let reason: String
    let evidence: [String]
}

private let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func normalizedText(_ value: String) -> String {
    let punctuationNormalized = value
        .replacingOccurrences(of: "’", with: "'")
        .replacingOccurrences(of: "‘", with: "'")
        .replacingOccurrences(of: "`", with: "'")
        .replacingOccurrences(of: "–", with: "-")
        .replacingOccurrences(of: "—", with: "-")
        .replacingOccurrences(of: "−", with: "-")

    return punctuationNormalized
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .uppercased(with: Locale(identifier: "en_US_POSIX"))
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

private func compactText(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics
    return String(value.unicodeScalars.filter { allowed.contains($0) })
}

private func loadImage(at url: URL) throws -> CGImage {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else {
        throw ClassifierError.missingFile(url.path)
    }
    guard fileManager.isReadableFile(atPath: url.path) else {
        throw ClassifierError.unreadableFile(url.path)
    }

    let data: Data
    do {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
        throw ClassifierError.unreadableFile(url.path)
    }
    guard data.count >= pngSignature.count, data.prefix(pngSignature.count) == pngSignature else {
        throw ClassifierError.notPNG
    }

    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ClassifierError.invalidImage
    }
    guard supportedDimensions.contains("\(image.width)x\(image.height)") else {
        throw ClassifierError.wrongDimensions(image.width, image.height)
    }
    return image
}

private func recognizeText(in image: CGImage) throws -> [OCRLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US", "ru-RU"]
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.008
    request.customWords = [
        "Teamfight Tactics",
        "Tocker's Trials",
        "Treasure Realms",
        "Loadouts",
        "Reroll",
        "Match Found",
        "Match Accepted",
        "Reconnect",
        "Choose One",
        "Time Bonus",
        "Description",
        "Доступно обновление",
        "Скачать",
        "Загрузка",
        "Установка",
        "Играть",
        "Пропуск",
        "Царства сокровищ",
        "Сборки",
    ]

    do {
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
    } catch {
        throw ClassifierError.recognitionFailed(error.localizedDescription)
    }

    let observations = (request.results ?? []).sorted {
        let verticalDelta = $0.boundingBox.midY - $1.boundingBox.midY
        if abs(verticalDelta) > 0.01 {
            return verticalDelta > 0
        }
        return $0.boundingBox.minX < $1.boundingBox.minX
    }

    return observations.compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else {
            return nil
        }
        let normalized = normalizedText(candidate.string)
        guard !normalized.isEmpty else {
            return nil
        }
        return OCRLine(
            text: candidate.string,
            normalized: normalized,
            compact: compactText(normalized),
            confidence: candidate.confidence,
            boundingBox: observation.boundingBox
        )
    }
}

private func recognizeTopStageText(in image: CGImage) throws -> [OCRLine] {
    let scaleX = CGFloat(image.width) / CGFloat(referenceWidth)
    let scaleY = CGFloat(image.height) / CGFloat(referenceHeight)
    let region = CGRect(
        x: 630 * scaleX,
        y: 0,
        width: 800 * scaleX,
        height: 95 * scaleY
    ).integral
    guard let crop = image.cropping(to: region) else {
        return []
    }

    // Full-frame Vision occasionally drops the tiny stage label during combat
    // when the adjacent timer is animated. A dedicated top-strip pass keeps the
    // semantic stage gate stable without relaxing it to a pixel heuristic.
    return try recognizeText(in: crop).map { line in
        OCRLine(
            text: line.text,
            normalized: line.normalized,
            compact: line.compact,
            confidence: line.confidence,
            boundingBox: CGRect(
                x: (region.minX / CGFloat(image.width))
                    + line.boundingBox.minX * (region.width / CGFloat(image.width)),
                y: 0.94,
                width: line.boundingBox.width * (region.width / CGFloat(image.width)),
                height: 0.04
            )
        )
    }
}

private func recognizeBoardOccupancyText(in image: CGImage) throws -> [OCRLine] {
    let scaleX = CGFloat(image.width) / CGFloat(referenceWidth)
    let scaleY = CGFloat(image.height) / CGFloat(referenceHeight)
    let region = CGRect(
        x: 850 * scaleX,
        y: 250 * scaleY,
        width: 850 * scaleX,
        height: 350 * scaleY
    ).integral
    guard let crop = image.cropping(to: region) else {
        return []
    }

    // Shop cards and Trial tooltips overlap the large arena counter often
    // enough that full-frame Vision drops `3/4`. A dedicated center crop keeps
    // the one-swipe reinforcement gate observable without loosening it to a
    // stage-based guess.
    return try recognizeText(in: crop).map { line in
        OCRLine(
            text: line.text,
            normalized: line.normalized,
            compact: line.compact,
            confidence: line.confidence,
            boundingBox: CGRect(
                x: (region.minX / CGFloat(image.width))
                    + line.boundingBox.minX * (region.width / CGFloat(image.width)),
                y: 1.0 - (region.maxY / CGFloat(image.height))
                    + line.boundingBox.minY * (region.height / CGFloat(image.height)),
                width: line.boundingBox.width * (region.width / CGFloat(image.width)),
                height: line.boundingBox.height * (region.height / CGFloat(image.height))
            )
        )
    }
}

private func combatCyanMetrics(in image: CGImage) -> (pixels: Int, longestRun: Int) {
    let scaleX = CGFloat(image.width) / CGFloat(referenceWidth)
    let scaleY = CGFloat(image.height) / CGFloat(referenceHeight)
    let combatProgressRegion = CGRect(
        x: referenceCombatProgressRegion.origin.x * scaleX,
        y: referenceCombatProgressRegion.origin.y * scaleY,
        width: referenceCombatProgressRegion.width * scaleX,
        height: referenceCombatProgressRegion.height * scaleY
    ).integral
    guard let croppedImage = image.cropping(to: combatProgressRegion) else {
        return (0, 0)
    }

    let width = croppedImage.width
    let height = croppedImage.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    return pixels.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress,
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return (0, 0)
        }

        context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = buffer.bindMemory(to: UInt8.self)
        var count = 0
        var longestRun = 0
        for y in 0..<height {
            var currentRun = 0
            for x in 0..<width {
                let index = y * bytesPerRow + x * bytesPerPixel
                let red = bytes[index]
                let green = bytes[index + 1]
                let blue = bytes[index + 2]
                if red < 120, green > 170, blue > 170 {
                    count += 1
                    currentRun += 1
                    longestRun = max(longestRun, currentRun)
                } else {
                    currentRun = 0
                }
            }
        }
        return (count, longestRun)
    }
}

private func dominantColor(in image: CGImage, region: CGRect) -> (red: Int, green: Int, blue: Int)? {
    guard let croppedImage = image.cropping(to: region.integral) else {
        return nil
    }
    let width = croppedImage.width
    let height = croppedImage.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    return pixels.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress,
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return nil
        }

        context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = buffer.bindMemory(to: UInt8.self)
        var histogram: [Int: Int] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let index = y * bytesPerRow + x * bytesPerPixel
                let red = Int(bytes[index])
                let green = Int(bytes[index + 1])
                let blue = Int(bytes[index + 2])
                // Text, coin glyphs and card-border highlights are much
                // brighter than the flat tier-colored nameplate.
                guard max(red, green, blue) < 140 else {
                    continue
                }
                let key = (red / 4) << 12 | (green / 4) << 6 | (blue / 4)
                histogram[key, default: 0] += 1
            }
        }
        guard let mode = histogram.max(by: { $0.value < $1.value })?.key else {
            return nil
        }
        return (
            red: ((mode >> 12) & 0x3f) * 4 + 2,
            green: ((mode >> 6) & 0x3f) * 4 + 2,
            blue: (mode & 0x3f) * 4 + 2
        )
    }
}

private func shopCost(red: Int, green: Int, blue: Int) -> Int {
    // TFT encodes unit cost directly in the nameplate hue. Check the saturated
    // purple and gold tiers before blue so every >=3 tier remains purchasable
    // even if its exact OCR price glyph is omitted or confused with the coin.
    if red > green * 5 / 4, blue > green * 5 / 4 {
        return 4
    }
    if red > blue * 5 / 4, green > blue * 5 / 4 {
        return 5
    }
    if blue > green * 3 / 2 {
        return 3
    }
    if green > red * 2, green > blue {
        return 2
    }
    return 1
}

private func shopCosts(in image: CGImage, shopOpen: Bool) -> [Int] {
    guard shopOpen else {
        return []
    }
    let heightScale = CGFloat(image.height) / CGFloat(referenceHeight)
    let slateToPixels = CGFloat(image.height) / 1152.0
    return referenceShopCardCenters.map { referenceCenter in
        let densityAdjustedCenter = 2040.0
            + (CGFloat(referenceCenter) - 2040.0) / heightScale
        let centerX = densityAdjustedCenter * slateToPixels
        // The left edge of the nameplate contains the largest uninterrupted
        // tier-color patch; the champion name and price sit farther right.
        let region = CGRect(x: centerX - 125, y: 315, width: 40, height: 30)
        guard let color = dominantColor(in: image, region: region) else {
            return 0
        }
        return shopCost(red: color.red, green: color.green, blue: color.blue)
    }
}

private func classifierSelfTest() -> Bool {
    let noisyOccupancy = OCRLine(
        text: "473/4",
        normalized: "473/4",
        compact: "4734",
        confidence: 1,
        boundingBox: CGRect(x: 0.45, y: 0.64, width: 0.1, height: 0.04)
    )
    let battle = Classification(
        state: .battle,
        stage: "1-2",
        reason: "self_test",
        evidence: []
    )
    let timeBonus = OCRLine(
        text: "TIME BONUS +12",
        normalized: "TIME BONUS +12",
        compact: "TIMEBONUS12",
        confidence: 1,
        boundingBox: CGRect(x: 0.4, y: 0.7, width: 0.2, height: 0.04)
    )
    let planning = OCRLine(
        text: "FIGHT",
        normalized: "FIGHT",
        compact: "FIGHT",
        confidence: 1,
        boundingBox: CGRect(x: 0.8, y: 0.1, width: 0.1, height: 0.04)
    )
    let russianStage = OCRLine(
        text: "4-6",
        normalized: "4-6",
        compact: "46",
        confidence: 1,
        boundingBox: CGRect(x: 0.48, y: 0.91, width: 0.04, height: 0.03)
    )
    let russianBattleHUD = OCRLine(
        text: "КУПИТЬ ОПЫТ",
        normalized: "КУПИТЬ ОПЫТ",
        compact: "КУПИТЬОПЫТ",
        confidence: 1,
        boundingBox: CGRect(x: 0.02, y: 0.03, width: 0.12, height: 0.03)
    )
    let russianPlanning = OCRLine(
        text: "ОБНОВИТЬ",
        normalized: "ОБНОВИТЬ",
        compact: "ОБНОВИТЬ",
        confidence: 1,
        boundingBox: CGRect(x: 0.8, y: 0.1, width: 0.1, height: 0.04)
    )
    let russianBattle = classify(lines: [russianStage, russianBattleHUD, russianPlanning])
    let russianBattlePhase = battlePhase(
        for: russianBattle,
        lines: [russianStage, russianBattleHUD, russianPlanning],
        combatCyanPixels: 0,
        combatCyanLongestRun: 0,
        imageWidth: referenceWidth,
        imageHeight: referenceHeight
    )
    let postCombatPhase = battlePhase(
        for: battle,
        lines: [timeBonus],
        combatCyanPixels: 0,
        combatCyanLongestRun: 0,
        imageWidth: referenceWidth,
        imageHeight: referenceHeight
    )
    let planningPhase = battlePhase(
        for: battle,
        lines: [timeBonus, planning],
        combatCyanPixels: 0,
        combatCyanLongestRun: 0,
        imageWidth: referenceWidth,
        imageHeight: referenceHeight
    )
    return shopCost(red: 37, green: 51, blue: 65) == 1
        && shopCost(red: 19, green: 53, blue: 44) == 2
        && shopCost(red: 28, green: 32, blue: 72) == 3
        && shopCost(red: 82, green: 34, blue: 96) == 4
        && shopCost(red: 105, green: 91, blue: 35) == 5
        && boardOccupancy(in: [noisyOccupancy])?.units == 3
        && boardOccupancy(in: [noisyOccupancy])?.capacity == 4
        && postCombatPhase == "post_combat"
        && planningPhase == "planning"
        && russianBattle.state == .battle
        && russianBattle.stage == "4-6"
        && russianBattlePhase == "planning"
}

private func emitDebugLines(_ lines: [OCRLine]) {
    guard ProcessInfo.processInfo.environment["TFT_SCREEN_CLASSIFIER_DEBUG"] == "1" else {
        return
    }
    for line in lines {
        writeStandardError(String(
            format: "ocr confidence=%.3f x=%.3f y=%.3f text=%@",
            line.confidence,
            line.boundingBox.minX,
            line.boundingBox.minY,
            line.text
        ))
    }
}

private final class EvidenceMatcher {
    private let lines: [OCRLine]
    private let compactCorpus: String

    init(lines: [OCRLine]) {
        self.lines = lines
        compactCorpus = lines.map(\.compact).joined()
    }

    func has(_ phrase: String) -> Bool {
        let needle = compactText(normalizedText(phrase))
        guard !needle.isEmpty else {
            return false
        }
        return lines.contains { $0.compact.contains(needle) } || compactCorpus.contains(needle)
    }

    func hasAny(_ phrases: [String]) -> Bool {
        phrases.contains(where: has)
    }

    func matchedText(for phrases: [String], limit: Int = 4) -> [String] {
        let needles = phrases.map { compactText(normalizedText($0)) }.filter { !$0.isEmpty }
        var result: [String] = []
        for line in lines where needles.contains(where: { line.compact.contains($0) }) {
            if !result.contains(line.text) {
                result.append(line.text)
            }
            if result.count == limit {
                break
            }
        }
        return result
    }
}

private let stageExpression = try! NSRegularExpression(
    pattern: "(?<![0-9])([1-9])\\s*-\\s*(1[0-9]|[1-9])(?![0-9])"
)
private let boardOccupancyExpression = try! NSRegularExpression(
    // The helmet icon is sometimes recognized as a numeric prefix (`473/4`),
    // while the dedicated crop can omit the slash (`34`). The final two digits
    // remain stable and the center-region gate excludes every other counter.
    pattern: "([0-9])\\s*/?\\s*([1-9])$"
)

private func stageMarker(in lines: [OCRLine]) -> (stage: String, evidence: String)? {
    // The round marker is small, but it is always in the top strip of a real battle.
    // Restricting the match to that strip prevents prices and card text from becoming stages.
    for line in lines where line.boundingBox.midY >= 0.88 {
        let range = NSRange(line.normalized.startIndex..., in: line.normalized)
        guard let match = stageExpression.firstMatch(in: line.normalized, range: range),
              let stageRange = Range(match.range(at: 1), in: line.normalized),
              let roundRange = Range(match.range(at: 2), in: line.normalized) else {
            continue
        }
        return ("\(line.normalized[stageRange])-\(line.normalized[roundRange])", line.text)
    }
    return nil
}

private func boardOccupancy(in lines: [OCRLine]) -> (units: Int, capacity: Int)? {
    // The board counter is centered over the arena. Restricting both axes
    // excludes XP (bottom-left), traits (top-left), and shop odds (right).
    for line in lines where line.boundingBox.midX >= 0.42
            && line.boundingBox.midX <= 0.58
            && line.boundingBox.midY >= 0.58
            && line.boundingBox.midY <= 0.74 {
        let range = NSRange(line.normalized.startIndex..., in: line.normalized)
        guard let match = boardOccupancyExpression.firstMatch(in: line.normalized, range: range),
              let unitsRange = Range(match.range(at: 1), in: line.normalized),
              let capacityRange = Range(match.range(at: 2), in: line.normalized),
              let units = Int(line.normalized[unitsRange]),
              let capacity = Int(line.normalized[capacityRange]),
              units >= 1, units <= capacity, capacity <= 5 else {
            continue
        }
        return (units, capacity)
    }
    return nil
}

private func classify(lines: [OCRLine]) -> Classification {
    let matcher = EvidenceMatcher(lines: lines)

    // Fail closed: a reject marker always wins over content visible behind a dialog.
    // Trial settings and its surrender confirmation are overlays: the stage and
    // battle HUD remain OCR-visible behind them, so they must win over battle.
    let englishPatchPrompt = matcher.has("NEW PATCH AVAILABLE")
        && matcher.has("WOULD YOU LIKE TO DOWNLOAD")
    let russianPatchPrompt = matcher.has("ДОСТУПНО ОБНОВЛЕНИЕ")
        && matcher.has("СКАЧАТЬ")
    if englishPatchPrompt || russianPatchPrompt {
        return Classification(
            state: .patchAvailable,
            stage: nil,
            reason: "patch_download_confirmation",
            evidence: matcher.matchedText(for: [
                "NEW PATCH AVAILABLE", "WOULD YOU LIKE TO DOWNLOAD",
                "ДОСТУПНО ОБНОВЛЕНИЕ", "СКАЧАТЬ",
            ])
        )
    }

    if matcher.has("START PATCHING") && matcher.has("TEAMFIGHT") {
        return Classification(
            state: .patchReady,
            stage: nil,
            reason: "patch_ready",
            evidence: matcher.matchedText(for: ["START PATCHING", "TEAMFIGHT"])
        )
    }

    if matcher.hasAny([
        "PATCHING", "INSTALLING PATCH", "APPLYING PATCH",
        "ЗАГРУЗКА", "УСТАНОВКА", "ПРИМЕНЕНИЕ ОБНОВЛЕНИЯ",
    ])
            && matcher.has("TEAMFIGHT") {
        return Classification(
            state: .patching,
            stage: nil,
            reason: "patch_in_progress",
            evidence: matcher.matchedText(for: [
                "PATCHING", "INSTALLING PATCH", "APPLYING PATCH",
                "ЗАГРУЗКА", "УСТАНОВКА", "ПРИМЕНЕНИЕ ОБНОВЛЕНИЯ", "TEAMFIGHT",
            ])
        )
    }

    if matcher.has("UNAVAILABLE COSMETIC")
            && matcher.has("REPLACED WITH DEFAULT COSMETICS") {
        return Classification(
            state: .cosmeticNotice,
            stage: nil,
            reason: "default_cosmetics_notice",
            evidence: matcher.matchedText(for: ["UNAVAILABLE COSMETIC", "REPLACED WITH DEFAULT COSMETICS"])
        )
    }

    if matcher.has("SETTINGS") && matcher.has("SURRENDER GAME")
            && matcher.has("DO YOU WANT TO SURRENDER THIS GAME") {
        return Classification(
            state: .surrenderConfirm,
            stage: nil,
            reason: "surrender_confirmation",
            evidence: matcher.matchedText(for: ["SETTINGS", "SURRENDER GAME", "DO YOU WANT TO SURRENDER THIS GAME"])
        )
    }

    if matcher.has("SETTINGS") && matcher.hasAny(["SURRENDER", "LEAVE GAME"])
            && matcher.has("RESTORE DEFAULTS") {
        return Classification(
            state: .settings,
            stage: nil,
            reason: "trial_settings_overlay",
            evidence: matcher.matchedText(for: ["SETTINGS", "SURRENDER", "LEAVE GAME", "RESTORE DEFAULTS"])
        )
    }

    if matcher.has("TOCKER'S TRIALS") && matcher.has("PLAY AGAIN") {
        return Classification(
            state: .trialResults,
            stage: nil,
            reason: "trial_results_screen",
            evidence: matcher.matchedText(for: ["TOCKER'S TRIALS", "PLAY AGAIN"])
        )
    }

    let retryableLoginServiceMarkers = [
        "LOGIN SERVICE ERROR",
        "SERVICE ERROR HAS OCCURRED DURING",
        "LOGIN PLEASE TRY RECONNECTING",
        "LOGOUT",
        "RECONNECT",
    ]
    if retryableLoginServiceMarkers.allSatisfy(matcher.has) {
        return Classification(
            state: .loginServiceError,
            stage: nil,
            reason: "retryable_login_service_error",
            evidence: matcher.matchedText(for: retryableLoginServiceMarkers)
        )
    }

    let serviceErrorMarkers = ["LOGIN SERVICE ERROR", "SERVICE ERROR"]
    if matcher.hasAny(serviceErrorMarkers) {
        return Classification(
            state: .error,
            stage: nil,
            reason: "service_error_marker",
            evidence: matcher.matchedText(for: serviceErrorMarkers)
        )
    }

    // This modal cannot reconnect to a live game: it explicitly says the old
    // Trial ended and that Start will create a new one. Keep it separate from
    // every other reconnect/connection failure so automation may only dismiss
    // this exact acknowledgement.
    let endedTrialMarkers = [
        "TOCKER'S TRIALS",
        "RECONNECT FAILURE",
        "GAME ENDED UNEXPECTEDLY",
        "PRESS START TO PLAY A NEW GAME",
    ]
    if endedTrialMarkers.allSatisfy(matcher.has) {
        return Classification(
            state: .trialEnded,
            stage: nil,
            reason: "ended_trial_acknowledgement",
            evidence: matcher.matchedText(for: endedTrialMarkers)
        )
    }

    let disconnectedMarkers = [
        "RECONNECT",
        "TRY AGAIN",
        "INTERNET CONNECTION",
        "CHECK YOUR CONNECTION",
        "CONNECTION LOST",
        "CONNECTION FAILED",
        "DISCONNECTED",
        "UNABLE TO CONNECT",
    ]
    if matcher.hasAny(disconnectedMarkers) {
        return Classification(
            state: .disconnected,
            stage: nil,
            reason: "connection_reject_marker",
            evidence: matcher.matchedText(for: disconnectedMarkers)
        )
    }

    let strongErrorMarkers = [
        "FAILED",
        "UNAVAILABLE",
        "DECLINED READY CHECK",
        "RETURNED TO THE LOBBY",
    ]
    // PBE currently renders a broken top-bar currency label as `ERROR +` in
    // an otherwise normal lobby. Exempt only that exact, bounded signature;
    // an ERROR anywhere else remains fail-closed even when lobby content is
    // visible behind it.
    let hasTopBarErrorCurrency = lines.contains(where: {
        $0.compact == "ERROR" && $0.boundingBox.minX >= 0.68 && $0.boundingBox.midY >= 0.90
    }) && lines.contains(where: {
        $0.normalized == "+" && $0.boundingBox.minX >= 0.75 && $0.boundingBox.midY >= 0.90
    })
    if matcher.hasAny(strongErrorMarkers) || (matcher.has("ERROR") && !hasTopBarErrorCurrency) {
        return Classification(
            state: .error,
            stage: nil,
            reason: "error_reject_marker",
            evidence: matcher.matchedText(for: ["ERROR"] + strongErrorMarkers)
        )
    }

    if matcher.has("SIGN IN") && matcher.has("TEAMFIGHT") && matcher.has("TACTICS") {
        return Classification(
            state: .login,
            stage: nil,
            reason: "sign_in_splash",
            evidence: matcher.matchedText(for: ["TEAMFIGHT", "TACTICS", "SIGN IN"])
        )
    }

    let loginMarkers = [
        "LOG IN", "SIGN IN", "LOGIN", "RIOT ACCOUNT",
        "ВОЙТИ", "ВХОД", "УЧЕТНАЯ ЗАПИСЬ RIOT", "УЧЁТНАЯ ЗАПИСЬ RIOT",
    ]
    if matcher.hasAny(loginMarkers) || (matcher.has("USERNAME") && matcher.has("PASSWORD")) {
        return Classification(
            state: .login,
            stage: nil,
            reason: "login_reject_marker",
            evidence: matcher.matchedText(for: loginMarkers + ["USERNAME", "PASSWORD"])
        )
    }

    let acceptedMarkers = ["MATCH ACCEPTED"]
    if matcher.hasAny(acceptedMarkers) {
        return Classification(
            state: .matchAccepted,
            stage: nil,
            reason: "match_accepted_marker",
            evidence: matcher.matchedText(for: acceptedMarkers)
        )
    }

    let foundMarkers = ["MATCH FOUND", "READY CHECK"]
    if matcher.hasAny(foundMarkers) && matcher.hasAny(["ACCEPT", "READY CHECK"]) {
        return Classification(
            state: .matchFound,
            stage: nil,
            reason: "match_found_marker",
            evidence: matcher.matchedText(for: foundMarkers + ["ACCEPT"])
        )
    }

    // Trial reward, augment, and evolution choosers cover the normal battle
    // HUD. The top stage marker plus CHOOSE ONE is a closed, battle-scoped gate:
    // generic Riot and login dialogs cannot satisfy the stage requirement.
    if let stage = stageMarker(in: lines), matcher.has("CHOOSE ONE") {
        let reason = matcher.has("EVOLVE")
            ? "trial_evolution_choice"
            : (matcher.has("DESCRIPTION") ? "trial_reward_choice" : "trial_option_choice")
        return Classification(
            state: .trialChoice,
            stage: stage.stage,
            reason: reason,
            evidence: [stage.evidence]
                + matcher.matchedText(for: ["CHOOSE ONE", "DESCRIPTION", "EVOLVE"], limit: 3)
        )
    }

    let battleHUDMarkers = [
        "SCORE", "DAMAGE DEALT", "SURVIVING DAMAGE", "BUY XP",
        "СЧЕТ", "СЧЁТ", "НАНЕСЕННЫЙ УРОН", "НАНЕСЁННЫЙ УРОН",
        "НАНЕСЕНО УРОНА", "УРОН ВЫЖИВШИХ", "КУПИТЬ ОПЫТ",
    ]
    if let stage = stageMarker(in: lines), matcher.hasAny(battleHUDMarkers) {
        return Classification(
            state: .battle,
            stage: stage.stage,
            reason: "top_stage_and_battle_hud",
            evidence: [stage.evidence] + matcher.matchedText(for: battleHUDMarkers, limit: 2)
        )
    }

    let modeMarkers = ["NORMAL", "DOUBLE UP", "RANKED", "TOCKER'S TRIALS"]
    let modeMarkerCount = modeMarkers.filter(matcher.has).count
    if (modeMarkerCount >= 2 && matcher.has("PLAY")) || modeMarkerCount >= 3 {
        return Classification(
            state: .modeSelect,
            stage: nil,
            reason: "mode_cards",
            evidence: matcher.matchedText(for: modeMarkers + ["PLAY"])
        )
    }

    if matcher.has("TOCKER'S TRIALS") && matcher.has("START") {
        return Classification(
            state: .trialsLobby,
            stage: nil,
            reason: "trials_start",
            evidence: matcher.matchedText(for: ["TOCKER'S TRIALS", "START"])
        )
    }

    let lobbyMarkers = [
        "PASS", "TREASURE REALMS", "LOADOUTS", "PATCH NOTES",
        "ПРОПУСК", "ЦАРСТВА СОКРОВИЩ", "СБОРКИ", "ОПИСАНИЕ ОБНОВЛЕНИЯ",
    ]
    let lobbyMarkerCount = lobbyMarkers.filter(matcher.has).count
    if matcher.hasAny(["PLAY", "ИГРАТЬ"]) && lobbyMarkerCount >= 2 {
        return Classification(
            state: .lobby,
            stage: nil,
            reason: "home_navigation",
            evidence: matcher.matchedText(for: lobbyMarkers + ["PLAY", "ИГРАТЬ"])
        )
    }

    return Classification(state: .unknown, stage: nil, reason: "insufficient_evidence", evidence: [])
}

private func battlePhase(
    for classification: Classification,
    lines: [OCRLine],
    combatCyanPixels: Int,
    combatCyanLongestRun: Int,
    imageWidth: Int,
    imageHeight: Int
) -> String? {
    guard classification.state == .battle || classification.state == .trialChoice else {
        return nil
    }
    if classification.state == .trialChoice {
        return "planning"
    }
    if lines.contains(where: { $0.compact == "COMBAT" || $0.compact == "БОЙ" }) {
        return "combat"
    }
    // The Combat banner is brief. The cyan progress bar remains visible for
    // the fight, while preparation and reconnect screens do not contain it.
    let horizontalScale = Double(imageWidth) / Double(referenceWidth)
    let verticalScale = Double(imageHeight) / Double(referenceHeight)
    let combatCyanRunThreshold = Int((Double(referenceCombatCyanRunThreshold) * horizontalScale).rounded())
    if combatCyanLongestRun >= combatCyanRunThreshold {
        return "combat"
    }
    // Near the end of a fight the timer is broken into shorter cyan segments,
    // while OCR can still read the disabled grey Fight button. Require both a
    // meaningful run and total cyan area before treating that late frame as
    // combat; planning fixtures have neither signal.
    let lateCombatRunThreshold = Int((40.0 * horizontalScale).rounded())
    let lateCombatPixelThreshold = Int((400.0 * horizontalScale * verticalScale).rounded())
    if combatCyanLongestRun >= lateCombatRunThreshold
            && combatCyanPixels >= lateCombatPixelThreshold {
        return "combat"
    }
    if lines.contains(where: {
        $0.compact == "PLANNING" || $0.compact == "PREPARE"
            || $0.compact == "FIGHT" || $0.compact == "REROLL"
            || $0.compact == "ПЛАНИРОВАНИЕ" || $0.compact == "ПОДГОТОВКА"
            || $0.compact == "ОБНОВИТЬ"
    }) {
        return "planning"
    }
    // Tocker's multi-orb reward gate keeps the battle HUD and stage visible,
    // but removes both the combat timer and planning controls. TIME BONUS is
    // the stable semantic marker on that completed-combat screen. Exposing a
    // separate phase lets the harness open each reward chooser without ever
    // guessing from a generic battle frame.
    if EvidenceMatcher(lines: lines).has("TIME BONUS") {
        return "post_combat"
    }
    return nil
}

private func emit(
    _ classification: Classification,
    phase: String?,
    ocrCount: Int,
    combatCyanPixels: Int,
    combatCyanLongestRun: Int,
    imageWidth: Int,
    imageHeight: Int,
    shopOpen: Bool,
    shopCosts: [Int],
    boardUnits: Int?,
    boardCapacity: Int?,
    fightButtonVisible: Bool,
    combatBannerVisible: Bool
) throws {
    let result: [String: Any] = [
        "combat_cyan_pixels": combatCyanPixels,
        "combat_cyan_longest_run": combatCyanLongestRun,
        "combat_banner_visible": combatBannerVisible,
        "board_capacity": boardCapacity ?? NSNull(),
        "board_units": boardUnits ?? NSNull(),
        "evidence": classification.evidence,
        "height": imageHeight,
        "ocr_count": ocrCount,
        "phase": phase ?? NSNull(),
        "reason": classification.reason,
        "stage": classification.stage ?? NSNull(),
        "state": classification.state.rawValue,
        "shop_open": shopOpen,
        "shop_costs": shopCosts,
        "fight_button_visible": fightButtonVisible,
        "width": imageWidth,
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    guard let output = String(data: data, encoding: .utf8) else {
        throw ClassifierError.recognitionFailed("could not encode JSON output")
    }
    print(output)
}

private func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--self-test"] {
        guard classifierSelfTest() else {
            writeStandardError("tft-screen-classifier: self-test failed")
            return 1
        }
        print("TFT screen classifier self-test: OK")
        return 0
    }
    guard arguments.count == 1, arguments[0] != "-h", arguments[0] != "--help" else {
        writeStandardError("usage: tft-screen-classifier <supported-16x9.png> | --self-test")
        if arguments.count == 1, arguments[0] == "-h" || arguments[0] == "--help" {
            return 0
        }
        return 64
    }

    do {
        let image = try loadImage(at: URL(fileURLWithPath: arguments[0]))
        let fullFrameLines = try recognizeText(in: image)
        let topStageLines = try recognizeTopStageText(in: image)
        let boardOccupancyLines = try recognizeBoardOccupancyText(in: image)
        let lines = fullFrameLines + topStageLines + boardOccupancyLines
        emitDebugLines(lines)
        let classification = classify(lines: lines)
        let combatCyanMetrics = combatCyanMetrics(in: image)
        let interfaceMatcher = EvidenceMatcher(lines: lines)
        let shopOpen = interfaceMatcher.has("REROLL")
        let occupancy = boardOccupancy(in: lines)
        try emit(
            classification,
            phase: battlePhase(
                for: classification,
                lines: lines,
                combatCyanPixels: combatCyanMetrics.pixels,
                combatCyanLongestRun: combatCyanMetrics.longestRun,
                imageWidth: image.width,
                imageHeight: image.height
            ),
            ocrCount: lines.count,
            combatCyanPixels: combatCyanMetrics.pixels,
            combatCyanLongestRun: combatCyanMetrics.longestRun,
            imageWidth: image.width,
            imageHeight: image.height,
            shopOpen: shopOpen,
            shopCosts: shopCosts(in: image, shopOpen: shopOpen),
            boardUnits: occupancy?.units,
            boardCapacity: occupancy?.capacity,
            fightButtonVisible: interfaceMatcher.has("FIGHT"),
            combatBannerVisible: interfaceMatcher.has("COMBAT")
        )
        return 0
    } catch let error as ClassifierError {
        writeStandardError("tft-screen-classifier: \(error)")
        return 65
    } catch {
        writeStandardError("tft-screen-classifier: \(error.localizedDescription)")
        return 70
    }
}

exit(main())
