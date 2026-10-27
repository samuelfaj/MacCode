import XCTest
@testable import CoreModel

final class BotBlobatarTests: XCTestCase {
    func test_attentionKeepsTheSameIdentity() {
        let name = "Developer"
        let handle = "elephant-developer"
        let baseline = BotBlobatar.figure(name: name, spec: .default, handle: handle)
        for attention: BotAttentionState in [.none, .working, .unreadActivity, .needsAttention] {
            let live = BotBlobatarSpec.default.liveFaced(attention: attention, name: name, handle: handle)
            let figure = BotBlobatar.figure(name: name, spec: live, handle: handle)
            XCTAssertEqual(figure.resolvedShape, baseline.resolvedShape)
            XCTAssertEqual(figure.body, baseline.body, "activity must not regenerate the Bot")
            XCTAssertEqual(figure.petals, baseline.petals)
            XCTAssertEqual(figure.radii, baseline.radii)
            XCTAssertEqual(figure.palette, baseline.palette, "activity must not recolor the Bot")
            XCTAssertEqual(live.expression, .live(for: attention))
        }
    }

    func test_pickedColorsMatchTheirSwatchesAcrossNamesAndAttention() {
        for swatch in BotBlobatar.studioHues {
            let spec = BotBlobatarSpec(hue: .named(swatch.id))
            let idle = BotBlobatar.figure(name: "Piper", spec: spec)
            let needsYou = BotBlobatar.figure(
                name: "Developer", spec: spec.liveFaced(attention: .needsAttention, name: "Developer", handle: "elephant-developer"),
                handle: "elephant-developer"
            )
            XCTAssertEqual(idle.palette.head, swatch.preview, swatch.id)
            XCTAssertEqual(needsYou.palette.head, swatch.preview, swatch.id)
        }
    }

    func test_workspaceTintOverridesHue_becauseWorkspaceExclusiveBotsWearTheWorkspaceColor() {
        let spec = BotBlobatarSpec(hue: .named("coral"))
        let plain = BotBlobatar.figure(name: "Piper", spec: spec)
        let tinted = BotBlobatar.figure(name: "Piper", spec: spec, tintHex: 0x8EE6A8)
        XCTAssertEqual(tinted.palette.head, 0x8EE6A8)
        XCTAssertNotEqual(plain.palette.head, 0x8EE6A8)
        XCTAssertEqual(plain, BotBlobatar.figure(name: "Piper", spec: spec, tintHex: nil), "no workspace color keeps the look")
        XCTAssertEqual(tinted.body, plain.body, "tint recolors only, never reshapes")
    }

    func test_previewSaveAndRenameKeepTheSelectedCreature() throws {
        let original = BotBlobatarSpec.default
        let selected = original.selecting(shape: .cloud, hue: .auto, name: "Developer", handle: "elephant-developer")
        let reloaded = try XCTUnwrap(BotBlobatarSpec.parse(selected.token))
        XCTAssertEqual(
            BotBlobatar.figure(name: "Developer", spec: selected, handle: "elephant-developer"),
            BotBlobatar.figure(name: "Renamed Developer", spec: reloaded, handle: "new-handle")
        )
        let recolored = reloaded.selecting(shape: .cloud, hue: .named("cyan"), name: "Renamed Developer")
        XCTAssertEqual(recolored.frozenSeed, reloaded.frozenSeed)
        XCTAssertEqual(recolored.selecting(shape: .auto, hue: .auto, name: "Renamed Developer"), .default)
        XCTAssertEqual(BotBlobatarSpec.parse("blobatar:cloud:cyan"), BotBlobatarSpec(shape: .cloud, hue: .named("cyan")))
    }

