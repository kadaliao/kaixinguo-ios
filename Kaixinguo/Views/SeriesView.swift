import KaixinguoKit
import Openhongguo
import SwiftUI

/// SeriesView is a series: its poster over its own colors, what it is
/// about, a way to play it, and its seasons and episodes.
struct SeriesView: View {
    let id: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let sp = model.seriesPage(id)
        Group {
            if let series = sp.series {
                SeriesBody(sp: sp, series: series)
            } else if let error = sp.error {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(friendly(error))
                } actions: {
                    Button("重试") { model.loadSeries(sp) }
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SeriesBody: View {
    let sp: SeriesPage
    let series: Series
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var hsize
    @State private var expanded = false
    @State private var titleInBar = false

    var body: some View {
        let wide = hsize == .regular
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(wide: wide)
                if !wide {
                    VStack(alignment: .leading, spacing: 14) {
                        about
                        actions
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                episodes(wide: wide)
            }
        }
        .scrollIndicators(.hidden)
        .modifier(HeroUnderBar())
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentOffset.y + g.contentInsets.top > (wide ? 260 : 170)
        } action: { _, past in
            titleInBar = past
        }
        .navigationTitle(titleInBar ? series.title : "")
    }

    /// The poster over its own colors, blurred wide.
    private func hero(wide: Bool) -> some View {
        HStack(alignment: .bottom, spacing: wide ? 32 : 16) {
            Poster(url: series.coverUrl, radius: 12)
                .frame(width: wide ? 200 : 118)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 12)
            VStack(alignment: .leading, spacing: wide ? 10 : 6) {
                Text(series.title)
                    .font(wide ? .largeTitle.bold() : .title2.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(metaLine(series))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if wide {
                    about.frame(maxWidth: 640, alignment: .leading)
                    actions.padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, wide ? 44 : 16)
        .padding(.top, wide ? 24 : 12)
        .padding(.bottom, wide ? 30 : 18)
        .background {
            ZStack {
                GeometryReader { g in
                    CoverImage(url: series.coverUrl)
                        .frame(width: g.size.width + 160, height: g.size.height + 160)
                        .offset(x: -80, y: -80)
                        .blur(radius: 50)
                        .opacity(0.75)
                }
                LinearGradient(stops: [.init(color: Color(uiColor: .systemBackground).opacity(0.1), location: 0.1),
                                       .init(color: Color(uiColor: .systemBackground), location: 0.97)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            // Up under the bar too: in a scroll view the safe area is an
            // inset of the content, which ignoresSafeArea can't reach.
            .padding(.top, -320)
        }
    }

    @ViewBuilder private var about: some View {
        if !series.description.isEmpty {
            Text(series.description)
                .font(.subheadline)
                .lineSpacing(4)
                .foregroundStyle(.primary.opacity(0.86))
                .lineLimit(expanded ? nil : 3)
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(expanded ? "收起简介" : "展开简介")
        }
    }

    private var actions: some View {
        let saved = model.favorites.has(sp.id)
        let wide = hsize == .regular
        return HStack(spacing: 10) {
            if !sp.episodes.isEmpty && !sp.isBook {
                let r = model.resumePoint(sp)
                Button {
                    model.player.play(r.seriesID, r.number, start: r.start)
                } label: {
                    Label(r.label, systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: wide ? nil : .infinity)
                        .padding(.vertical, 4)
                        .padding(.horizontal, wide ? 8 : 0)
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                withAnimation(.snappy) { _ = model.favorites.toggle(Fav(Card(series))) }
            } label: {
                Label(saved ? "已收藏" : "收藏", systemImage: saved ? "star.fill" : "star")
                    .font(.body.weight(.semibold))
                    .padding(.vertical, 4)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .accessibilityLabel(favLabel(saved) + "这部剧")
        }
        .controlSize(.large)
    }

    private func episodes(wide: Bool) -> some View {
        let w = model.history.get(sp.id)
        return VStack(alignment: .leading, spacing: 14) {
            SeasonChips(sp: sp) { se in router.replaceTop(.series(se.seriesId)) }
                .padding(.horizontal, wide ? -16 : -16)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("选集").font(.title3.bold())
                Text("共 \(sp.episodes.count) 集").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                PartPicker(sp: sp)
            }
            if sp.isBook {
                Text("这是小说或有声书，不能播放").font(.footnote).foregroundStyle(.secondary)
            } else if sp.episodes.isEmpty {
                Text("暂时没有可看的剧集").font(.footnote).foregroundStyle(.secondary)
            } else {
                EpisodeGrid(sp: sp, current: w?.episode ?? 0, watched: Set(w?.watched ?? []),
                            minWidth: wide ? 56 : 50) { e in
                    model.player.play(sp.id, e.number)
                }
            }
        }
        .padding(.horizontal, wide ? 44 : 16)
        .padding(.top, 10)
        .padding(.bottom, 40)
    }
}

/// SeasonChips shows the seasons of a series in several, this one chosen;
/// seasons still to come show, but can't be chosen yet.
struct SeasonChips: View {
    let sp: SeriesPage
    let choose: (Season) -> Void

    var body: some View {
        if let seasons = sp.seasons, seasons.count > 1 {
            ChipRow(selected: sp.id) {
                ForEach(seasons, id: \.seriesId) { se in
                    Chip(label: seasonLabel(se), on: se.seriesId == sp.id, enabled: se.episodeCount > 0) { choose(se) }
                        .id(se.seriesId)
                        .accessibilityHint(se.episodeCount == 0 ? "即将上线" : "")
                }
            }
        }
    }
}

/// PartPicker chooses which hundred episodes show, for long series.
struct PartPicker: View {
    @Bindable var sp: SeriesPage
    @Environment(\.horizontalSizeClass) private var hsize

    var body: some View {
        let parts = sp.parts
        if parts.count > 1 {
            let picker = Picker("集数", selection: $sp.part) {
                ForEach(parts.indices, id: \.self) { Text(parts[$0]).tag($0) }
            }
            if parts.count <= (hsize == .regular ? 6 : 3) {
                picker.pickerStyle(.segmented).fixedSize()
            } else {
                picker.pickerStyle(.menu)
            }
        }
    }
}

/// EpisodeGrid is the episodes of the part showing, to tap.
struct EpisodeGrid: View {
    let sp: SeriesPage
    let current: Int
    var watched: Set<Int> = []
    var minWidth: CGFloat = 50
    let play: (Episode) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 8)], spacing: 8) {
            ForEach(sp.partEpisodes, id: \.id) { e in
                EpisodeChip(episode: e, current: e.number == current, watched: watched.contains(e.number)) {
                    play(e)
                }
                .id(e.number)
            }
        }
    }
}

/// EpisodeChip is an episode's number to tap, filled while it is the one
/// the viewer is on, faded and checked once watched; a lock for one that
/// needs a login.
struct EpisodeChip: View {
    let episode: Episode
    let current: Bool
    var watched = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if episode.playable {
                    Text("\(episode.number)")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                } else {
                    Image(systemName: "lock.fill").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(current ? AnyShapeStyle(.white) : watched ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .background(current ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.07)),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if watched {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(current ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                        .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!episode.playable)
        .opacity(episode.playable ? 1 : 0.45)
        .accessibilityLabel("第 \(episode.number) 集")
        .accessibilityValue(watched ? "已看过" : "")
        .accessibilityHint(episode.playable ? "" : "这一集需要登录")
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// HeroUnderBar lets the hero's colors run up under the bar, where iOS 26
/// would fade the content out.
private struct HeroUnderBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}
