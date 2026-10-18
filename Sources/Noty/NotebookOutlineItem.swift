import Foundation

struct NotebookOutlineItem: Identifiable {
    let id: String
    let title: String
    let pageID: UUID?
    let children: [NotebookOutlineItem]?
}
