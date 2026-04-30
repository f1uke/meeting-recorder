import SwiftUI

/// Calendar attachment card shown in the popover idle state. Surfaces the
/// best-matched current/upcoming event so the user can start recording
/// with the meeting title + attendees pre-filled.
///
/// `selectedEvent` is owned by the parent (`PopoverIdleView`) so that the
/// recording start handler can read which event to pass through to
/// `RecordingSession.start(window:event:)`.
struct CalendarNowCard: View {
    let events: [CalendarEvent]
    @Binding var selectedEvent: CalendarEvent?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if events.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionLabel(text: badgeText)
                    Spacer()
                    if events.count > 1 {
                        Menu {
                            ForEach(events) { event in
                                Button(action: { selectedEvent = event }) {
                                    Label(event.title, systemImage: selectedEvent?.id == event.id ? "checkmark" : "")
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text("Switch")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.brandAccent)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    if selectedEvent != nil {
                        Button(action: { selectedEvent = nil }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.textFaint)
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Don't attach this event to the recording")
                    }
                }

                eventBody
            }
        }
    }

    private var badgeText: String {
        guard let event = selectedEvent else { return "Calendar" }
        return event.isHappeningNow ? "Happening now" : "Up next"
    }

    @ViewBuilder
    private var eventBody: some View {
        if let event = selectedEvent {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.brandAccent)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                        Text(subtitleText(for: event))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textDim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.brandAccent.opacity(scheme == .dark ? 0.10 : 0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.brandAccent.opacity(0.30), lineWidth: 0.5)
                    }
            }
        } else {
            Button {
                selectedEvent = events.first
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 11))
                    Text("Attach calendar event")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Color.brandAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.brandAccent.opacity(0.30),
                                              style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    private func subtitleText(for event: CalendarEvent) -> String {
        var parts: [String] = []
        if event.isHappeningNow {
            let endsIn = Int(event.endDate.timeIntervalSinceNow / 60)
            if endsIn > 0 { parts.append("ends in \(endsIn)m") }
        } else {
            let startsIn = Int(event.startDate.timeIntervalSinceNow / 60)
            if startsIn <= 0 {
                parts.append("starting now")
            } else if startsIn < 60 {
                parts.append("starts in \(startsIn)m")
            } else {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                parts.append("at \(f.string(from: event.startDate))")
            }
        }
        let count = event.totalAttendeeCount
        if count > 0 {
            parts.append(count == 1 ? "1 attendee" : "\(count) attendees")
        }
        if let cal = event.calendarName, !cal.isEmpty {
            parts.append(cal)
        }
        return parts.joined(separator: " · ")
    }
}