    func test_sameNameAndSpecIsDeterministic_becauseAnAvatarMustStayTheSameCreature() {
        // WHY: A roster of the same bot must not flicker. blobatar's
        // contract is same name + spec => same figure.
        let spec = BotBlobatarSpec(shape: .cloud, expression: .idle, background: .none, hue: .named("coral"))
        let a = BotBlobatar.figure(name: "Piper", spec: spec)
        let b = BotBlobatar.figure(name: "Piper", spec: spec)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.resolvedShape, .cloud)
        XCTAssertEqual(
            BotBlobatar.figure(name: "Scout", spec: spec, handle: "piper"),
            a,
            "a fixed leftover token must not remake the creature when the name changes"
        )
        let unlocked = BotBlobatar.figure(name: "Scout", spec: .default)
        XCTAssertNotEqual(a.body.cx, unlocked.body.cx)
    }

    func test_tokenRoundTripsStudioChoices_becauseSaveMustKeepWhatThePickerWrote() {
        // WHY: Studio writes one avatarSymbol string. Reload must restore
        // shape, expression, background, and hue.
        let spec = BotBlobatarSpec(shape: .sun, expression: .mad, background: .squircle, hue: .named("indigo"))
        XCTAssertEqual(BotBlobatarSpec.parse(spec.token), spec)
        XCTAssertEqual(BotBlobatarSpec.parse("SUN")?.shape, .sun)
        XCTAssertNil(BotBlobatarSpec.parse("blobatar:v1:orb:idle:none:auto"))
    }

    func test_autoShapeUsesTheName_becauseAutoIsTheHashedCreature() {
        // WHY: Auto is not a seventh silhouette. Two names must be able
        // to resolve to different shapes.
        let spec = BotBlobatarSpec.default
        let shapes = (0..<40).map { BotBlobatar.figure(name: "seed-\($0)", spec: spec).resolvedShape }
        XCTAssertGreaterThan(Set(shapes).count, 1)
        let piper = BotBlobatar.figure(name: "Piper", spec: .default)
        let scout = BotBlobatar.figure(name: "Scout", spec: .default)
        XCTAssertNotEqual(piper, scout, "an undefined avatar must follow the live name")
    }

    func test_fixedSeedIgnoresNameChange_becauseAPickedAvatarMustStayPut() {
        // WHY: Once the owner clicks Cloud, renaming the bot must not
        // invent a new creature. Only another picker click may change it.
        let locked = BotBlobatarSpec(
            shape: .cloud,
            expression: .idle,
            background: .none,
            hue: .named("coral"),
            frozenSeed: "piper"
        )
        XCTAssertEqual(
            BotBlobatar.figure(name: "Piper", spec: locked),
            BotBlobatar.figure(name: "Scout", spec: locked)
        )
        XCTAssertEqual(BotBlobatarSpec.parse(locked.token), locked)
        var reset = locked
        reset.shape = .auto
        reset.expression = .idle
        reset.background = .none
        reset.hue = .auto
        XCTAssertTrue(reset.isDefaultAppearance)
    }

    func test_motionSampleIsDeterministic_becauseAReplayMustMatchTheLiveFace() {
        // WHY: TimelineView re-samples time. The same instant has to
        // draw the same breathe/blink or the face flickers.
        let a = BotBlobatarMotion.sample(name: "Piper", time: 12.4, expression: .idle, amplitude: 1)
        let b = BotBlobatarMotion.sample(name: "Piper", time: 12.4, expression: .idle, amplitude: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, BotBlobatarMotion.still)
    }

    func test_motionPhaseDiffersByName_becauseARosterMustNotBreatheInUnison() {
        // WHY: Seeded phase is what makes a grid a crowd instead of a
        // drill team. Two names at the same clock must not match.
        let a = BotBlobatarMotion.sample(name: "Piper", time: 8, expression: .idle, amplitude: 1)
        let b = BotBlobatarMotion.sample(name: "Scout", time: 8, expression: .idle, amplitude: 1)
        XCTAssertNotEqual(a.bobY, b.bobY)
    }

    func test_liveExpressionFollowsAttention() {
        // WHY: Studio no longer picks a face. Working, waiting, and
        // blocked must read as different expressions so the creature
        // reacts to what is happening.
        XCTAssertEqual(BotBlobatarExpression.live(for: .none), .idle)
        XCTAssertEqual(BotBlobatarExpression.live(for: .working), .happy)
        XCTAssertEqual(BotBlobatarExpression.live(for: .unreadActivity), .sad)
        XCTAssertEqual(BotBlobatarExpression.live(for: .needsAttention), .mad)
    }

    func test_zeroAmplitudeIsStill_becauseReducedMotionAndFrozenTilesMustNotWiggle() {
        // WHY: Picker tiles and prefers-reduced-motion gate on amplitude 0.
        // A leftover sine would animate the editor grid.
        XCTAssertEqual(
            BotBlobatarMotion.sample(name: "Piper", time: 3, expression: .mad, amplitude: 0),
            .still
        )
    }

    func test_existingAvatarsKeepTheirLook_becauseTheRebuildMustNotRedrawAnyonesBot() {
        // WHY: users already know their Bots by face. Values captured from 9be26ace7 before the rebuild.
        let expected: [(String, BotBlobatarShape, BotBlobatarResolvedShape, Int, Double, UInt32)] = [
        ("Piper", .auto, .organic, 0, 35.818, 0x3E3345),
        ("Piper", .round, .round, 0, 36.549, 0x3E3345),
        ("Piper", .organic, .organic, 0, 35.818, 0x3E3345),
        ("Piper", .boxy, .boxy, 0, 31.432, 0x3E3345),
        ("Piper", .nub, .nub, 2, 32.163, 0x3E3345),
        ("Piper", .cloud, .cloud, 6, 28.508, 0x3E3345),
        ("Piper", .sun, .sun, 6, 25.584, 0x3E3345),
        ("Scout", .auto, .boxy, 0, 27.606, 0xCBDDCE),
        ("Scout", .round, .round, 0, 32.100, 0xCBDDCE),
        ("Scout", .organic, .organic, 0, 31.458, 0xCBDDCE),
        ("Scout", .boxy, .boxy, 0, 27.606, 0xCBDDCE),
        ("Scout", .nub, .nub, 1, 28.248, 0xCBDDCE),
        ("Scout", .cloud, .cloud, 4, 25.038, 0xCBDDCE),
        ("Scout", .sun, .sun, 7, 22.470, 0xCBDDCE),
        ("Titio", .auto, .organic, 0, 36.438, 0xBF5AAF),
        ("Titio", .round, .round, 0, 37.182, 0xBF5AAF),
        ("Titio", .organic, .organic, 0, 36.438, 0xBF5AAF),
        ("Titio", .boxy, .boxy, 0, 31.977, 0xBF5AAF),
        ("Titio", .nub, .nub, 2, 32.720, 0xBF5AAF),
        ("Titio", .cloud, .cloud, 6, 29.002, 0xBF5AAF),
        ("Titio", .sun, .sun, 6, 26.027, 0xBF5AAF),
        ]
        for (name, shape, resolved, petals, rx, head) in expected {
            let f = BotBlobatar.figure(name: name, spec: BotBlobatarSpec(shape: shape))
            XCTAssertEqual(f.resolvedShape, resolved, "\(name) \(shape)")
            XCTAssertEqual(f.petals.count, petals, "\(name) \(shape)")
            XCTAssertEqual(f.body.rx, rx, accuracy: 0.0006, "\(name) \(shape)")
            XCTAssertEqual(f.palette.head, head, "\(name) \(shape)")
        }
    }

    func test_newShapesAreDistinctAndRoundTrip_becausePickingOneMustStick() {
        for shape in [BotBlobatarShape.spark, .ghost, .bean, .drop] {
            let spec = BotBlobatarSpec(shape: shape, hue: .named("lime"))
            let f = BotBlobatar.figure(name: "Piper", spec: spec)
            XCTAssertEqual(f.resolvedShape.rawValue, shape.rawValue, "a picked \(shape) must draw that silhouette")
            XCTAssertEqual(BotBlobatarSpec.parse(spec.token), spec, "Studio must reload the picked \(shape)")
            XCTAssertEqual(f.eyes.count, 2, "every new shape still has a face")
        }
        XCTAssertGreaterThanOrEqual(BotBlobatar.figure(name: "Piper", spec: BotBlobatarSpec(shape: .spark)).petals.count, 5)
        XCTAssertEqual(BotBlobatar.figure(name: "Piper", spec: BotBlobatarSpec(shape: .drop)).petals.count, 1)
        XCTAssertEqual(BotBlobatar.figure(name: "Piper", spec: BotBlobatarSpec(shape: .bean)).petals.count, 0)
    }

    func test_autoNeverPicksANewShape_becauseHashedAvatarsMustNotChange() {
        let extra: Set<BotBlobatarResolvedShape> = [.spark, .ghost, .bean, .drop]
        for i in 0..<200 {
            XCTAssertFalse(extra.contains(BotBlobatar.figure(name: "seed-\(i)", spec: .default).resolvedShape))
        }
    }

    func test_starStaysTheLegacySymbolName_becauseBotsAlreadyAskForStarAsAnSFSymbol() {
        XCTAssertNil(BotBlobatarSpec.parse("star"), "a new shape must not steal the legacy Star avatar name")
        XCTAssertEqual(BotBlobatarSpec.parse("spark")?.shape, .spark)
    }

    func test_newHuesParse_becauseTheStudioOffersMoreColors() {
        XCTAssertEqual(BotBlobatarSpec.parse("lime")?.hue, .named("lime"))
        XCTAssertEqual(BotBlobatarHue.named("lime").degrees, 90)
        XCTAssertGreaterThanOrEqual(BotBlobatar.studioHues.count, 15)
        XCTAssertEqual(Array(BotBlobatar.studioHues.prefix(8).map(\.id)),
                       ["pink", "coral", "amber", "green", "teal", "sky", "indigo", "violet"],
                       "existing hues keep their order so old tokens and pickers stay put")
    }

    func test_workingMotionHopsHarderThanIdle_becauseAnActiveBotMustVisiblyMove() {
        let frames = stride(from: 0.0, through: 2.0, by: 1.0 / 30.0)
        let idle = frames.map { abs(BotBlobatarMotion.sample(name: "Piper", time: $0, expression: .happy, amplitude: 1).bobY) }.max() ?? 0
        let working = frames.map { abs(BotBlobatarMotion.sampleWorking(name: "Piper", time: $0).bobY) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(working, idle * 2, "working must bounce at least twice as high as the idle breath")
        let hop = stride(from: 0.0, through: 1.2, by: 1.0 / 30.0).contains { BotBlobatarMotion.sampleWorking(name: "Piper", time: $0).bobY < -2.5 }
        XCTAssertTrue(hop, "a working avatar must hop within every 1.2 s cycle")
    }
}
