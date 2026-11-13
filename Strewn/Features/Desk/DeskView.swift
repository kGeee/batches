import SwiftUI

/// Your desk: profile header and your piles, laid out how you like. A grid, one long row you scroll
/// sideways, or freehand, with piles wherever you drop them. Piles can be kept together in groups in
/// any of those. Moving things only happens in Arrange, so tapping and scrolling stay as they are.
struct DeskView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppChrome.self) private var chrome: AppChrome?
    @Namespace private var pileSpace
    @State private var openID: UUID?
    @State private var filter = DeskFilter.all
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var openGroupID: UUID?
    @State private var showNewPile = false
    @State private var sharing: PileRef?
    @State private var showAccount = false
    @State private var followList: FollowListRoute?
    @State private var arranging = false
    @State private var renamingGroup: DeskGroup?
    @State private var groupNameDraft = ""

    // The tile being dragged in Arrange.
    @State private var draggingID: String?
    @State private var dragPoint: CGPoint = .zero
    /// Where on the tile the finger came down, from its center, so it doesn't jump to the finger.
    @State private var grabOffset: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var dropTargetID: String?
    @State private var slots: [String: CGRect] = [:]

    private static let tileSpace = "deskTiles"
    // Top-aligned, so a batch with a short title doesn't sit lower than the one beside it.
    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]
    private var layout: DeskLayout { model.desk }
    /// Everything on the desk. Moving and grouping work on this, whatever is filtered out of view.
    private var tiles: [DeskTile] { layout.tiles(for: model.myCollections) }
    /// What's showing: `tiles` narrowed by the filter and the search. Arrange shows everything.
    private var shownTiles: [DeskTile] {
        guard !arranging else { return tiles }
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return tiles.filter { tile in
            let piles: [PhotoCollection]
            switch tile {
            case .pile(let pile): piles = [pile]
            case .group(_, let members): piles = members
            }
            guard piles.contains(where: filter.includes) else { return false }
            guard !words.isEmpty else { return true }
            return tile.title.lowercased().contains(words)
                || piles.contains { $0.title.lowercased().contains(words) || ($0.place?.lowercased().contains(words) ?? false) }
        }
    }
    private var narrowed: Bool { !arranging && (filter != .all || !query.trimmingCharacters(in: .whitespaces).isEmpty) }
    /// The first batch on the desk, given room at the top of the grid.
    private var hero: PhotoCollection? {
        guard layout.mode == .grid, !arranging, !narrowed, tiles.count >= 3, case .pile(let pile)? = tiles.first else { return nil }
        return pile
    }
    private var openGroup: (group: DeskGroup, piles: [PhotoCollection])? {
        for case .group(let group, let piles) in tiles where group.id == openGroupID { return (group, piles) }
        return nil
    }

    var body: some View {
        ZStack {
            deskSurface
                .background(DeskMatBackground())
                .refreshable { await model.refresh() }
                .sheet(isPresented: $showNewPile) { NewPileSheet() }
                .sheet(item: $sharing) { SharePileSheet(collectionID: $0.id) }
                .sheet(isPresented: $showAccount) { AccountSheet() }
                .sheet(item: $followList) { route in
                    NavigationStack {
                        FollowListView(route: route)
                            .navigationDestination(for: User.self) { ProfileView(user: $0) }
                            .navigationDestination(for: FollowListRoute.self) { FollowListView(route: $0) }
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { followList = nil }.fontWeight(.semibold) } }
                    }
                    .tint(.strewnAccent)
                }
                .sensoryFeedback(.impact(weight: .light), trigger: openID)
                .sensoryFeedback(.selection, trigger: dropTargetID)
                // The gallery gets the whole screen, as it does from Friends.
                .coversTabBar(openID != nil || openGroupID != nil, key: "desk")
                // Likes and comments made while a batch was open show on the desk once it closes.
                .onChange(of: openID) { before, now in
                    if before != nil, now == nil { Task { await model.refreshSocial() } }
                }
                .sheet(item: $renamingGroup) { group in
                    PaperTextPrompt(title: "Name this group", placeholder: "Name", initial: group.title) { title in
                        groupNameDraft = title
                        saveGroupName(id: group.id)
                    }
                    .presentationDetents([.height(200)])
                }

            if let openGroup {
                DeskGroupView(group: openGroup.group, piles: openGroup.piles, namespace: pileSpace, openID: openID,
                              onOpen: open,
                              onRename: { startRenaming(openGroup.group) },
                              onTakeOut: { pile in
                                  model.changeDesk { $0.takeOut(pile.id, from: openGroup.group.id) }
                              },
                              onUngroup: {
                                  openGroupID = nil
                                  model.changeDesk { $0.ungroup(openGroup.group.id) }
                              },
                              onClose: { withAnimation(.snappy) { openGroupID = nil } })
                    .transition(.opacity)
                    .zIndex(1)
            }

            if let openID, let collection = model.myCollections.first(where: { $0.id == openID }) {
                GalleryView(collection: collection, namespace: pileSpace, isOwner: true) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { self.openID = nil }
                }
                .zIndex(2)
            }
        }
        .environment(\.tiltedPiles, layout.tiltedPiles)
        // A group that lost its last batches closes with it.
        .onChange(of: model.desk.groups) { _, groups in
            if let id = openGroupID, !groups.contains(where: { $0.id == id }) { openGroupID = nil }
        }
    }

    // MARK: Layouts

    @ViewBuilder
    private var deskSurface: some View {
        if layout.mode == .freehand && !shownTiles.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                top.padding(.horizontal, 14)
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) { freehandBoard(viewport: geo.size) }
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    top.padding(.horizontal, 14)
                    if tiles.isEmpty {
                        EmptyDesk { showNewPile = true }.padding(.horizontal, 14)
                    } else if shownTiles.isEmpty {
                        Text(query.isEmpty ? "No \(filter.title.lowercased()) batches yet." : "No batches match “\(query)”.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if layout.mode == .sideways {
                        sidewaysRow
                    } else {
                        if let hero { heroTile(hero).padding(.horizontal, 14).padding(.bottom, 6) }
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(hero == nil ? shownTiles : Array(shownTiles.dropFirst())) { slottedTile($0) }
                        }
                        .coordinateSpace(name: Self.tileSpace)
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProfileHeader(user: model.me, pileCount: model.myCollections.count,
                          frameCount: model.myCollections.reduce(0) { $0 + $1.photos.count },
                          onSearch: model.myCollections.isEmpty ? nil : { toggleSearch() }, onAccount: { showAccount = true },
                          onFollowList: { tab in if let me = model.me { followList = FollowListRoute(user: me, tab: tab) } })
            if searching { searchField }
            if let news { activityLine(news) }
            if !model.myCollections.isEmpty {
                if arranging { arrangeBar } else { filterBar }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your batches", text: $query)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
            Button { toggleSearch() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .paperField(focused: searchFocused)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func toggleSearch() {
        withAnimation(.snappy) {
            searching.toggle()
            if !searching { query = "" }
        }
        searchFocused = searching
    }

    /// Narrows the desk to one kind of batch, with the layout and Arrange tucked at the end.
    private var filterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(DeskFilter.allCases) { option in
                        let selected = filter == option
                        Button {
                            withAnimation(.snappy) { filter = option }
                        } label: {
                            Text(option.title)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 13)
                                .frame(height: 32)
                                .foregroundStyle(selected ? Color.mat : Color.primary)
                                .background(selected ? Color.primary : Color.clear, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.secondary.opacity(selected ? 0 : 0.3), lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
            Menu {
                Picker("Layout", selection: Binding(get: { layout.mode },
                                                    set: { mode in withAnimation(.snappy) { model.changeDesk { $0.mode = mode } } })) {
                    ForEach(DeskLayout.Mode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Button("Arrange", systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                    withAnimation(.snappy) { arranging = true }
                }
            } label: {
                Image(systemName: layout.mode.symbol)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 40, height: 32)
                    .foregroundStyle(Color.primary)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Layout, \(layout.mode.title)")
        }
    }

    // MARK: Activity

    private struct News {
        let people: [User]
        let headline: String
        let detail: String
        let batch: PhotoCollection?
    }

    /// What's happened to your photos since you last looked, summed up in two lines.
    private var news: News? {
        let unseen = model.unseenActivity
        guard !unseen.isEmpty, !arranging else { return nil }
        var people: [User] = []
        var seen: Set<UUID> = []
        for item in unseen where seen.insert(item.actorID).inserted {
            if let actor = item.actor { people.append(actor) }
        }
        let names = people.prefix(2).map(\.displayName)
        let others = seen.count - names.count
        var who = names.joined(separator: names.count == 2 && others == 0 ? " and " : ", ")
        if who.isEmpty { who = seen.count.counted("person", plural: "people") }
        else if others > 0 { who += " and \(others.counted("other"))" }

        let likes = unseen.filter(\.isLike).count
        let comments = unseen.count - likes
        let verb = likes > 0 && comments > 0 ? "liked and commented" : likes > 0 ? "liked your photos" : "commented"
        // The batch most of it happened in.
        let batches = Dictionary(grouping: unseen.compactMap { model.batch(containing: $0.photoID) }, by: \.id)
        let busiest = batches.max { $0.value.count < $1.value.count }?.value.first
        // Counts first: a long title is what gets cut short, not the numbers.
        var parts: [String] = []
        if likes > 0 { parts.append(likes.counted("like")) }
        if comments > 0 { parts.append(comments.counted("comment")) }
        if let busiest { parts.append(busiest.title + (batches.count > 1 ? " and \(batches.count - 1) more" : "")) }
        return News(people: people, headline: "\(who) \(verb)", detail: parts.joined(separator: " · "), batch: busiest)
    }

    private func activityLine(_ news: News) -> some View {
        Button {
            model.markActivitySeen()
            if let batch = news.batch, model.myCollections.contains(where: { $0.id == batch.id }) {
                open(batch)
            } else {
                chrome?.showsActivity = true
                chrome?.tab = .friends
            }
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: -8) {
                    ForEach(news.people.prefix(3)) { AvatarView(user: $0, size: 28) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(news.headline).font(.footnote.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(news.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(news.headline). \(news.detail)")
        .transition(.opacity)
    }

    /// Picks the layout, and goes in and out of Arrange.
    private var arrangeBar: some View {
        HStack(spacing: 6) {
            ForEach(DeskLayout.Mode.allCases) { mode in
                Button {
                    withAnimation(.snappy) { model.changeDesk { $0.mode = mode } }
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 34)
                        .foregroundStyle(layout.mode == mode ? Color.onAccent : Color.primary)
                        .background(layout.mode == mode ? Color.strewnAccent : Color.card, in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("\(mode.title) layout")
                .accessibilityAddTraits(layout.mode == mode ? .isSelected : [])
            }
            Spacer(minLength: 8)
            if arranging {
                Button {
                    withAnimation(.snappy) { model.changeDesk { $0.tiltedPiles.toggle() } }
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 34)
                        .foregroundStyle(layout.tiltedPiles ? Color.onAccent : Color.primary)
                        .background(layout.tiltedPiles ? Color.strewnAccent : Color.card, in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("Tilted piles")
                .accessibilityAddTraits(layout.tiltedPiles ? .isSelected : [])
            }
            Button {
                withAnimation(.snappy) { arranging.toggle() }
            } label: {
                Text(arranging ? "Done" : "Arrange")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .foregroundStyle(arranging ? Color.onAccent : Color.primary)
                    .background(arranging ? Color.strewnAccent : Color.card, in: Capsule())
            }
        }
        .overlay(alignment: .bottomLeading) {
            if arranging {
                Text(layout.mode == .freehand ? "Drag batches anywhere. Drop one on another to group them."
                                              : "Drag to reorder. Long-press a batch to group it.")
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .font(.caption).foregroundStyle(.secondary)
                    .offset(y: 20)
            }
        }
        .padding(.bottom, arranging ? 20 : 0)
    }

    private var sidewaysRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(shownTiles) { slottedTile($0).frame(width: 250) }
            }
            .coordinateSpace(name: Self.tileSpace)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    /// A board bigger than the screen, so it scrolls both ways. While arranging it keeps spare room
    /// past the furthest batch, to drag into.
    private func freehandBoard(viewport: CGSize) -> some View {
        let spots = layout.freehandPositions(for: tiles)
        let spareX = arranging ? viewport.width * 0.7 : 0
        let spareY = arranging ? viewport.height * 0.5 : 0
        let right = (spots.values.map(\.x).max() ?? 0) + DeskLayout.tileWidth / 2 + 14
        let bottom = (spots.values.map(\.y).max() ?? 0) + DeskLayout.tileHeight / 2 + 24
        return ZStack {
            ForEach(shownTiles) { tile in
                let spot = spots[tile.id] ?? .zero
                let dragging = draggingID == tile.id
                tileBody(tile)
                    // A fixed height, so tiles line up however long their captions run.
                    .frame(width: DeskLayout.tileWidth, height: DeskLayout.tileHeight, alignment: .top)
                    .scaleEffect(dragging ? 1.06 : 1)
                    .contentShape(Rectangle())
                    .highPriorityGesture(freehandDrag(tile, spots: spots), including: arranging ? .all : .subviews)
                    .position(x: spot.x + (dragging ? dragTranslation.width : 0),
                              y: spot.y + (dragging ? dragTranslation.height : 0))
                    .zIndex(dragging ? 10 : 0)
            }
        }
        .frame(width: max(viewport.width, right + spareX), height: max(viewport.height, bottom + spareY))
    }

    // MARK: Tiles

    /// A tile in the grid or row: remembers its slot so a drag can tell what it's over.
    private func slottedTile(_ tile: DeskTile) -> some View {
        let dragging = draggingID == tile.id
        return tileBody(tile)
            .scaleEffect(dragging ? 1.05 : 1)
            .offset(dragging ? slotOffset(tile) : .zero)
            // Measured outside the offset, so this is the slot, not where the drag has taken it.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.tileSpace)) } action: { slots[tile.id] = $0 }
            .zIndex(dragging ? 10 : 0)
            .contentShape(Rectangle())
            .highPriorityGesture(reorderDrag(tile), including: arranging ? .all : .subviews)
            .accessibilityAction(named: "Move earlier") { moveTile(tile, by: -1) }
            .accessibilityAction(named: "Move later") { moveTile(tile, by: 1) }
    }

    private func slotOffset(_ tile: DeskTile) -> CGSize {
        guard let slot = slots[tile.id] else { return .zero }
        return CGSize(width: dragPoint.x - grabOffset.width - slot.midX, height: dragPoint.y - grabOffset.height - slot.midY)
    }

    /// The first batch, drawn large with its likes and comments beside the title.
    private func heroTile(_ collection: PhotoCollection) -> some View {
        let tile = DeskTile.pile(collection)
        return VStack(alignment: .leading, spacing: 4) {
            Group {
                if openID == collection.id {
                    Color.clear.aspectRatio(3 / 2, contentMode: .fit)
                } else {
                    DeskPileView(collection: collection, namespace: pileSpace)
                        .aspectRatio(3 / 2, contentMode: .fit)
                        // The pile is square; centered, not pushed to the leading edge.
                        .frame(maxWidth: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { open(collection) }
            .contextMenu { tileMenu(tile) }
            PileCaption(collection: collection, showsVisibility: true, prominent: true, totals: model.batchTotals[collection.id])
        }
    }

    private func tileBody(_ tile: DeskTile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                switch tile {
                case .pile(let collection):
                    if openID == collection.id {
                        // Keep the slot so the grid does not reflow while the pile is spread out.
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    } else {
                        DeskPileView(collection: collection, namespace: pileSpace)
                    }
                case .group(let group, let piles):
                    DeskGroupPile(group: group, piles: piles, tilted: layout.tiltedPiles)
                }
            }
            .overlay {
                if arranging {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.strewnAccent.opacity(dropTargetID == tile.id ? 1 : 0.35),
                                      style: StrokeStyle(lineWidth: dropTargetID == tile.id ? 3 : 1, dash: dropTargetID == tile.id ? [] : [5, 4]))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !arranging { open(tile) } }
            .contextMenu { tileMenu(tile) }
            switch tile {
            case .pile(let collection):
                PileCaption(collection: collection, showsVisibility: true, totals: model.batchTotals[collection.id])
            case .group(let group, let piles):
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).titleStyle(.subheadline).lineLimit(2)
                    Text(piles.count.counted("batch", plural: "batches")).metaStyle().lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func tileMenu(_ tile: DeskTile) -> some View {
        let others = tiles.filter { $0.id != tile.id }
        switch tile {
        case .pile(let collection):
            Button("Open", systemImage: "rectangle.expand.vertical") { open(tile) }
            Button("Share…", systemImage: "square.and.arrow.up") { sharing = PileRef(id: collection.id) }
            groupMenu(tile, others: others)
            Button("Delete batch", systemImage: "trash", role: .destructive) { model.deletePile(collection.id) }
        case .group(let group, _):
            Button("Open", systemImage: "rectangle.expand.vertical") { open(tile) }
            Button("Rename", systemImage: "pencil") { startRenaming(group) }
            groupMenu(tile, others: others)
            Button("Ungroup", systemImage: "rectangle.stack.badge.minus") { model.changeDesk { $0.ungroup(group.id) } }
        }
    }

    @ViewBuilder
    private func groupMenu(_ tile: DeskTile, others: [DeskTile]) -> some View {
        if !others.isEmpty {
            Menu("Group with", systemImage: "rectangle.stack.badge.plus") {
                ForEach(others) { other in
                    Button(other.title) { groupTiles(tile, onto: other) }
                }
            }
        }
    }

    // MARK: Moving

    private func reorderDrag(_ tile: DeskTile) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.tileSpace))
            .onChanged { value in
                if draggingID != tile.id {
                    draggingID = tile.id
                    if let slot = slots[tile.id] {
                        grabOffset = CGSize(width: value.startLocation.x - slot.midX, height: value.startLocation.y - slot.midY)
                    }
                    // From here the desk keeps its own order.
                    model.changeDesk(save: false) { $0.order = tiles.map(\.id) }
                }
                dragPoint = value.location
                guard let over = slots.first(where: { $0.key != tile.id && $0.value.contains(value.location) })?.key,
                      let from = layout.order.firstIndex(of: tile.id), let to = layout.order.firstIndex(of: over) else { return }
                withAnimation(.snappy) {
                    model.changeDesk(save: false) { $0.order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
                }
            }
            .onEnded { _ in
                withAnimation(.snappy) { draggingID = nil }
                model.saveDesk()
            }
    }

    private func freehandDrag(_ tile: DeskTile, spots: [String: CGPoint]) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                draggingID = tile.id
                dragTranslation = value.translation
                dropTargetID = target(for: tile, at: moved(spots[tile.id], by: value.translation), spots: spots)?.id
            }
            .onEnded { value in
                let spot = moved(spots[tile.id], by: value.translation)
                let target = target(for: tile, at: spot, spots: spots)
                withAnimation(.snappy) {
                    model.changeDesk { desk in
                        // Every tile keeps the place it's in now, not just the one that moved.
                        desk.positions = spots
                        if let target {
                            desk.group(tile, onto: target)
                        } else {
                            desk.positions[tile.id] = CGPoint(x: max(DeskLayout.tileWidth / 2, spot.x),
                                                              y: max(DeskLayout.tileHeight / 2, spot.y))
                        }
                    }
                    draggingID = nil
                    dragTranslation = .zero
                    dropTargetID = nil
                }
            }
    }

    private func moved(_ spot: CGPoint?, by translation: CGSize) -> CGPoint {
        CGPoint(x: (spot?.x ?? 0) + translation.width, y: (spot?.y ?? 0) + translation.height)
    }

    /// The tile this one would join if dropped here: its center is well inside the other's.
    private func target(for tile: DeskTile, at spot: CGPoint, spots: [String: CGPoint]) -> DeskTile? {
        tiles.first { other in
            guard other.id != tile.id, let center = spots[other.id] else { return false }
            return abs(center.x - spot.x) < DeskLayout.tileWidth * 0.35 && abs(center.y - spot.y) < DeskLayout.tileHeight * 0.35
        }
    }

    private func moveTile(_ tile: DeskTile, by step: Int) {
        var order = tiles.map(\.id)
        guard let from = order.firstIndex(of: tile.id), order.indices.contains(from + step) else { return }
        order.swapAt(from, from + step)
        model.changeDesk { $0.order = order }
    }

    private func groupTiles(_ tile: DeskTile, onto other: DeskTile) {
        withAnimation(.snappy) {
            model.changeDesk { desk in
                desk.order = tiles.map(\.id)
                desk.group(tile, onto: other)
            }
        }
    }

    private func startRenaming(_ group: DeskGroup) {
        groupNameDraft = group.title
        renamingGroup = group
    }

    private func saveGroupName(id: UUID) {
        let title = groupNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        model.changeDesk { desk in
            if let i = desk.groups.firstIndex(where: { $0.id == id }) { desk.groups[i].title = title }
        }
    }

    private func open(_ tile: DeskTile) {
        switch tile {
        case .pile(let collection): open(collection)
        case .group(let group, _): withAnimation(.snappy) { openGroupID = group.id }
        }
    }

    private func open(_ collection: PhotoCollection) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { openID = collection.id }
    }
}

/// A group on the desk: the covers of its batches, loosely fanned on a tray. Whole prints, as
/// everywhere, never cropped to fit.
struct DeskGroupPile: View {
    let group: DeskGroup
    let piles: [PhotoCollection]
    var tilted = false

    private static let fan: [(angle: Double, x: CGFloat, y: CGFloat)] = [(-9, -0.12, -0.08), (7, 0.12, -0.06), (-4, -0.08, 0.12), (5, 0.1, 0.1)]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let covers = Array(piles.compactMap(\.cover).prefix(Self.fan.count))
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial)
                ForEach(Array(covers.enumerated()), id: \.element.id) { index, photo in
                    let spot = Self.fan[index]
                    // Centered on the tray however many covers there are.
                    let used = Self.fan.prefix(covers.count)
                    let middleX = used.map(\.x).reduce(0, +) / CGFloat(used.count)
                    let middleY = used.map(\.y).reduce(0, +) / CGFloat(used.count)
                    PrintView(photo: photo, paper: side * 0.012)
                        .frame(width: side * (photo.orientation == .portrait ? 0.34 : 0.48))
                        .rotationEffect(.degrees(tilted ? spot.angle : 0))
                        .position(x: side / 2 + (spot.x - middleX) * side, y: side / 2 + (spot.y - middleY) * side)
                }
                Text("\(piles.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.onAccent)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Color.strewnAccent, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.title), group of \(piles.count) batches")
        .accessibilityAddTraits(.isButton)
    }
}

/// A group opened up: its batches, each opening as usual.
private struct DeskGroupView: View {
    let group: DeskGroup
    let piles: [PhotoCollection]
    let namespace: Namespace.ID
    let openID: UUID?
    let onOpen: (PhotoCollection) -> Void
    let onRename: () -> Void
    let onTakeOut: (PhotoCollection) -> Void
    let onUngroup: () -> Void
    let onClose: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 38, height: 38)
                        .background(.foreground.opacity(0.1), in: Circle())
                }
                .accessibilityLabel("Back to the desk")
                Spacer()
                Menu {
                    Button("Rename", systemImage: "pencil", action: onRename)
                    Button("Ungroup", systemImage: "rectangle.stack.badge.minus", action: onUngroup)
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 38, height: 38)
                        .background(.foreground.opacity(0.1), in: Circle())
                }
                .accessibilityLabel("More")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.title).titleStyle(.largeTitle, weight: .bold)
                            .onTapGesture(perform: onRename)
                            .accessibilityAddTraits(.isButton)
                        Text(piles.count.counted("batch", plural: "batches")).metaStyle(.caption)
                    }
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(piles) { pile in
                            VStack(alignment: .leading, spacing: 2) {
                                Group {
                                    if openID == pile.id {
                                        Color.clear.aspectRatio(1, contentMode: .fit)
                                    } else {
                                        DeskPileView(collection: pile, namespace: namespace)
                                            .contentShape(Rectangle())
                                            .onTapGesture { onOpen(pile) }
                                            .contextMenu {
                                                Button("Open", systemImage: "rectangle.expand.vertical") { onOpen(pile) }
                                                Button("Take out of group", systemImage: "rectangle.stack.badge.minus") { onTakeOut(pile) }
                                            }
                                    }
                                }
                                PileCaption(collection: pile, showsVisibility: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .background(DeskMatBackground())
    }
}

struct PileCaption: View {
    let collection: PhotoCollection
    /// Your own piles show who can see them.
    var showsVisibility = false
    /// The large batch at the top of the desk: a bigger title.
    var prominent = false
    /// Likes and comments across the batch's photos, when they're known.
    var totals: PhotoReactions? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(collection.title).batchTitle(collection.font, prominent ? .title3 : .subheadline).lineLimit(2)
                if let totals, totals.likeCount + totals.commentCount > 0 {
                    Spacer(minLength: 4)
                    ReactionsLine(reactions: totals)
                }
            }
            HStack(spacing: 6) {
                if showsVisibility { AudienceChip(collection: collection) }
                // The longest line that fits beside the chip, so it never wraps to a second.
                ViewThatFits(in: .horizontal) {
                    ForEach(metaLines, id: \.self) { Text($0).metaStyle().lineLimit(1) }
                }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var metaLines: [String] {
        let count = collection.photos.count
        let date = collection.shotOn?.formatted(.dateTime.month(.abbreviated).day())
        var full = [count.counted("frame")]
        if let date { full.append(date) }
        var lines: [String] = []
        if let place = collection.place { lines.append((full + [place]).joined(separator: " · ")) }
        lines.append(full.joined(separator: " · "))
        lines.append((["\(count)"] + (date.map { [$0] } ?? [])).joined(separator: " · "))
        return lines
    }
}

/// Who can see one of your batches, in words: "Followers", "2 people", "Only me".
struct AudienceChip: View {
    let collection: PhotoCollection

    var body: some View {
        let shared = collection.isShared
        HStack(spacing: 3) {
            Image(systemName: collection.visibility.symbol)
            Text(collection.audienceLabel).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(shared ? AnyShapeStyle(Color.strewnAccent) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(shared ? Color.strewnAccent.opacity(0.12) : Color.secondary.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Visible to: \(collection.visibility.title)")
    }
}

/// The kinds of batch the desk can be narrowed to.
enum DeskFilter: String, CaseIterable, Identifiable {
    case all, shared, onlyMe, group
    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .shared: "Shared"
        case .onlyMe: "Private"
        case .group: "Group"
        }
    }

    func includes(_ pile: PhotoCollection) -> Bool {
        switch self {
        case .all: true
        case .shared: pile.isShared
        case .onlyMe: !pile.isShared
        case .group: pile.isGroup
        }
    }
}

/// The top of your desk: who you are, what's on it, and the two things you do from here.
struct ProfileHeader: View {
    let user: User?
    let pileCount: Int
    let frameCount: Int
    /// nil hides the search button, as on an empty desk.
    var onSearch: (() -> Void)? = nil
    var onAccount: () -> Void = {}
    var onFollowList: (FollowListRoute.Tab) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(user?.displayName ?? " ").titleStyle(.largeTitle, weight: .bold).lineLimit(1)
                Text("\(pileCount.counted("batch", plural: "batches")) · \(frameCount.counted("frame"))").metaStyle(.caption)
                if let user {
                    HStack(spacing: 4) {
                        Button { onFollowList(.followers) } label: {
                            Text(user.followerCount.counted("follower")).metaStyle(.caption).underline().roomyTapTarget()
                        }
                        Text("·").metaStyle(.caption)
                        Button { onFollowList(.following) } label: {
                            Text("\(user.followingCount) following").metaStyle(.caption).underline().roomyTapTarget()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 8)
            // New batch is in the bar at the bottom, under the thumb.
            if let onSearch {
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass").font(.body.weight(.semibold)).foregroundStyle(Color.strewnAccent)
                        .frame(width: 44, height: 44)
                        .background(Color.strewnAccent.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Search your batches")
            }
            Button(action: onAccount) { AvatarView(user: user, size: 44) }
                .accessibilityLabel("Account")
        }
        .padding(.top, 16)
        .padding(.bottom, 2)
    }
}

/// What an empty desk says, instead of a blank mat.
private struct EmptyDesk: View {
    var onNewPile: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Your desk is clear").titleStyle(.title3)
            Text("Make a batch from photos in your library.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("New batch", systemImage: "plus", action: onNewPile)
                .buttonStyle(.borderedProminent).tint(.strewnAccent).foregroundStyle(Color.onAccent)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.top, 24)
    }
}

/// Your account, set out on the desk like a contact sheet: who you are, what you've made,
/// your latest frames, and signing out.
struct AccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var frameCount: Int { model.myCollections.reduce(0) { $0 + $1.photos.count } }
    private var recentCovers: [Photo] { model.myCollections.compactMap(\.cover).prefix(4).map { $0 } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if let me = model.me {
                        VStack(spacing: 6) {
                            AvatarView(user: me, size: 92)
                                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                                .padding(.bottom, 6)
                            Text(me.displayName).titleStyle(.title, weight: .bold)
                            Text("@\(me.handle)").metaStyle(.subheadline)
                        }
                        .padding(.top, 8)

                        stats(me)

                        if !recentCovers.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                label("Latest batches")
                                HStack(spacing: 12) {
                                    ForEach(Array(recentCovers.enumerated()), id: \.element.id) { index, photo in
                                        PrintView(photo: photo, paper: 3)
                                            .aspectRatio(1, contentMode: .fit)
                                            .clipped()
                                    }
                                    ForEach(recentCovers.count..<4, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                                }
                            }
                        }

                        VStack(spacing: 0) {
                            NavigationLink(value: me) {
                                row("Your desk as friends see it", systemImage: "person.crop.rectangle")
                            }
                            Divider().padding(.leading, 48)
                            NavigationLink { BlockedPeopleView() } label: {
                                row("Blocked", systemImage: "hand.raised", detail: model.blocked.isEmpty ? nil : "\(model.blocked.count)")
                            }
                        }
                        .buttonStyle(.plain)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))

                        if AppLinks.feedbackMail() != nil || AppLinks.privacyPolicy != nil {
                            VStack(spacing: 0) {
                                if let mail = AppLinks.feedbackMail() {
                                    Link(destination: mail) { row("Send feedback", systemImage: "envelope", chevron: false) }
                                }
                                if AppLinks.feedbackMail() != nil && AppLinks.privacyPolicy != nil {
                                    Divider().padding(.leading, 48)
                                }
                                if let policy = AppLinks.privacyPolicy {
                                    Link(destination: policy) { row("Privacy policy", systemImage: "hand.raised.square", chevron: false) }
                                }
                            }
                            .buttonStyle(.plain)
                            .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
                        }

                        VStack(spacing: 0) {
                            Button { dismiss(); Task { await model.signOut() } } label: {
                                row("Sign out", systemImage: "rectangle.portrait.and.arrow.right", tint: .red, chevron: false)
                            }
                            Divider().padding(.leading, 48)
                            NavigationLink { DeleteAccountView() } label: {
                                row("Delete account", systemImage: "trash", tint: .red)
                            }
                        }
                        .buttonStyle(.plain)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
                    }

                    if model.isDemo {
                        Label("Demo mode: sample friends, and nothing leaves this phone. Batches reset when the app restarts.",
                              systemImage: "testtube.2")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(Self.versionLine).metaStyle().frame(maxWidth: .infinity).padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(DeskMatBackground())
            .navigationDestination(for: User.self) { ProfileView(user: $0) }
            .navigationDestination(for: FollowListRoute.self) { FollowListView(route: $0) }
            .paperNavigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.strewnAccent)
    }

    /// Counts in a strip like film edge printing: big number, small label, hairline between.
    private func stats(_ me: User) -> some View {
        HStack(spacing: 0) {
            stat(model.myCollections.count, "batch", "batches")
            Divider().frame(height: 34)
            stat(frameCount, "frame", "frames")
            Divider().frame(height: 34)
            NavigationLink(value: FollowListRoute(user: me, tab: .followers)) {
                stat(me.followerCount, "follower", "followers")
            }
            .accessibilityHint("Shows who follows you")
            Divider().frame(height: 34)
            NavigationLink(value: FollowListRoute(user: me, tab: .following)) {
                stat(me.followingCount, "following", "following")
            }
            .accessibilityHint("Shows who you follow")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 14)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func stat(_ value: Int, _ one: String, _ many: String) -> some View {
        VStack(spacing: 3) {
            Text("\(value)").font(.system(.title2, design: .serif, weight: .semibold)).monospacedDigit()
            Text((value == 1 ? one : many).uppercased()).font(.system(size: 9.5, weight: .medium, design: .monospaced)).kerning(0.8).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func row(_ title: String, systemImage: String, tint: Color = .primary, detail: String? = nil, chevron: Bool = true) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage).frame(width: 22).foregroundStyle(tint == .primary ? Color.strewnAccent : tint)
            Text(title).foregroundStyle(tint)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.8)
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Batches \(version) (\(build))"
    }
}

/// Identifies a pile for `.sheet(item:)`.
struct PileRef: Identifiable, Hashable { let id: UUID }
