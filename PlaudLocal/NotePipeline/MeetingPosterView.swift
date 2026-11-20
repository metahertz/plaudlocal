import SwiftUI

/// At-a-glance meeting poster — light card grid modeled on the strategic-alignment style.
struct MeetingPosterView: View {
    let brief: MeetingBrief
    let recordingDate: Date

    private let canvas = Color(red: 0.95, green: 0.95, blue: 0.96) // #F2F3F5
    private let ink = Color(red: 0.10, green: 0.12, blue: 0.15)
    private let muted = Color(red: 0.40, green: 0.44, blue: 0.50)
    private let actionsBG = Color(red: 0.91, green: 0.92, blue: 0.94)
    private let white = Color.white

    private let topicPalettes: [(fill: Color, accent: Color, icon: String)] = [
        (Color(red: 0.91, green: 0.94, blue: 0.99), Color(red: 0.22, green: 0.45, blue: 0.90), "person.3.fill"),
        (Color(red: 0.90, green: 0.96, blue: 0.94), Color(red: 0.10, green: 0.55, blue: 0.50), "laptopcomputer"),
        (Color(red: 0.99, green: 0.96, blue: 0.88), Color(red: 0.72, green: 0.52, blue: 0.10), "calendar"),
        (Color(red: 0.99, green: 0.91, blue: 0.90), Color(red: 0.78, green: 0.28, blue: 0.28), "mappin.and.ellipse"),
        (Color(red: 0.93, green: 0.91, blue: 0.98), Color(red: 0.45, green: 0.32, blue: 0.82), "lightbulb.fill"),
        (Color(red: 0.90, green: 0.95, blue: 0.99), Color(red: 0.15, green: 0.50, blue: 0.72), "chart.bar.fill"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            topicGrid
            if !brief.actionItems.isEmpty {
                actionBoard
            } else if !brief.decisions.isEmpty {
                decisionsFallback
            }
            footer
        }
        .padding(40)
        .frame(width: 1080, alignment: .topLeading)
        .background(canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(brief.kind.isEmpty ? "Meeting notes" : brief.kind)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.22, green: 0.45, blue: 0.90))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color(red: 0.86, green: 0.91, blue: 0.99))
                .clipShape(Capsule())

            Text(brief.title)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)

            if !brief.subtitle.isEmpty {
                Text(brief.subtitle)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(recordingDate.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(muted.opacity(0.8))
        }
    }

    private var topicGrid: some View {
        let topics = displayTopics
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)],
            spacing: 20
        ) {
            ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                topicCard(topic, palette: topicPalettes[index % topicPalettes.count])
            }
        }
    }

    /// Prefer model topics; if empty but decisions exist, synthesize a decisions card.
    private var displayTopics: [MeetingTopic] {
        // Long meetings can legitimately need more than a handful of topic cards.
        if !brief.topics.isEmpty { return Array(brief.topics.prefix(8)) }
        if !brief.decisions.isEmpty {
            return [
                MeetingTopic(
                    name: "Key decisions",
                    tag: "Decisions",
                    summary: "Outcomes agreed in this conversation.",
                    points: brief.decisions.prefix(4).map {
                        MeetingTopicPoint(title: "Decision", detail: $0)
                    }
                ),
            ]
        }
        return []
    }

    private func topicCard(
        _ topic: MeetingTopic,
        palette: (fill: Color, accent: Color, icon: String)
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: palette.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 28, height: 28)
                Text(topic.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !topic.tag.isEmpty {
                    Text(topic.tag)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(white.opacity(0.7))
                        .clipShape(Capsule())
                }
            }

            if !topic.summary.isEmpty {
                Text(topic.summary)
                    .font(.system(size: 15))
                    .foregroundStyle(ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let highlight = topic.highlight, !highlight.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if let label = topic.highlightLabel, !label.isEmpty {
                        Text(label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(muted)
                    }
                    Text(highlight)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(ink)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            ForEach(topic.points.prefix(4)) { point in
                VStack(alignment: .leading, spacing: 6) {
                    Text(point.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(ink)
                    Text(point.detail)
                        .font(.system(size: 14))
                        .foregroundStyle(ink.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(palette.fill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var actionBoard: some View {
        let owners = brief.actionOwners
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundStyle(ink)
                Text("Action Items & Next Steps")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(ink)
            }

            LazyVGrid(
                columns: owners.count == 1
                    ? [GridItem(.flexible())]
                    : [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                spacing: 16
            ) {
                ForEach(Array(owners.enumerated()), id: \.offset) { _, group in
                    ownerColumn(name: group.owner, role: group.role, tasks: group.tasks)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(actionsBG)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func ownerColumn(name: String?, role: String?, tasks: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let name, !name.isEmpty {
                HStack(spacing: 10) {
                    Text(initials(name))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(avatarColor(name))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(ink)
                        if let role, !role.isEmpty {
                            Text(role)
                                .font(.system(size: 12))
                                .foregroundStyle(muted)
                        }
                    }
                }
            }

            ForEach(tasks, id: \.self) { task in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .stroke(muted.opacity(0.55), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                        .padding(.top, 2)
                    Text(task)
                        .font(.system(size: 14))
                        .foregroundStyle(ink.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var decisionsFallback: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Decisions")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(ink)
            ForEach(brief.decisions, id: \.self) { decision in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(muted)
                    Text(decision).foregroundStyle(ink)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(actionsBG)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Text("Plaud Local")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(muted.opacity(0.55))
            Spacer()
        }
        .padding(.top, 4)
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }

    private func avatarColor(_ name: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.22, green: 0.45, blue: 0.90),
            Color(red: 0.10, green: 0.55, blue: 0.50),
            Color(red: 0.78, green: 0.28, blue: 0.28),
            Color(red: 0.45, green: 0.32, blue: 0.82),
            Color(red: 0.72, green: 0.52, blue: 0.10),
        ]
        let idx = abs(name.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) }) % colors.count
        return colors[idx]
    }
}

@MainActor
enum PosterRenderer {
    enum RenderError: Error {
        case failed
    }

    static func pngData(brief: MeetingBrief, recordingDate: Date) throws -> Data {
        let view = MeetingPosterView(brief: brief, recordingDate: recordingDate)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else {
            throw RenderError.failed
        }
        return data
    }
}
