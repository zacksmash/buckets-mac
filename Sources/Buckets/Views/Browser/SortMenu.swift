import SwiftUI

/// Sort By choices, shared by the View menu and the toolbar.
struct SortMenu: View {
    @Bindable var model: BrowserModel

    var body: some View {
        Picker("Sort By", selection: $model.sortField) {
            ForEach(BrowserSortField.allCases) { field in
                Text(field.title).tag(field)
            }
        }
        .pickerStyle(.inline)

        Picker("Order", selection: $model.isSortAscending) {
            Text("Ascending").tag(true)
            Text("Descending").tag(false)
        }
        .pickerStyle(.inline)
    }
}
