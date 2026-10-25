import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Welcome to FunSize")
                .font(.title)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 300)
    }
}

#Preview {
    ContentView()
}
