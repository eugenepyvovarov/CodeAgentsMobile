//
//  OpenCodeMidAnswerSendPolicy.swift
//  CodeAgentsMobile
//
//  Purpose: Decide soft-steer (prompt_async only) vs full stream attach for OpenCode sends.
//

import Foundation

/// Policy for user prompts submitted while an OpenCode answer may still be in flight.
///
/// OpenCode does not expose a first-class "steer" API mode. Sending `prompt_async` while a
/// session is busy stores a new user message; the active agent loop picks it up at the next
/// step boundary. Clients must not attach a second `/event` stream for that follow-up.
enum OpenCodeMidAnswerSendPolicy {
    enum Mode: Equatable {
        /// Attach `/event` and call `prompt_async` (first send / no live consumer).
        case startStream
        /// Call `prompt_async` only; reuse the existing `/event` consumer.
        case softSteerPromptOnly
    }

    static func mode(isEventStreamActive: Bool) -> Mode {
        isEventStreamActive ? .softSteerPromptOnly : .startStream
    }
}
