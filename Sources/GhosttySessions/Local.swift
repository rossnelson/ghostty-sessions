import SwiftUI

// The macOS 26 SDK makes @State a macro, and its plugin ships only with Xcode.
// This wrapper gives the same view-owned state through @StateObject, so the
// app builds with the Command Line Tools alone.
@propertyWrapper
struct Local<Value>: DynamicProperty {
  @StateObject private var box: Box

  init(wrappedValue: Value) {
    _box = StateObject(wrappedValue: Box(wrappedValue))
  }

  var wrappedValue: Value {
    get { box.value }
    nonmutating set { box.value = newValue }
  }

  var projectedValue: Binding<Value> {
    Binding(get: { box.value }, set: { box.value = $0 })
  }

  final class Box: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
  }
}
