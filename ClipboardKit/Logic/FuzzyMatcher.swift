//
//  FuzzyMatcher.swift
//  ClipboardKit
//
//  Created by Oliver Ames on 10/20/26.
//

import Foundation

/// The result of a successful fuzzy match.
public struct FuzzyMatch
{
    /// Higher scores are better matches. Only comparable between matches for the same query.
    public let score: Int

    /// The matched characters of the candidate, merged into contiguous runs.
    /// These use the candidate's own indices, so they can be used to highlight it directly.
    public let ranges: [Range<String.Index>]

    public init(score: Int, ranges: [Range<String.Index>])
    {
        self.score = score
        self.ranges = ranges
    }
}

/// Matches a short query against a longer candidate, requiring the query's characters to appear in order.
public enum FuzzyMatcher
{
    private static let matchPoints = 10
    private static let consecutiveBonus = 20
    private static let wordStartBonus = 15
    private static let gapPenalty = 3
    private static let earlyStartBonus = 8

    /// Returns a match if every non-whitespace character of `query` appears in order in `candidate`, ignoring case and diacritics.
    /// An empty query matches everything with a score of 0. Matching is greedy left to right.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch?
    {
        let needle = query.filter { !$0.isWhitespace }.map { fold($0) }
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, ranges: []) }

        var ranges = [Range<String.Index>]()
        var score = 0
        var needleIndex = 0
        var position = 0
        var lastMatchPosition: Int?
        var previous: Character?

        for index in candidate.indices
        {
            guard needleIndex < needle.count else { break }

            let character = candidate[index]
            defer {
                previous = character
                position += 1
            }

            guard fold(character) == needle[needleIndex] else { continue }
            needleIndex += 1

            score += matchPoints

            if let lastMatchPosition
            {
                score += lastMatchPosition == position - 1 ? consecutiveBonus : -gapPenalty
            }
            else
            {
                score += max(0, earlyStartBonus - position)
            }

            if startsWord(character, after: previous)
            {
                score += wordStartBonus
            }

            lastMatchPosition = position

            let range = index ..< candidate.index(after: index)
            if let last = ranges.last, last.upperBound == range.lowerBound
            {
                ranges[ranges.count - 1] = last.lowerBound ..< range.upperBound
            }
            else
            {
                ranges.append(range)
            }
        }

        guard needleIndex == needle.count else { return nil }
        return FuzzyMatch(score: score, ranges: ranges)
    }
}

private extension FuzzyMatcher
{
    static func fold(_ character: Character) -> String
    {
        return String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// True at the start of the candidate, after a space or punctuation, or at a lowercase-to-uppercase transition.
    static func startsWord(_ character: Character, after previous: Character?) -> Bool
    {
        guard let previous else { return true }
        if !previous.isLetter && !previous.isNumber { return true }
        return previous.isLowercase && character.isUppercase
    }
}
