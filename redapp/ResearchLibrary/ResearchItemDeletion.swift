import SwiftUI

extension View {
    /// Asks before deleting a saved feed, since that removes every snapshot,
    /// answer and comparison saved for it. Setting `item` starts the request.
    /// `beforeDelete` runs first (for example to leave a report that shows the
    /// feed), and `onDeleted` runs after a successful delete.
    func researchItemDeletionConfirmation(
        item: Binding<ResearchItemRecord?>,
        beforeDelete: @escaping (UUID) -> Void = { _ in },
        onDeleted: @escaping (UUID) -> Void = { _ in }
    ) -> some View {
        modifier(ResearchItemDeletionConfirmation(item: item, beforeDelete: beforeDelete, onDeleted: onDeleted))
    }

    /// Swipe left to delete, for rows that aren't in a `List` (where
    /// `.swipeActions` isn't available), such as the sidebar.
    func researchSwipeToDelete(
        background: Color,
        onDelete: @escaping () -> Void
    ) -> some View {
        modifier(ResearchSwipeToDelete(background: background, onDelete: onDelete))
    }
}

@MainActor
private struct ResearchItemDeletionConfirmation: ViewModifier {
    private struct PendingDeletion: Equatable {
        let id: UUID
        let title: String
        let snapshotCount: Int
    }

    @Binding var item: ResearchItemRecord?
    let beforeDelete: (UUID) -> Void
    let onDeleted: (UUID) -> Void
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var pending: PendingDeletion?
    @State private var errorMessage: String?

    /// Requests usually come from a context menu or swipe action that is still
    /// closing. Presenting an alert during that animation can be silently
    /// dropped on a device, so the confirmation and any error wait for it.
    private let presentationDelay: TimeInterval = 0.45

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id) { _, newID in
                guard let newID, let item else { return }
                let request = PendingDeletion(
                    id: newID,
                    title: item.title,
                    snapshotCount: (try? store.runs(itemID: newID).count) ?? 1
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + presentationDelay) {
                    pending = request
                }
            }
            .alert(
                "Delete “\(pending?.title ?? "saved research")”?",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { cancel() } }
                )
            ) {
                Button("Cancel", role: .cancel) { cancel() }
                Button("Delete", role: .destructive) { deletePending() }
            } message: {
                Text(message)
            }
            .alert("Couldn’t Delete", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var message: String {
        let count = pending?.snapshotCount ?? 1
        let snapshots = count == 1 ? "its saved snapshot" : "all \(count) saved snapshots"
        return "This deletes \(snapshots), with the questions, answers and comparisons made from them. This can’t be undone."
    }

    private func cancel() {
        pending = nil
        item = nil
    }

    private func deletePending() {
        guard let request = pending else { return }
        pending = nil
        item = nil
        // Leave any screen showing this feed before its data disappears.
        beforeDelete(request.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + presentationDelay) {
            do {
                try store.deleteItem(id: request.id)
                onDeleted(request.id)
            } catch {
                errorMessage = "“\(request.title)” couldn’t be deleted: \(error.localizedDescription)"
            }
        }
    }
}

/// Set while a row is being swiped. The row moves with the finger, so lifting
/// it would otherwise also count as a tap on the row; row actions check this.
@MainActor
enum ResearchRowSwipe {
    static var isActive = false
}

/// Drag a row left to delete it: a red trash area follows the finger, and
/// letting go past it asks for confirmation (through `onDelete`). There is no
/// separate button to tap, so a tap can never reach both Delete and the row.
/// Vertical drags are left to the enclosing scroll view.
private struct ResearchSwipeToDelete: ViewModifier {
    let background: Color
    let onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var isHorizontalDrag: Bool?

    private let triggerWidth: CGFloat = 76

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            if offset < 0 {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(offset <= -triggerWidth ? 1.15 : 1)
                    .frame(width: max(triggerWidth, -offset))
                    .frame(maxHeight: .infinity)
                    .background(RedappDesign.negative.opacity(offset <= -triggerWidth ? 1 : 0.75))
                    .accessibilityHidden(true)
            }
            content
                .background(background)
                // A swipe must never also count as a tap on the row.
                .allowsHitTesting(isHorizontalDrag != true)
                .offset(x: offset)
        }
        .clipShape(RoundedRectangle(cornerRadius: RedappDesign.Radius.small, style: .continuous))
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    if isHorizontalDrag == nil {
                        isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height)
                    }
                    guard isHorizontalDrag == true else { return }
                    ResearchRowSwipe.isActive = true
                    offset = min(0, value.translation.width)
                }
                .onEnded { value in
                    let shouldDelete = isHorizontalDrag == true && value.translation.width <= -triggerWidth
                    withAnimation(.snappy(duration: 0.2)) { offset = 0 }
                    // Re-enable taps only after this touch has finished.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isHorizontalDrag = nil
                        ResearchRowSwipe.isActive = false
                    }
                    if shouldDelete { onDelete() }
                }
        )
        .animation(.snappy(duration: 0.15), value: offset <= -triggerWidth)
        .accessibilityAction(named: "Delete") { onDelete() }
    }
}
