// One native scope panel's BODY, transition-complete (webview retirement): renders the pinned
// panel's active tab for a week/month scope INCLUDING the in-flight carousels the Canvas header
// draws — the week→week horizontal turn (two sub-panels sliding by wP) and the month→month
// vertical page-turn (two sub-panels riding their band frames by mDy0/mDy1, fading by mP).
// Everything is computed from the SAME per-frame values the header uses, so header and body
// move in lockstep — the exact desync the webview bridge could never fully close.

import CalendarEngine
import CalendarRender
import SwiftUI

struct NativePanelHost: View {
    let engine: CalendarEngine
    let scope: String // "week" | "month"
    let tab: DashTab
    let theme: Theme
    // Week-turn state (weekDashTurn): the two Sunday keys + progress (rests at 0 AND 1).
    var wFromKey: String
    var wToKey: String
    var wP: CGFloat
    // Month-turn state: the two "YYYY-MM" keys, progress, and the band-frame dy offsets.
    var mKeyA: String
    var mKeyB: String
    var mP: CGFloat
    var mDy0: CGFloat
    var mDy1: CGFloat
    @Binding var noteMode: NotesMode
    var onOpen: (String) -> Void

    private func mid(_ v: CGFloat) -> Bool { v > 0.001 && v < 0.999 }

    var body: some View {
        if scope == "week", mid(wP), !wToKey.isEmpty {
            // Week turn: outgoing slides out left (-wP·w) fading to 1−wP; incoming enters from
            // the right ((1−wP)·w) fading to wP — the day-carousel house rule the header follows.
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    content(key: wFromKey)
                        .offset(x: -wP * w)
                        .opacity(Double(1 - wP))
                    content(key: wToKey)
                        .offset(x: (1 - wP) * w)
                        .opacity(Double(wP))
                }
            }
            .clipped()
        } else if scope == "month", mid(mP), !mKeyB.isEmpty {
            // Month page-turn: both sub-panels ride their bands' PIXEL frames (the same staggered
            // easing the Canvas header animates with) and fade by turn progress.
            ZStack(alignment: .topLeading) {
                content(key: mKeyA)
                    .offset(y: mDy0)
                    .opacity(Double(1 - mP))
                content(key: mKeyB)
                    .offset(y: mDy1)
                    .opacity(Double(mP))
            }
            .clipped()
        } else {
            content(key: scope == "week" ? (wP < 0.5 ? wFromKey : wToKey) : mKeyA)
        }
    }

    @ViewBuilder
    private func content(key: String) -> some View {
        switch tab {
        case .proj:
            NativeProjPanel(engine: engine, scope: scope, key: key, theme: theme, onOpen: onOpen)
        case .note:
            NativeNotePanel(engine: engine, scope: scope, key: key, theme: theme,
                            noteMode: $noteMode)
        case .todo:
            NativeDashPanel(engine: engine, scope: scope, key: key, theme: theme, onOpen: onOpen)
        }
    }
}
