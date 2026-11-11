import Foundation

/// Decides who answers next in a group conversation. Pure: the orchestrator
/// owns ordinals, room rows and persistence.
///
/// Hops: the user's round is hop 0. Each @mention hand-off inside a round
/// takes the next hop number (1, 2, …), so `maxAutoHops` bounds the total
/// number of hand-off turns per round and (round, bot, hop) stays unique.
public enum BotGroupTurnPlanner {
    public struct PlannedTurn: Equatable, Sendable {
        public let botID: BotID
        public let hop: Int

        public init(botID: BotID, hop: Int) {
            self.botID = botID
            self.hop = hop
        }
    }

    public enum Rejection: Equatable, Sendable {
        /// Every participant left the group.
        case noParticipants
        /// `mentions_only` and the message mentions no participant.
        case mentionRequired

        public var message: String {
            switch self {
            case .noParticipants:
                return L("This group has no bots. Add a participant to continue.")
            case .mentionRequired:
                return L("This group answers only when you @mention a participant.")
            }
        }
    }

    public enum UserRoundPlan: Equatable, Sendable {
        case turns([PlannedTurn])
        case rejected(Rejection)
    }

    public struct HandOffPlan: Equatable, Sendable {
        /// Appended after the round's pending turns, in mention order.
        public var turns: [PlannedTurn]
        /// Mentioned participants left out because the hop budget ran out.
        /// Non-empty means the room shows `pausedNote`.
        public var pausedBotIDs: [BotID]

        public init(turns: [PlannedTurn] = [], pausedBotIDs: [BotID] = []) {
            self.turns = turns
            self.pausedBotIDs = pausedBotIDs
        }

        public static let none = HandOffPlan()
    }

    /// Turns for a new user message. `participants` are the active
    /// participants in group order. Mentioned participants answer in text
    /// order (deduplicated, non-participants ignored); with no participant
    /// mentioned, the policy decides.
    public static func planUserRound(
        text: String,
        participants: [BotDefinition],
        policy: BotGroupPolicy,
        leadBotID: BotID?
    ) -> UserRoundPlan {
        guard !participants.isEmpty else { return .rejected(.noParticipants) }
        let mentioned = BotMentionParser.mentionedBots(in: text, bots: participants, excluding: nil)
        if !mentioned.isEmpty {
            return .turns(mentioned.map { PlannedTurn(botID: $0.id, hop: 0) })
        }
        switch policy {
        case .roundtable:
            return .turns(participants.map { PlannedTurn(botID: $0.id, hop: 0) })
        case .lead:
            // A lead that is no longer a participant falls back to roundtable,
            // matching what BotStore does when the lead bot is deleted.
            if let leadBotID, participants.contains(where: { $0.id == leadBotID }) {
                return .turns([PlannedTurn(botID: leadBotID, hop: 0)])
            }
            return .turns(participants.map { PlannedTurn(botID: $0.id, hop: 0) })
        case .mentionsOnly:
            return .rejected(.mentionRequired)
        }
    }

    /// Hand-offs requested by a finished reply. `author` is the turn that
    /// produced `replyText`; `groupTurns` are the group's turns (any rounds).
    /// A superseded round (the user wrote again) hands off nothing. The
    /// author and participants that still have an unstarted turn in this
    /// round are skipped: they will see the mention in their room delta.
    public static func planHandOff(
        replyText: String,
        author: BotGroupTurn,
        groupTurns: [BotGroupTurn],
        latestRoundID: BotGroupRoundID,
        participants: [BotDefinition],
        maxAutoHops: Int
    ) -> HandOffPlan {
        guard author.roundID == latestRoundID else { return .none }
        let roundTurns = groupTurns.filter { $0.roundID == author.roundID }
        let alreadyQueued = Set(
            roundTurns.filter { !$0.state.isTerminal && $0.id != author.id }.map(\.botID)
        )
        let mentioned = BotMentionParser.mentionedBots(
            in: handOffMentionText(replyText),
            bots: participants,
            excluding: author.botID
        ).filter { !alreadyQueued.contains($0.id) }
        guard !mentioned.isEmpty else { return .none }

        let budget = min(max(maxAutoHops, 0), BotGroupConversation.maxAutoHopsCap)
        var nextHop = roundTurns.map(\.hop).reduce(author.hop, max) + 1
        var plan = HandOffPlan()
        for bot in mentioned {
            if nextHop <= budget {
                plan.turns.append(PlannedTurn(botID: bot.id, hop: nextHop))
                nextHop += 1
            } else {
                plan.pausedBotIDs.append(bot.id)
            }
        }
        return plan
    }

    /// What a new user message does to the group's existing turns: unstarted
    /// turns of every round except `newRoundID` are cancelled; a running turn
    /// finishes first and the new round waits for it. Turns of `newRoundID`
    /// are left alone whether or not they were inserted yet.
    public struct Supersession: Equatable, Sendable {
        public var cancelledTurnIDs: [BotGroupTurnID]
        public var runningTurnID: BotGroupTurnID?

        public init(cancelledTurnIDs: [BotGroupTurnID], runningTurnID: BotGroupTurnID?) {
            self.cancelledTurnIDs = cancelledTurnIDs
            self.runningTurnID = runningTurnID
        }
    }

    public static func supersede(_ groupTurns: [BotGroupTurn], newRoundID: BotGroupRoundID) -> Supersession {
        let earlier = groupTurns.filter { $0.roundID != newRoundID }
        return Supersession(
            cancelledTurnIDs: earlier
                .filter { BotGroupTurn.State.pending.contains($0.state) }
                .map(\.id),
            runningTurnID: earlier.first { $0.state == .running }?.id
        )
    }

    private static let codeSpanRegex = try! NSRegularExpression(
        pattern: #"(```|~~~)[\s\S]*?(?:\1|\z)|``[^\n]*?``|`[^`\n]*`"#
    )

    /// A reply's text with the parts that are not a hand-off blanked out:
    /// fenced and inline code, and `@` glued to a word (`bob@beta`). The
    /// author's prose mentions are kept as written.
    static func handOffMentionText(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutCode = codeSpanRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        var result = ""
        var previous: Character?
        for character in withoutCode {
            if character == "@", let previous, previous.isLetter || previous.isNumber || previous == "_" {
                result.append(" ")
            } else {
                result.append(character)
            }
            previous = character
        }
        return result
    }

    /// Honest room note when mentions were not handed off.
    public static func pausedNote(pausedBots: [BotDefinition], maxAutoHops: Int) -> String {
        let handles = pausedBots.map { BotPeerTranscript.handleLabel($0.handle) }
            .joined(separator: ", ")
        let limit = min(max(maxAutoHops, 0), BotGroupConversation.maxAutoHopsCap)
        let reason: String
        switch limit {
        case 0: reason = L("Automatic hand-offs are off in this group.")
        case 1: reason = L("Paused after 1 automatic hand-off in this round.")
        default: reason = L("Paused after %1$@ automatic hand-offs in this round.", limit)
        }
        return L("%1$@ %2$@ did not answer. Mention them in a new message to continue.", reason, handles)
    }
}
